#!/usr/bin/env node
'use strict';

// Fork-only: this file uses the same owned-loopback write guard as restart.cjs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Account, RpcProvider } = require('starknet');
const scenario = process.argv[2] || 'immediate';
assert(['immediate', 'traded'].includes(scenario), 'Usage: node rollback.cjs [immediate|traded]');
const output = path.resolve(process.env.BEAST_RESTART_OUTPUT || `/workspace/.scratch/beast-mode-rollback/${scenario}`);
process.env.BEAST_RESTART_OUTPUT = output;
const { A, inspect, rehearse, rpc, call, balance, txCall, transfer, integer, save, bounds, u256, submitLocal } = require('./restart.cjs');
const { buildProposal } = require('./web/proposal.cjs');
const { startForkProxy } = require('./fork-proxy.cjs');
const same = (a, b) => BigInt(a) === BigInt(b);

async function state(url, s, buyer) {
  const g = s.getters, getters = {}, balances = {}, classes = {};
  for (const name of Object.keys(g)) getters[name] = await call(url, A.ticket, name);
  for (const name of Object.keys(s.classes)) classes[name] = await rpc(url, 'starknet_getClassHashAt', { block_id: 'latest', contract_address: A[name] });
  for (const token of ['lords', 'ticket', 'survivor']) {
    for (const who of ['owner', 'ticket', 'dao', 'velords']) balances[`${token}_${who}`] = await balance(url, A[token], A[who]);
    if (buyer) balances[`${token}_buyer`] = await balance(url, A[token], buyer);
  }
  const read = (method, args) => call(url, A.positions, method, args);
  return { getters, classes, balances,
    order: await read('get_order_info', [...g.get_position_token_id, ...g.get_distribution_order_key]),
    lp: await read('get_token_info', [...g.get_liquidity_position_id, ...g.get_distribution_pool_key, ...bounds]),
    poolPrice: await read('get_pool_price', g.get_distribution_pool_key),
    poolLiquidity: await call(url, A.core, 'get_pool_liquidity', g.get_distribution_pool_key),
    aggregateRates: await call(url, A.extension, 'get_sale_rate_and_last_virtual_order_time', g.get_distribution_pool_key.slice(0, 3)),
    orderOwner: await call(url, A.nft, 'owner_of', [...g.get_position_token_id, 0]),
    lpOwner: await call(url, A.nft, 'owner_of', [...g.get_liquidity_position_id, 0]),
  };
}

