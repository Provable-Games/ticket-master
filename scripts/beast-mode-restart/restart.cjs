#!/usr/bin/env node
'use strict';

// This program never submits a mainnet transaction. Writes are restricted to the
// freshly spawned, loopback Devnet whose upstream is the pinned read-only fork.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const net = require('node:net');
const { hash } = require('starknet');

const MAINNET = 'https://api.cartridge.gg/x/starknet/mainnet/rpc/v0_10';
const A = {
  ticket: '0x0452810188c4cb3aebd63711a3b445755bc0d6c4f27b923fdd99b1a118858136',
  owner: '0x0248f76e72088853c3fe96cad8f7f075c9e514b862a6e9a3d5957ea5522ebb6d',
  lords: '0x0124aeb495b947201f5fac96fd1138e326ad86195b98df6dec9009158a533b49',
  survivor: '0x042dd777885ad2c116be96d4d634abc90a26a790ffb5871e037dd5ae7d2ec86b',
  dao: '0x041bb7729efa185f2cab327de0a668886302f1d4969e3edf504c4741648f858b',
  velords: '0x045c587318c9ebcf2fbe21febf288ee2e3597a21cd48676005a5770a50d433c5',
  positions: '0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067',
  nft: '0x07b696af58c967c1b14c9dde0ace001720635a660a8e90c565ea459345318b30',
  core: '0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b',
  router: '0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e',
  extension: '0x043e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc',
};
const OUTPUT = path.resolve(process.env.BEAST_RESTART_OUTPUT || '/workspace/.scratch/beast-mode-restart');
const hex = x => `0x${BigInt(x).toString(16)}`;
const u256 = x => [hex(BigInt(x) & ((1n << 128n) - 1n)), hex(BigInt(x) >> 128n)];
const integer = r => BigInt(r[0]) + (r.length === 2 ? BigInt(r[1]) << 128n : 0n);
const eq = (a, b) => BigInt(a) === BigInt(b);
const json = x => JSON.stringify(x, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);
const save = (name, value) => fs.writeFileSync(path.join(OUTPUT, name), `${json(value)}\n`);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const bounds = [88368108, 1, 88368108, 0];

async function rpc(url, method, params = {}) {
  // Retry read-only calls only. Never retry a potentially accepted write.
  const attempts = method.startsWith('starknet_get') || method === 'starknet_call' || method === 'starknet_blockNumber' ? 4 : 1;
  for (let i = 0; i < attempts; i++) {
    try {
      const response = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: json({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(new URL(url).hostname === '127.0.0.1' ? 330000 : 120000),
      });
      const result = await response.json();
      if (result.error) throw new Error(`${method}: ${json(result.error)}`);
      if (!response.ok) throw new Error(`${method}: HTTP ${response.status}`);
      return result.result;
    } catch (error) {
      if (i + 1 === attempts) throw error;
      await delay(300 * (i + 1));
    }
  }
}

const call = (url, address, entrypoint, calldata = [], block = 'latest') => rpc(url, 'starknet_call', {
  request: { contract_address: address, entry_point_selector: hash.getSelectorFromName(entrypoint), calldata: calldata.map(hex) },
  block_id: block,
});
const balance = async (url, token, who) => integer(await call(url, token, 'balance_of', [who]));
const txCall = (address, entrypoint, calldata = []) => ({ contractAddress: address, entrypoint, calldata: calldata.map(hex) });
const transfer = (token, to, amount) => txCall(token, 'transfer', [to, ...u256(amount)]);

