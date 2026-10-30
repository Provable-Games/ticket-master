#!/usr/bin/env node
'use strict';
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { hash, Account, RpcProvider, constants } = require('starknet');
const mode = process.argv[2] || 'lords';
assert(['lords', 'survivor'].includes(mode), 'Usage: node controller-rehearsal.cjs [lords|survivor]');
const output = path.resolve(process.env.BEAST_RESTART_OUTPUT || `/workspace/.scratch/beast-mode-controller/${mode}`);
process.env.BEAST_RESTART_OUTPUT = output;
const { A, inspect, rehearse, rpc, call, balance, txCall, transfer, integer, save, bounds, u256, submitLocal, declareLocal, alignedTime, sqrt } = require('./restart.cjs');
const { buildProposal } = require('./web/proposal.cjs');
const { startForkProxy } = require('./fork-proxy.cjs');
const eq = (a, b) => BigInt(a) === BigInt(b);
const staged = process.env.BEAST_CONTROLLER_STAGED === '1';
assert(!staged || mode === 'lords');
const unit = 10n ** 18n;
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const status = async (url, controller) => (await call(url, controller, 'status')).map(BigInt);
const expectReason = (receipt, text) => assert(receipt.revert_reason.includes(text) || receipt.revert_reason.includes(Buffer.from(text).toString('hex')), `Expected revert: ${text}`);