async function run(url, s) {
  const g = s.getters, pool = g.get_distribution_pool_key, key = g.get_distribution_order_key;
  const orderId = g.get_position_token_id[0], lpId = g.get_liquidity_position_id[0];
  let buyer, buyerAccount;
  if (scenario === 'traded') {
    const local = (await rpc(url, 'devnet_getPredeployedAccounts'))[0];
    buyer = local.address;
    buyerAccount = new Account({ provider: new RpcProvider({ nodeUrl: url }),
      address: buyer, signer: local.private_key, cairoVersion: '1' });
    // Real fork LORDS, not minted tokens. Fund the test trader before baseline.
    await submitLocal(url, A.owner, [transfer(A.lords, buyer, 31n * 10n ** 18n)], 'fund-buyer');
  }
  const before = await state(url, s, buyer); save('before.json', before);
  const head = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
  const at = Math.max(head.timestamp + 1, s.timestamp + 300);
  await rpc(url, 'devnet_setTime', { time: at, generate_block: true });
  const proposal = buildProposal(s, at);
  save('restart-bundle.json', proposal);
  await submitLocal(url, A.owner, proposal.calls, 'restart');
  const restarted = await state(url, s, buyer); save('restarted.json', restarted);
  assert(same(restarted.orderOwner[0], A.ticket) && same(restarted.lpOwner[0], A.ticket));
  assert(BigInt(restarted.order[0]) > 0n && BigInt(restarted.poolLiquidity[0]) > 0n);

  let purchase = null;
  if (buyer) {
    const priceLimit = BigInt(proposal.sqrtPrice) * 99n / 100n, amount = 31n * 10n ** 18n;
    await submitLocal(url, buyer, [transfer(A.lords, A.router, amount),
      txCall(A.router, 'swap', [...pool, ...u256(priceLimit), 0, A.lords, amount, 0]),
      txCall(A.router, 'clear', [A.ticket]), txCall(A.router, 'clear', [A.lords])], 'buyer-purchase', 'SUCCEEDED', buyerAccount);
    purchase = { paidLords: before.balances.lords_buyer - await balance(url, A.lords, buyer),
      receivedTickets: await balance(url, A.ticket, buyer) - before.balances.ticket_buyer };
    assert(purchase.receivedTickets > 0n && purchase.paidLords > 0n);
    save('purchase.json', purchase);
    await rpc(url, 'devnet_increaseTime', { time: 3600 });
  }

  const active = await state(url, s, buyer); save('before-unwind.json', active);
  const rate = BigInt(active.order[0]), liquidity = BigInt(active.lp[4]);
  assert(rate > 0n && liquidity > 0n);
  // One atomic unwind. Remaining sale inventory and all sale proceeds go back
  // to TicketMaster; liquidity principal/fees return to the founding multisig.
  const unwind = [
    txCall(A.ticket, 'withdraw_erc721', [A.nft, ...u256(orderId)]),
    txCall(A.ticket, 'withdraw_erc721', [A.nft, ...u256(lpId)]),
    txCall(A.positions, 'withdraw_proceeds_from_sale_to', [orderId, ...key, A.ticket]),
    txCall(A.positions, 'decrease_sale_rate_to', [orderId, ...key, rate, A.ticket]),
    txCall(A.positions, 'withdraw', [lpId, ...pool, ...bounds, liquidity,
      BigInt(active.lp[5]) * 99n / 100n, BigInt(active.lp[6]) * 99n / 100n, 1]),
  ];
  save('unwind-bundle.json', { status: 'FORK_REHEARSAL_ONLY', scenario, forkBlock: s.block,
    calls: unwind, notes: 'State-dependent rate/liquidity/minimums; regenerate and simulate before any live signing.' });
  if (buyer) {
    // Fail after all recovery calls: none of their NFT/token changes may persist.
    const rejected = await submitLocal(url, A.owner, [...unwind, txCall(A.ticket, 'rollback_rehearsal_missing_entrypoint')], 'unwind-deliberate-revert', 'REVERTED');
    assert.match(rejected.revert_reason, /0x5, .*ENTRYPOINT_NOT_FOUND/s,
      'Negative control must fail at the sixth call, after all five recovery calls');
    const failed = await state(url, s, buyer); save('after-reverted-unwind.json', failed);
    assert(same(failed.orderOwner[0], A.ticket) && same(failed.lpOwner[0], A.ticket));
    assert.equal(BigInt(failed.order[0]), rate, 'Failed cancellation must leave sale rate active');
    assert.equal(BigInt(failed.lp[4]), liquidity, 'Failed withdrawal must leave LP funded');
    for (const token of ['lords', 'ticket']) for (const who of ['owner', 'ticket'])
      assert.equal(failed.balances[`${token}_${who}`], active.balances[`${token}_${who}`], 'Failed unwind must not transfer capital or sale proceeds');
  }
  await submitLocal(url, A.owner, unwind, 'unwind');
  const stopped = await state(url, s, buyer); save('after-unwind.json', stopped);
  assert(stopped.order.every(x => BigInt(x) === 0n), 'Order rate, unsold inventory and unclaimed proceeds must be zero');
  assert(stopped.lp.slice(4).every(x => BigInt(x) === 0n), 'LP liquidity, principal and fees must be zero');
  assert(stopped.aggregateRates.slice(0, 2).every(x => BigInt(x) === 0n), 'Aggregate TWAMM rates must be zero');
  assert.equal(BigInt(stopped.poolLiquidity[0]), 0n);
  assert(same(stopped.orderOwner[0], A.owner) && same(stopped.lpOwner[0], A.owner));

  // Optional empty-pool price restoration, keeping it separate from recovery.
  const oldPrice = integer(before.poolPrice.slice(0, 2));
  const currentPrice = integer(stopped.poolPrice.slice(0, 2));
  assert(oldPrice > currentPrice, 'Expected the original empty-pool price above the restarted price');
  const resetPrice = [transfer(A.ticket, A.router, 1n),
    txCall(A.router, 'swap', [...pool, ...u256(oldPrice), 0, A.ticket, 1, 0]),
    txCall(A.router, 'clear', [A.ticket]), txCall(A.router, 'clear', [A.lords])];
  save('restore-empty-price-bundle.json', { status: 'FORK_REHEARSAL_ONLY', calls: resetPrice });
  await submitLocal(url, A.owner, resetPrice, 'restore-empty-price');
  const after = await state(url, s, buyer); save('after.json', after);
  assert.deepEqual(after.poolPrice.map(BigInt), before.poolPrice.map(BigInt), 'Original empty-pool price must be restored');
  for (const name of Object.keys(before.getters)) assert.deepEqual(after.getters[name].map(BigInt), before.getters[name].map(BigInt), `${name} must stay unchanged`);
  for (const name of Object.keys(before.classes)) assert(same(after.classes[name], before.classes[name]));
  for (const token of ['lords', 'ticket', 'survivor']) {
    for (const recipient of ['dao', 'velords']) assert.equal(after.balances[`${token}_${recipient}`], before.balances[`${token}_${recipient}`], 'Unwind must not touch revenue recipients');
  }
  assert(after.balances.lords_ticket >= before.balances.lords_ticket, 'Old proceeds must be preserved');
  if (buyer) assert.equal(after.balances.ticket_buyer - before.balances.ticket_buyer, purchase.receivedTickets, 'Buyer keeps purchased tickets');
  const deltas = Object.fromEntries(Object.keys(before.balances).map(name => [name, after.balances[name] - before.balances[name]]));
  // Restart preflight must accept the recovered setup again.
  buildProposal({ ...s, ...after, threshold: s.threshold }, at);
  const combined = token => ['owner', 'ticket', ...(buyer ? ['buyer'] : [])]
    .reduce((sum, who) => sum + deltas[`${token}_${who}`], 0n);
  const result = { passed: true, scenario, forkBlock: s.block, buyer: buyer || null,
    buyerFundingBeforeBaseline: buyer ? '31 LORDS from multisig; local test fixture only' : null,
    purchase, unwindCalls: unwind.length, emptyPriceRestorationCalls: resetPrice.length,
    deltas, combinedTrackedDelta: { lords: combined('lords'), ticket: combined('ticket') },
    exactTrackedBalancesRestored: Object.values(deltas).every(value => value === 0n),
    operationalStateRestored: true, originalEmptyPoolPriceRestored: true,
    configurationUnchanged: true, restartPreflightPassed: true, failedUnwindAtomicityChecked: Boolean(buyer),
    limits: ['Local impersonation skips signatures; local fee funding is excluded.',
      'Block history, account nonces, oracle/TWAMM timestamps and executed trades are not rolled back.',
      'New sale proceeds remain on TicketMaster for its existing revenue split.',
      'No legacy buyback claimed, proceeds distributed or issuance transition invoked in these scenarios.'] };
  save('result.json', result);
  console.log(JSON.stringify(result, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2));
}

async function main() {
  fs.mkdirSync(output, { recursive: true });
  fs.rmSync(path.join(output, 'result.json'), { force: true });
  save('run-status.json', { status: 'running', scenario });
  let proxy;
  try {
    proxy = await startForkProxy({ cacheDirectory: '/workspace/.scratch/beast-mode-rollback/rpc-cache' });
    save('fork-proxy.json', { pid: process.pid, url: proxy.url });
    const snapshot = await inspect(proxy.url);
    await rehearse(snapshot, run, proxy.url);
    save('run-status.json', { status: 'passed', scenario });
  } catch (error) { save('run-status.json', { status: 'failed', scenario, error: error.message }); throw error; }
  finally { if (proxy) { await proxy.close(); save('fork-proxy.json', { pid: process.pid, stopped: true }); } }
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
