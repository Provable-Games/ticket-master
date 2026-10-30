'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { A, validateSnapshot } = require('./restart.cjs');

function pausedSale() {
  return {
    classes: { ticket: '0x05c668438529906abdd5f04cbe44c9919c40a811f922cbdc59630f3116c0fd8f' },
    getters: {
      owner: [A.owner], get_payment_token: [A.lords], get_buyback_token: [A.survivor],
      get_treasury_address: [A.dao], get_velords_address: [A.velords],
      get_deployment_state: ['0x3'], is_low_issuance_mode: ['0x1'],
      get_token_distribution_rate: ['0x2ad909c264a70183601165'],
    },
    orderOwner: [A.owner], lpOwner: [A.owner], order: ['0x0', '0x0', '0x0'],
    poolLiquidity: ['0x0'], lp: ['0x1', '0x0', '0x1', '0x0', '0x0', '0x0', '0x0', '0x0', '0x0'],
    aggregateRates: ['0x0', '0x0', '0x6aca3c46'],
  };
}

test('accepts an empty original sale under multisig custody', () => {
  assert.doesNotThrow(() => validateSnapshot(pausedSale()));
});

for (const [name, change] of [
  ['an order that has already restarted', s => { s.order[0] = '0x1'; }],
  ['another active TWAMM seller', s => { s.aggregateRates[1] = '0x1'; }],
  ['liquidity deposited since inspection', s => { s.poolLiquidity[0] = '0x1'; }],
  ['order NFT moved to another owner', s => { s.orderOwner = [A.ticket]; }],
  ['LP NFT moved to another owner', s => { s.lpOwner = [A.ticket]; }],
  ['unclaimed LP fees', s => { s.lp[8] = '0x1'; }],
  ['a changed DAO recipient', s => { s.getters.get_treasury_address = [A.owner]; }],
  ['a changed payment token', s => { s.getters.get_payment_token = [A.survivor]; }],
  ['a changed TicketMaster implementation', s => { s.classes.ticket = '0x123'; }],
]) {
  test(`refuses ${name}`, () => {
    const snapshot = pausedSale();
    change(snapshot);
    assert.throws(() => validateSnapshot(snapshot));
  });
}

test('fork read proxy refuses writes, preserves request IDs, and caches only pinned reads', async () => {
  const { startForkProxy } = require('./fork-proxy.cjs');
  const fs = require('node:fs');
  const root = fs.existsSync('/workspace/.scratch') ? '/workspace/.scratch' : require('node:os').tmpdir();
  const cache = fs.mkdtempSync(require('node:path').join(root, 'beast-rollback-proxy-test-'));
  let forwarded = 0;
  const proxy = await startForkProxy({ cacheDirectory: cache, intervalMs: 0,
    fetcher: async () => { forwarded++; return { ok: true, status: 200, json: async () => ({ jsonrpc: '2.0', id: 1, result: '0x123' }) }; } });
  try {
    const request = async (method, params, id) => (await fetch(proxy.url, { method: 'POST',
      body: JSON.stringify({ jsonrpc: '2.0', method, params, id }) })).json();
    for (const method of ['starknet_addInvokeTransaction', 'starknet_addDeclareTransaction', 'devnet_mint']) {
      const refused = await request(method, {}, 9);
      assert.match(refused.error.message, /Read-only/);
    }
    assert.equal(forwarded, 0);
    const params = { block_id: { block_number: 16432906 }, contract_address: A.ticket, key: '0x1' };
    assert.equal((await request('starknet_getStorageAt', params, 10)).id, 10);
    assert.equal((await request('starknet_getStorageAt', params, 11)).id, 11);
    assert.equal(forwarded, 1);
    await request('starknet_getStorageAt', { ...params, block_id: 'latest' }, 12);
    await request('starknet_getStorageAt', { ...params, block_id: 'latest' }, 13);
    assert.equal(forwarded, 3);
  } finally { await proxy.close(); fs.rmSync(cache, { recursive: true }); }
});


test('controller declarations refuse mainnet before any network request', async () => {
  const { declareLocal } = require('./restart.cjs');
  await assert.rejects(declareLocal('https://api.cartridge.gg/x/starknet/mainnet/rpc/v0_10', A.owner, {}, {}), /Declarations require loopback Devnet/);
});