async function inspect(readUrl = MAINNET) {
  assert.equal(await rpc(readUrl, 'starknet_chainId'), '0x534e5f4d41494e');
  const block = { block_number: Number(process.env.BEAST_RESTART_BLOCK || await rpc(readUrl, 'starknet_blockNumber')) };
  const head = await rpc(readUrl, 'starknet_getBlockWithTxHashes', { block_id: block });
  const result = { block: block.block_number, blockHash: head.block_hash, timestamp: head.timestamp, addresses: A, getters: {}, classes: {} };
  const names = ['owner', 'get_distribution_order_key', 'get_distribution_pool_key', 'get_position_token_id',
    'get_liquidity_position_id', 'get_token_distribution_rate', 'get_distribution_initial_tick',
    'is_low_issuance_mode', 'get_issuance_reduction_bips', 'get_deployment_state',
    'get_payment_token', 'get_buyback_token', 'get_buyback_order_config', 'get_buyback_order_key_bookmark',
    'get_buyback_order_key_counter', 'get_treasury_address', 'get_velords_address'];
  for (const name of names) result.getters[name] = await call(readUrl, A.ticket, name, [], block);
  for (const key of ['ticket', 'positions', 'core', 'nft', 'router', 'extension', 'owner']) {
    result.classes[key] = await rpc(readUrl, 'starknet_getClassHashAt', { block_id: block, contract_address: A[key] });
    const cls = await rpc(readUrl, 'starknet_getClassAt', { block_id: block, contract_address: A[key] });
    save(`abi-${key}.json`, typeof cls.abi === 'string' ? JSON.parse(cls.abi) : cls.abi);
  }
  const g = result.getters;
  result.order = await call(readUrl, A.positions, 'get_order_info', [...g.get_position_token_id, ...g.get_distribution_order_key], block);
  result.lp = await call(readUrl, A.positions, 'get_token_info', [...g.get_liquidity_position_id, ...g.get_distribution_pool_key, ...bounds], block);
  result.poolPrice = await call(readUrl, A.positions, 'get_pool_price', g.get_distribution_pool_key, block);
  result.poolLiquidity = await call(readUrl, A.core, 'get_pool_liquidity', g.get_distribution_pool_key, block);
  result.orderOwner = await call(readUrl, A.nft, 'owner_of', [...g.get_position_token_id, 0], block);
  result.lpOwner = await call(readUrl, A.nft, 'owner_of', [...g.get_liquidity_position_id, 0], block);
  result.balances = {};
  for (const token of ['ticket', 'lords', 'survivor']) {
    for (const who of ['ticket', 'owner']) result.balances[`${token}_${who}`] = integer(await call(readUrl, A[token], 'balance_of', [A[who]], block));
  }
  const bookmark = BigInt(g.get_buyback_order_key_bookmark[0]);
  const counter = BigInt(g.get_buyback_order_key_counter[0]);
  result.buybacks = [];
  assert(counter - bookmark < 100n, 'Unexpected buyback backlog; review before proceeding');
  for (let index = bookmark; index < counter; index++) {
    const end = (await call(readUrl, A.ticket, 'get_buyback_order_key_end_time', [index], block))[0];
    const key = await call(readUrl, A.ticket, 'get_buyback_order_key', [0, end], block);
    const info = await call(readUrl, A.positions, 'get_order_info', [...g.get_position_token_id, ...key], block);
    result.buybacks.push({ index, key, info });
  }
  result.aggregateRates = await call(readUrl, A.extension, 'get_sale_rate_and_last_virtual_order_time', g.get_distribution_pool_key.slice(0, 3), block);
  result.threshold = await call(readUrl, A.owner, 'get_threshold', [], block);
  save('snapshot.json', result);
  console.log(`Pinned mainnet block ${result.block}; order=${result.order}; owner LORDS=${result.balances.lords_owner}`);
  return result;
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

function validateSnapshot(s) {
  const g = s.getters;
  assert(eq(g.owner[0], A.owner));
  assert(eq(s.classes.ticket, '0x05c668438529906abdd5f04cbe44c9919c40a811f922cbdc59630f3116c0fd8f'),
    'TicketMaster class changed; review before proceeding');
  assert(eq(g.get_payment_token[0], A.lords));
  assert(eq(g.get_buyback_token[0], A.survivor));
  assert(eq(g.get_treasury_address[0], A.dao));
  assert(eq(g.get_velords_address[0], A.velords));
  assert(eq(s.orderOwner[0], A.owner) && eq(s.lpOwner[0], A.owner), 'NFT custody changed');
  assert(s.order.every(x => BigInt(x) === 0n), 'Order no longer empty');
  assert.equal(BigInt(s.poolLiquidity[0]), 0n, 'Pool no longer empty');
  assert(s.lp.slice(4).every(x => BigInt(x) === 0n), 'LP principal or fees changed');
  assert(s.aggregateRates.slice(0, 2).every(x => BigInt(x) === 0n), 'Another TWAMM order is active');
  assert.equal(BigInt(g.get_deployment_state[0]), 3n);
  assert.equal(BigInt(g.is_low_issuance_mode[0]), 1n);
  assert(BigInt(g.get_token_distribution_rate[0]) > 0n);
}

function executionCalldata(calls) {
  // Cairo 1 account Span<Call> encoding, also used by the live Argent multisig.
  return [hex(calls.length), ...calls.flatMap(c => [c.contractAddress, hash.getSelectorFromName(c.entrypoint), hex(c.calldata.length), ...c.calldata])];
}

async function submitLocal(url, sender, calls, label, expectedStatus = 'SUCCEEDED', localAccount) {
  assert.equal(new URL(url).hostname, '127.0.0.1', 'Writes require loopback Devnet');
  assert.deepEqual(await rpc(url, 'devnet_getConfig'), configGuard);
  const nonce = await rpc(url, 'starknet_getNonce', { block_id: 'latest', contract_address: sender });
  const bound = { max_amount: '0x3b9aca00', max_price_per_unit: '0x2540be400' };
  let transaction = {
    type: 'INVOKE', version: '0x3', sender_address: sender, calldata: executionCalldata(calls), signature: [], nonce,
    resource_bounds: { l1_gas: bound, l1_data_gas: bound, l2_gas: bound },
    tip: '0x0', paymaster_data: [], account_deployment_data: [], nonce_data_availability_mode: 'L1', fee_data_availability_mode: 'L1',
  };
  if (localAccount) {
    assert(eq(localAccount.address, sender));
    const resource = { max_amount: 1000000000n, max_price_per_unit: 10000000000n };
    transaction = await localAccount.getSignedTransaction(calls, { nonce, tip: 0,
      resourceBounds: { l1_gas: resource, l1_data_gas: resource, l2_gas: resource } });
  }
  const sent = await rpc(url, 'starknet_addInvokeTransaction', { invoke_transaction: transaction });
  const receipt = await rpc(url, 'starknet_getTransactionReceipt', { transaction_hash: sent.transaction_hash });
  save(`receipt-${label}.json`, receipt);
  assert.equal(receipt.execution_status, expectedStatus, `${label}: ${receipt.revert_reason}`);
  // Advance the local pending context before view callbacks execute virtual
  // orders; never rewind below a transaction's recorded TWAMM timestamp.
  await rpc(url, 'devnet_increaseTime', { time: 1 });
  console.log(`${label}: ${receipt.execution_status.toLowerCase()}`);
  return receipt;
}

let configGuard;
async function declareLocal(url, sender, sierra, casm) {
  assert.equal(new URL(url).hostname, '127.0.0.1', 'Declarations require loopback Devnet');
  assert.deepEqual(await rpc(url, 'devnet_getConfig'), configGuard);
  const nonce = await rpc(url, 'starknet_getNonce', { block_id: 'latest', contract_address: sender });
  const head = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
  const bound = (name, amount) => ({ max_amount: hex(amount),
    max_price_per_unit: hex(BigInt(head[name]?.price_in_fri || '0x2540be400') * 2n) });
  const compiledClassHash = hash.computeCompiledClassHash(casm);
  const transaction = { type: 'DECLARE', version: '0x3', sender_address: sender, nonce, signature: [],
    compiled_class_hash: compiledClassHash,
    contract_class: { sierra_program: sierra.sierra_program, contract_class_version: sierra.contract_class_version,
      entry_points_by_type: sierra.entry_points_by_type, abi: JSON.stringify(sierra.abi) },
    resource_bounds: { l1_gas: bound('l1_gas_price', 100000n),
      l1_data_gas: bound('l1_data_gas_price', 100000000n), l2_gas: bound('l2_gas_price', 10000000000n) },
    tip: '0x0', paymaster_data: [], account_deployment_data: [], nonce_data_availability_mode: 'L1', fee_data_availability_mode: 'L1' };
  const sent = await rpc(url, 'starknet_addDeclareTransaction', { declare_transaction: transaction });
  const receipt = await rpc(url, 'starknet_getTransactionReceipt', { transaction_hash: sent.transaction_hash });
  save('receipt-declare-controller.json', receipt);
  assert.equal(receipt.execution_status, 'SUCCEEDED', receipt.revert_reason);
  await rpc(url, 'devnet_increaseTime', { time: 1 });
  return { classHash: sent.class_hash, compiledClassHash };
}

async function rehearse(s, runner = runRehearsal, forkNetwork = MAINNET) {
  validateSnapshot(s);
  assert(forkNetwork === MAINNET || new URL(forkNetwork).hostname === '127.0.0.1', 'Fork origin must be mainnet or an owned read-only loopback proxy');
  const binary = process.env.BEAST_RESTART_DEVNET;
  assert(binary, 'Set BEAST_RESTART_DEVNET to a starknet-devnet v0.10.1 binary');
  const port = await freePort();
  const url = `http://127.0.0.1:${port}/rpc`;
  const log = fs.openSync(path.join(OUTPUT, 'devnet.log'), 'w');
  const child = spawn(binary, ['--host', '127.0.0.1', '--port', String(port), '--seed', '42', '--accounts', '1',
    '--fork-network', forkNetwork, '--fork-block', String(s.block), '--start-time', String(s.timestamp), '--timeout', '300'],
  { stdio: ['ignore', log, log], env: { ...process.env, RAYON_NUM_THREADS: '2', TOKIO_WORKER_THREADS: '2' } });
  fs.closeSync(log);
  save('devnet-process.json', { pid: child.pid, port, forkBlock: s.block });
  try {
    for (let attempt = 0; ; attempt++) {
      try { configGuard = await rpc(url, 'devnet_getConfig'); break; }
      catch (error) { if (attempt > 90 || child.exitCode !== null) throw error; await delay(1000); }
    }
    assert(configGuard);
    await rpc(url, 'devnet_impersonateAccount', { account_address: A.owner });
    await rpc(url, 'devnet_mint', { address: A.owner, amount: 10 ** 22, unit: 'FRI' });
    await runner(url, s);
  } finally {
    child.kill('SIGTERM');
    await new Promise(resolve => {
      if (child.exitCode !== null) return resolve();
      const timer = setTimeout(() => child.kill('SIGKILL'), 10000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
    save('devnet-process.json', { pid: child.pid, port, stopped: true });
  }
}

async function runRehearsal(url, s) {
  const g = s.getters;
  const forkHead = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
  const executionTimestamp = Math.max(forkHead.timestamp + 1, s.timestamp + 300);
  await rpc(url, 'devnet_setTime', { time: executionTimestamp, generate_block: true });
  const metadata = require('./web/proposal.cjs').buildProposal(s, executionTimestamp);
  const pool = g.get_distribution_pool_key, orderKey = g.get_distribution_order_key;
  const orderId = g.get_position_token_id[0], lpId = g.get_liquidity_position_id[0];
  const bundle = metadata.calls;
  const [seedLords, seedTickets, sqrtPrice, minimumLiquidity, restoreTickets, storedRate] =
    ['seedLords', 'seedTickets', 'sqrtPrice', 'minimumLiquidity', 'restoreTickets', 'storedRateQ32'].map(k => BigInt(metadata[k]));
  save('restart-bundle.json', metadata);
  save('restart-calldata.json', executionCalldata(bundle));
  const restartReceipt = await submitLocal(url, A.owner, bundle, 'restart');
  const repricing = restartReceipt.events.find(event => eq(event.from_address, A.core)
    && eq(event.keys[0], hash.getSelectorFromName('Swapped')));
  assert(repricing, 'Expected pool repricing event');
  assert.equal(integer(repricing.data.slice(-5, -3)), sqrtPrice, 'Pool must reset to original initial tick');
  assert.deepEqual(repricing.data.slice(-3, -1).map(BigInt), g.get_distribution_initial_tick.map(BigInt));
  const after = {
    order: await call(url, A.positions, 'get_order_info', [orderId, ...orderKey]),
    price: await call(url, A.positions, 'get_pool_price', pool),
    liquidity: await call(url, A.core, 'get_pool_liquidity', pool),
    lp: await call(url, A.positions, 'get_token_info', [lpId, ...pool, ...bounds]),
    orderOwner: await call(url, A.nft, 'owner_of', [orderId, 0]),
    lpOwner: await call(url, A.nft, 'owner_of', [lpId, 0]),
    reserve: await balance(url, A.ticket, A.ticket),
    legacyLords: await balance(url, A.lords, A.ticket),
  };
  assert(eq(after.orderOwner[0], A.ticket) && eq(after.lpOwner[0], A.ticket));
  assert(BigInt(after.order[0]) > 0n);
  const rateDrift = BigInt(after.order[0]) - storedRate;
  // Fixed calldata is derived at the snapshot time; execution seconds later
  // causes a small, measurable drift over the original 130-year duration.
  assert(rateDrift >= 0n && rateDrift * 1000000000n <= storedRate * 100n,
    'Restart rate differs by more than 100 parts per billion; regenerate bundle');
  assert(BigInt(after.liquidity[0]) >= minimumLiquidity);
  assert.equal(after.reserve, BigInt(s.balances.ticket_ticket) - restoreTickets);
  assert.equal(after.legacyLords, BigInt(s.balances.lords_ticket));
  save('after-restart.json', after);

  // Claim the outstanding old buyback via the real deployed TicketMaster code.
  const daoBefore = await balance(url, A.survivor, A.dao);
  if (s.buybacks.length) {
    await submitLocal(url, A.owner, [txCall(A.ticket, 'claim_and_distribute_buybacks', [0])], 'legacy-buyback');
    const daoAfter = await balance(url, A.survivor, A.dao);
    assert(daoAfter > daoBefore, 'Legacy buyback must reach DAO');
    save('legacy-buyback-result.json', { survivorToDao: daoAfter - daoBefore,
      bookmark: await call(url, A.ticket, 'get_buyback_order_key_bookmark') });
  }

  // Real purchase with an explicit price limit (swap + clear in one account call).
  const ownerTicketBefore = await balance(url, A.ticket, A.owner);
  const ownerLordsBefore = await balance(url, A.lords, A.owner);
  const buyAmount = 31n * 10n ** 18n;
  await submitLocal(url, A.owner, [transfer(A.lords, A.router, buyAmount),
    txCall(A.router, 'swap', [...pool, ...u256(sqrtPrice * 99n / 100n), 0, A.lords, buyAmount, 0]),
    txCall(A.router, 'clear', [A.ticket]), txCall(A.router, 'clear', [A.lords])], 'purchase');
  const bought = await balance(url, A.ticket, A.owner) - ownerTicketBefore;
  assert(bought > 99n * 10n ** 16n && bought < 101n * 10n ** 16n, '31 LORDS should buy approximately one ticket');
  save('purchase-result.json', { paidLords: ownerLordsBefore - await balance(url, A.lords, A.owner), receivedTickets: bought });

  // Let the real TWAMM sell tickets; claim and distribute through the original
  // controller, verifying existing LORDS proceeds are split just once.
  await rpc(url, 'devnet_increaseTime', { time: 3600 });
  await submitLocal(url, A.owner, [txCall(A.ticket, 'claim_proceeds')], 'claim-sales');
  const proceeds = await balance(url, A.lords, A.ticket);
  assert(proceeds > after.legacyLords, 'Live ticket sales must produce LORDS');
  const veBefore = await balance(url, A.lords, A.velords);
  const current = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
  const end = alignedTime(current.timestamp, 4 * 86400);
  await submitLocal(url, A.owner, [txCall(A.ticket, 'distribute_proceeds', [end])], 'distribute-sales');
  assert.equal(await balance(url, A.lords, A.velords) - veBefore, proceeds / 5n);
  assert.equal(await balance(url, A.lords, A.ticket), 0n);
  const nextBuybackKey = await call(url, A.ticket, 'get_buyback_order_key', [0, end]);
  const nextBuyback = await call(url, A.positions, 'get_order_info', [orderId, ...nextBuybackKey]);
  assert(BigInt(nextBuyback[0]) > 0n && BigInt(nextBuyback[1]) > 0n);
  save('proceeds-result.json', { lordsProceeds: proceeds, lordsToVelords: proceeds / 5n,
    lordsForSurvivorBuyback: proceeds - proceeds / 5n, nextBuybackKey, nextBuyback });
  const daoBeforeNew = await balance(url, A.survivor, A.dao);
  await rpc(url, 'devnet_setTime', { time: end + 1, generate_block: true });
  await submitLocal(url, A.owner, [txCall(A.ticket, 'claim_and_distribute_buybacks', [0])], 'settle-sales');
  assert(await balance(url, A.survivor, A.dao) > daoBeforeNew);

  // Exercise both reserve transitions using the real stored rate and NFT owner.
  await submitLocal(url, A.owner, [txCall(A.ticket, 'force_disable_low_issuance_mode')], 'disable-low-issuance');
  assert.equal(BigInt((await call(url, A.ticket, 'is_low_issuance_mode'))[0]), 0n);
  await submitLocal(url, A.owner, [txCall(A.ticket, 'force_enable_low_issuance_mode')], 'enable-low-issuance');
  assert.equal(BigInt((await call(url, A.ticket, 'is_low_issuance_mode'))[0]), 1n);
  const finalActual = (await call(url, A.positions, 'get_order_info', [orderId, ...orderKey]))[0];
  const finalStored = (await call(url, A.ticket, 'get_token_distribution_rate'))[0];
  const drift = BigInt(finalActual) - BigInt(finalStored);
  assert((drift < 0n ? -drift : drift) * 1000000000n <= BigInt(finalStored) * 100n,
    'Issuance rate telemetry is materially inconsistent');
  save('result.json', { passed: true, forkBlock: s.block, seedLords, seedTickets, restoreTickets,
    initialActualRateQ32: after.order[0], initialStoredRateQ32: storedRate,
    finalActualRateQ32: finalActual, finalStoredRateQ32: finalStored, driftQ32: drift,
    checks: ['atomic restart', 'NFT custody', 'reserve preservation', 'legacy LORDS preservation',
      'legacy buyback claim', 'real ticket purchase', 'TWAMM ticket sales', '20% LORDS to veLords',
      '80% LORDS buyback', 'SURVIVOR to DAO', 'low-issuance disable and enable'] });
  console.log('All restart, trading, proceeds and issuance checks passed on local mainnet fork.');
}

function sqrt(n) {
  if (n < 2n) return n;
  let x = 1n << BigInt(Math.ceil(n.toString(2).length / 2));
  for (;;) { const next = (x + n / x) / 2n; if (next >= x) return x; x = next; }
}

function tickToSqrtRatio([magnitude, sign]) {
  const q = 1n << 256n;
  let power = BigInt(magnitude), base = q * 1000001n / 1000000n, result = q;
  while (power) { if (power & 1n) result = result * base / q; base = base * base / q; power >>= 1n; }
  if (BigInt(sign)) result = q * q / result;
  return sqrt(result);
}

function alignedTime(now, minimumDuration) {
  let step = 16;
  while (step * 16 <= minimumDuration) step *= 16;
  let target = Math.ceil((now + minimumDuration) / step) * step;
  while (true) {
    let required = 16;
    while (required * 16 <= target - now) required *= 16;
    if (target % required === 0) return target;
    target = Math.ceil(target / required) * required;
  }
}

async function main() {
  fs.mkdirSync(OUTPUT, { recursive: true });
  const mode = process.argv[2] || 'inspect';
  assert(['inspect', 'rehearse'].includes(mode), 'Usage: node restart.cjs [inspect|rehearse]');
  if (mode === 'rehearse') {
    // A failed rerun must never leave an old successful result as its verdict.
    fs.rmSync(path.join(OUTPUT, 'result.json'), { force: true });
    save('run-status.json', { status: 'running', startedAt: new Date().toISOString() });
  }
  try {
    const snapshot = await inspect();
    if (mode === 'rehearse') {
      await rehearse(snapshot);
      save('run-status.json', { status: 'passed', completedAt: new Date().toISOString() });
    }
  } catch (error) {
    if (mode === 'rehearse') save('run-status.json', { status: 'failed', error: error.message });
    throw error;
  }
}

if (require.main === module) main().catch(error => { console.error(error.stack); process.exitCode = 1; });
module.exports = { A, executionCalldata, validateSnapshot, u256, hex,
  inspect, rehearse, rpc, call, balance, txCall, transfer, integer, save, bounds, submitLocal, declareLocal, alignedTime, sqrt };