async function run(url, s) {
  const payment = A[mode], other = mode === 'lords' ? A.survivor : A.lords;
  const oldProceeds = await balance(url, A.lords, A.ticket);
  const g = s.getters, fee = g.get_buyback_order_config[4];
  let pool = g.get_distribution_pool_key, key = g.get_distribution_order_key;
  let orderId = g.get_position_token_id[0], lpId = g.get_liquidity_position_id[0];
  const head = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
  const at = Math.max(head.timestamp + 1, s.timestamp + 300);
  await rpc(url, 'devnet_setTime', { time: at, generate_block: true });
  const original = buildProposal(s, at);
  let sqrtPrice = BigInt(original.sqrtPrice), seedPayment = BigInt(original.seedLords), seedTickets = BigInt(original.seedTickets);
  let legacySurvivorToDao = 0n, imported = 0n, handoverPending = 0n, controller, declared;
  const artifact = path.resolve(process.env.BEAST_CONTROLLER_ARTIFACTS || '/workspace/.scratch/beast-mode-controller/target/dev');
  const sierra = read(path.join(artifact, 'beast_controller_trial_TrialController.contract_class.json'));
  const casm = read(path.join(artifact, 'beast_controller_trial_TrialController.compiled_contract_class.json'));
  if (staged) {
    const { buildControllerProposal, controllerDeclaration } = await import('./web/controller-proposal.mjs');
    const { simulate } = await import('./web/protocol.mjs');
    // Stage one executes independently, then let the original sale trade.
    await submitLocal(url, A.owner, original.calls, 'separate-original-restart');
    await submitLocal(url, A.owner, [transfer(A.lords, A.router, 31n * unit),
      txCall(A.router, 'swap', [...pool, ...u256(sqrtPrice * 99n / 100n), 0, A.lords, 31n * unit, 0]),
      txCall(A.router, 'clear', [A.ticket]), txCall(A.router, 'clear', [A.lords])], 'purchase-before-handover');
    await rpc(url, 'devnet_increaseTime', { time: 3600 });
    const liveHead = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
    const snapshot = { ...s, block: liveHead.block_number, timestamp: liveHead.timestamp, header: liveHead,
      balances: { ...s.balances }, legacyBuybacks: s.buybacks, controllerDeclared: false,
      order: await call(url, A.positions, 'get_order_info', [orderId, ...key]),
      lp: await call(url, A.positions, 'get_token_info', [lpId, ...pool, ...bounds]),
      poolLiquidity: await call(url, A.core, 'get_pool_liquidity', pool),
      orderOwner: await call(url, A.nft, 'owner_of', u256(orderId)),
      lpOwner: await call(url, A.nft, 'owner_of', u256(lpId)) };
    assert(BigInt(snapshot.order[2]) > 0n, 'Running sale must have unclaimed LORDS before handover');
    snapshot.balances.lords_ticket = await balance(url, A.lords, A.ticket);
    const walletBefore = { lords: await balance(url, A.lords, A.owner), ticket: await balance(url, A.ticket, A.owner) };
    const proposal = buildControllerProposal(snapshot);
    save('controller-staging-bundle.json', proposal);
    assert.equal(hash.computeSierraContractClassHash(sierra), proposal.controllerClassHash);
    const header = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
    const simulation = await simulate((method, params) => rpc(url, method, params), { ...snapshot, block: header.block_number, header }, proposal, controllerDeclaration);
    save('controller-staging-simulation.json', simulation);
    assert.equal(simulation.declarationSimulated, true);
    controller = proposal.controller;
    declared = await declareLocal(url, A.owner, sierra, casm);
    const beforeDao = await balance(url, A.survivor, A.dao);
    // A bad final call must revert the complete restart, custody and funding.
    await submitLocal(url, A.owner, [...proposal.calls, txCall(controller, 'missing_entrypoint')], 'staged-batch-atomic-revert', 'REVERTED');
    assert.equal(await balance(url, A.lords, A.ticket), oldProceeds);
    assert(eq((await call(url, A.nft, 'owner_of', u256(orderId)))[0], A.ticket));
    assert.equal((await call(url, A.positions, 'get_order_info', [orderId, ...key]))[0], snapshot.order[0]);
    await submitLocal(url, A.owner, proposal.calls, 'staged-controller-handover');
    legacySurvivorToDao = await balance(url, A.survivor, A.dao) - beforeDao;
    imported = oldProceeds;
    assert.equal(await balance(url, A.lords, A.ticket), 0n);
    handoverPending = (await status(url, controller))[1];
    assert(handoverPending >= imported + BigInt(snapshot.order[2]));
    assert.equal(await balance(url, A.lords, A.owner), walletBefore.lords);
    assert.equal(await balance(url, A.ticket, A.owner), walletBefore.ticket);
    assert.equal((await call(url, A.positions, 'get_order_info', [orderId, ...key]))[0], snapshot.order[0]);
    assert.equal((await call(url, A.positions, 'get_token_info', [lpId, ...pool, ...bounds]))[4], snapshot.lp[4]);
    assert.deepEqual(await call(url, A.lords, 'allowance', [A.owner, controller]), ['0x0', '0x0']);
    assert.equal(BigInt((await call(url, A.ticket, 'get_buyback_order_key_bookmark'))[0]), BigInt(s.getters.get_buyback_order_key_counter[0]));
    // A third party cannot add supposed proceeds or pull the owner's tokens.
    const local = (await rpc(url, 'devnet_getPredeployedAccounts'))[0];
    const signer = new Account({ provider: new RpcProvider({ nodeUrl: url }), address: local.address, signer: local.private_key, cairoVersion: '1' });
    const denied = await submitLocal(url, local.address, [txCall(controller, 'import_proceeds', [1])], 'unauthorized-import', 'REVERTED', signer);
    expectReason(denied, 'Caller is not the owner');
    await submitLocal(url, A.owner, [txCall(controller, 'import_proceeds', [imported])], 'repeat-import-without-allowance', 'REVERTED');
    assert.equal((await status(url, controller))[1], handoverPending);
  } else if (mode === 'lords') {
    await submitLocal(url, A.owner, original.calls, 'original-restart');
    // This NFT also holds legacy buybacks. Settle them before replacing custody.
    const before = await balance(url, A.survivor, A.dao);
    if (s.buybacks.length) await submitLocal(url, A.owner, [txCall(A.ticket, 'claim_and_distribute_buybacks', [0])], 'settle-legacy-buyback');
    legacySurvivorToDao = await balance(url, A.survivor, A.dao) - before;
    await submitLocal(url, A.owner, [txCall(A.ticket, 'withdraw_erc721', [A.nft, ...u256(orderId)]),
      txCall(A.ticket, 'withdraw_erc721', [A.nft, ...u256(lpId)])], 'withdraw-position-nfts');
  } else {
    pool = [A.survivor, A.ticket, 0, 354892, A.extension];
    key = [A.ticket, A.survivor, 0, 0, g.get_distribution_order_key[4]];
    const empty = await call(url, A.positions, 'get_pool_price', pool);
    assert(empty.every(x => BigInt(x) === 0n), 'SURVIVOR pool already initialized; review before using this trial');
    const quote = await call(url, A.positions, 'get_pool_price', [A.lords, A.survivor, fee, 354892, A.extension]);
    const quoteSqrt = integer(quote.slice(0, 2)); assert(quoteSqrt > 0n);
    const desired = sqrtPrice * (1n << 128n) / quoteSqrt;
    const tick = Math.round(2 * Math.log(Number(desired) / 2 ** 128) / Math.log(1.000001));
    const nextId = BigInt((await call(url, A.nft, 'get_next_token_id'))[0]);
    lpId = nextId; orderId = nextId + 1n;
    await submitLocal(url, A.owner, [txCall(A.core, 'initialize_pool', [...pool, Math.abs(tick), tick < 0 ? 1 : 0]),
      txCall(A.positions, 'mint_v2', [0]), txCall(A.positions, 'mint_v2', [0])], 'create-survivor-pool-and-nfts');
    sqrtPrice = integer((await call(url, A.positions, 'get_pool_price', pool)).slice(0, 2));
    seedPayment = BigInt(original.seedLords) * quoteSqrt * quoteSqrt / (1n << 256n);
    seedTickets = seedPayment * sqrtPrice * sqrtPrice / (1n << 256n) + 2n;
    assert(seedPayment < await balance(url, payment, A.owner));
    save('survivor-setup.json', { quote, tick, seedPayment, seedTickets, sqrtPrice, pool, key, orderId, lpId,
      note: 'Fresh fork quote converts the original LORDS price and seed to SURVIVOR; this is not a mainnet quote.' });
    await submitLocal(url, A.owner, [transfer(payment, A.positions, seedPayment), transfer(A.ticket, A.positions, seedTickets),
      txCall(A.positions, 'deposit_amounts', [lpId, ...pool, ...bounds, seedPayment, seedTickets, sqrt(seedPayment * seedTickets) * 99n / 100n]),
      txCall(A.positions, 'clear', [payment]), txCall(A.positions, 'clear', [A.ticket]),
      txCall(A.ticket, 'withdraw_erc20', [A.ticket, ...u256(original.restoreTickets)]),
      transfer(A.ticket, A.positions, BigInt(original.restoreTickets)),
      txCall(A.positions, 'increase_sell_amount', [orderId, ...key, original.restoreTickets]),
      txCall(A.positions, 'clear', [A.ticket])], 'seed-survivor-and-refill-sale');
  }

  if (!staged) {
    declared = await declareLocal(url, A.owner, sierra, casm);
    const constructor = [A.owner, A.positions, A.nft, A.lords, A.survivor, A.dao, A.velords, ...pool, ...key, ...bounds, orderId, lpId].map(x => `0x${BigInt(x).toString(16)}`);
    const salt = mode === 'lords' ? 1042 : 2080;
    controller = hash.calculateContractAddressFromHash(salt, declared.classHash, constructor, 0);
    await submitLocal(url, A.owner, [txCall(constants.UDC.ADDRESS, constants.UDC.ENTRYPOINT,
      [declared.classHash, salt, 0, constructor.length, ...constructor])], 'deploy-controller');
    assert(eq((await call(url, controller, 'owner'))[0], A.owner));
    await submitLocal(url, A.owner, [txCall(A.nft, 'transfer_from', [A.owner, controller, ...u256(orderId)]),
      txCall(A.nft, 'transfer_from', [A.owner, controller, ...u256(lpId)])], 'adopt-position-nfts');
  }
  for (const id of [orderId, lpId]) assert(eq((await call(url, A.nft, 'owner_of', u256(id)))[0], controller));
  assert.deepEqual(await status(url, controller), [0n, handoverPending, 0n, 0n]);
  save('controller.json', { status: 'FORK_ONLY', mode, controller, ...declared, pool, key, orderId, lpId });
  console.log(`${mode}: controller owns order and LP NFTs`);

  const local = (await rpc(url, 'devnet_getPredeployedAccounts'))[0];
  const buyer = new Account({ provider: new RpcProvider({ nodeUrl: url }), address: local.address, signer: local.private_key, cairoVersion: '1' });
  const amount = seedPayment * 31n / 10000n, donation = 7n * unit;
  await submitLocal(url, A.owner, [transfer(payment, local.address, amount), transfer(payment, controller, donation)], 'fund-buyer-and-unrelated-donation');
  const buyerBefore = await balance(url, A.ticket, local.address);
  await submitLocal(url, local.address, [transfer(payment, A.router, amount),
    txCall(A.router, 'swap', [...pool, ...u256(sqrtPrice * 99n / 100n), 0, payment, amount, 0]),
    txCall(A.router, 'clear', [A.ticket]), txCall(A.router, 'clear', [payment])], 'buyer-purchase', 'SUCCEEDED', buyer);
  const buyerTickets = await balance(url, A.ticket, local.address) - buyerBefore; assert(buyerTickets > 0n);
  await rpc(url, 'devnet_increaseTime', { time: 3600 });
  await submitLocal(url, A.owner, [txCall(controller, 'claim')], 'controller-claim');
  const claimed = (await status(url, controller))[1]; assert(claimed > 0n);
  assert.equal(await balance(url, payment, controller), claimed + donation, 'Unrelated donation must not enter proceeds ledger');
  const denied = await submitLocal(url, local.address, [txCall(controller, 'pause_sale')], 'unauthorized-pause', 'REVERTED', buyer);
  expectReason(denied, 'Caller is not the owner');
  const premature = await submitLocal(url, A.owner, [txCall(controller, 'withdraw_lp', [0, 0])], 'active-lp-withdrawal-refused', 'REVERTED');
  expectReason(premature, 'PAUSE_FIRST');
  await submitLocal(url, A.owner, [txCall(controller, 'pause_sale')], 'controller-pause');
  assert((await call(url, A.positions, 'get_order_info', [orderId, ...key])).every(x => BigInt(x) === 0n));
  assert.equal((await status(url, controller))[0], 1n);

  // Prove that a pause can be followed by a deliberately funded new rate.
  const refill = 1000n * unit;
  await submitLocal(url, A.owner, [txCall(A.ticket, 'withdraw_erc20', [A.ticket, ...u256(refill)]),
    transfer(A.ticket, controller, refill), txCall(controller, 'refill_sale', [refill])], 'controller-refill');
  assert(BigInt((await call(url, A.positions, 'get_order_info', [orderId, ...key]))[0]) > 0n);
  await submitLocal(url, A.owner, [txCall(controller, 'pause_sale')], 'controller-pause-again');
  const pending = (await status(url, controller))[1];
  const ownerBeforeSurplus = await balance(url, payment, A.owner);
  await submitLocal(url, A.owner, [txCall(controller, 'recover_surplus', [payment])], 'recover-unrelated-donation');
  assert.equal(await balance(url, payment, A.owner) - ownerBeforeSurplus, donation);
  assert.equal((await status(url, controller))[1], pending, 'Surplus recovery must preserve proceeds');
  const lp = await call(url, A.positions, 'get_token_info', [lpId, ...pool, ...bounds]);
  const ownerBeforeLp = await balance(url, payment, A.owner);
  await submitLocal(url, A.owner, [txCall(controller, 'withdraw_lp', [BigInt(lp[5]) * 99n / 100n, BigInt(lp[6]) * 99n / 100n])], 'controller-withdraw-lp');
  const lpPaymentReturned = await balance(url, payment, A.owner) - ownerBeforeLp;
  assert(lpPaymentReturned > 0n);
  assert.equal(await balance(url, payment, controller), pending, 'LP capital must not remain mixed with sale proceeds');
  assert.equal((await status(url, controller))[1], pending);
  const directRecipient = mode === 'survivor' ? A.dao : A.velords;
  const convertedRecipient = mode === 'survivor' ? A.velords : A.dao;
  let directTotal = 0n, convertedTotal = 0n, conversionPrincipal = 0n;
  const distributions = [];
  for (let cycle = 0; cycle < 4; cycle++) {
    const [, salePending, dust] = await status(url, controller);
    if (salePending === 0n && dust === 0n) break;
    const now = await rpc(url, 'starknet_getBlockWithTxHashes', { block_id: 'latest' });
    const end = alignedTime(now.timestamp, 4 * 86400);
    const recipientBefore = await balance(url, payment, directRecipient);
    await submitLocal(url, A.owner, [txCall(controller, 'distribute', [end])], `distribute-${cycle}`);
    const direct = await balance(url, payment, directRecipient) - recipientBefore;
    const expectedDirect = mode === 'survivor' ? salePending - salePending / 5n : salePending / 5n;
    assert.equal(direct, expectedDirect, 'Direct share must split only newly claimed proceeds');
    const principal = salePending - direct + dust;
    directTotal += direct; conversionPrincipal += principal;
    const afterDistribution = await status(url, controller);
    if (principal > 0n) {
      assert.equal(afterDistribution[3], 1n);
      const locked = await submitLocal(url, A.owner, [txCall(controller, 'release_positions')], `pending-conversion-release-refused-${cycle}`, 'REVERTED');
      expectReason(locked, 'PAUSE_AND_SETTLE');
      const keyConversion = [payment, other, fee, 0, end];
      const info = await call(url, A.positions, 'get_order_info', [orderId, ...keyConversion]);
      assert(BigInt(info[0]) > 0n && BigInt(info[1]) > 0n);
      const targetBefore = await balance(url, other, convertedRecipient);
      await rpc(url, 'devnet_setTime', { time: end + 1, generate_block: true });
      await submitLocal(url, A.owner, [txCall(controller, 'claim_conversion', [end])], `settle-conversion-${cycle}`);
      const converted = await balance(url, other, convertedRecipient) - targetBefore;
      if (cycle === 0) assert(converted > 0n);
      convertedTotal += converted;
      distributions.push({ salePending, carriedConversionDust: dust, direct, principal, converted, end });
    } else distributions.push({ salePending, carriedConversionDust: dust, direct, principal, converted: 0n, end });
  }
  assert.deepEqual(await status(url, controller), [1n, 0n, 0n, 0n]);
  await submitLocal(url, A.owner, [txCall(controller, 'recover_surplus', [A.ticket]), txCall(controller, 'release_positions')], 'return-nfts-to-multisig');
  for (const id of [orderId, lpId]) assert(eq((await call(url, A.nft, 'owner_of', u256(id)))[0], A.owner));
  assert.equal(await balance(url, payment, controller), 0n);
  assert.equal(await balance(url, A.ticket, controller), 0n);
  assert.equal(await balance(url, A.lords, A.ticket), staged ? 0n : oldProceeds, 'Legacy proceeds must stay separate');
  assert(eq((await call(url, A.ticket, 'owner'))[0], A.owner));
  assert(eq((await call(url, controller, 'owner'))[0], A.owner));
  assert.equal(await balance(url, A.ticket, local.address) - buyerBefore, buyerTickets);
  assert.equal(BigInt((await call(url, A.core, 'get_pool_liquidity', pool))[0]), 0n);
  const result = { passed: true, mode, forkBlock: s.block, controller, ...declared,
    paymentToken: payment, ticketToken: A.ticket, pool, key, orderId, lpId, seedPayment, seedTickets,
    buyerPaid: amount, buyerTickets, legacySurvivorToDao, legacyLordsPreserved: staged ? 0n : oldProceeds, legacyLordsImported: imported, handoverPending, staged,
    newlyClaimedProceeds: pending, directTotal, conversionPrincipal, convertedTotal, distributions, lpPaymentReturned,
    checks: ['NFT custody in controller', 'separate signed buyer purchase', 'only-owner enforcement',
      'active LP withdrawal refused', 'pause and refill', 'unsold tickets returned to original token contract',
      'donation excluded from proceeds and recoverable', 'LP capital excluded from split',
      'direct split exact', 'conversion dust never split twice', 'real TWAMM conversion settlement',
      'release blocked while conversion pending', 'NFTs and LP capital recoverable', 'original token ownership unchanged'],
    limits: ['Fork prototype only; no mainnet deploy or wallet proposal.',
      'No automatic low-issuance/oracle keeper implementation.', 'No upgrade entrypoint; review is required before choosing production design.'] };
  save('result.json', result); console.log(JSON.stringify(result, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2));
}

async function main() {
  fs.mkdirSync(output, { recursive: true }); fs.rmSync(path.join(output, 'result.json'), { force: true });
  save('run-status.json', { status: 'running', mode });
  let proxy;
  try {
    proxy = await startForkProxy({ cacheDirectory: '/workspace/.scratch/beast-mode-rollback/rpc-cache' });
    const snapshot = await inspect(proxy.url); await rehearse(snapshot, run, proxy.url);
    save('run-status.json', { status: 'passed', mode });
  } catch (error) { save('run-status.json', { status: 'failed', mode, error: error.message }); throw error; }
  finally { if (proxy) await proxy.close(); }
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
