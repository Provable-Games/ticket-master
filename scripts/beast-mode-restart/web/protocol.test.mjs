import { test } from 'node:test';
import assert from 'node:assert/strict';
import { A, config, buildProposal, openWalletReview, assertFresh, createRpc, simulate } from './protocol.mjs';

export function fixture() {
  return { block: 16418534, blockHash: '0x123', timestamp: 1792073067,
    classes: structuredClone(config.classes),
    getters: { ...structuredClone(config.getters), owner: [A.owner], get_payment_token: [A.lords],
      get_buyback_token: [A.survivor], get_treasury_address: [A.dao], get_velords_address: [A.velords],
      get_deployment_state: ['0x3'], is_low_issuance_mode: ['0x1'] },
    threshold: ['0x2'], orderOwner: [A.owner], lpOwner: [A.owner], order: ['0x0', '0x0', '0x0'],
    poolLiquidity: ['0x0'], lp: ['0x1', '0x0', '0x1', '0x0', '0x0', '0x0', '0x0', '0x0', '0x0'],
    aggregateRates: ['0x0', '0x0', '0x1'], balances: {
      lords_owner: '53855520609363178609392', ticket_owner: '22260890373785672224233',
      ticket_ticket: '99578848002815489878184241',
    } };
}

test('rebuilds the tested seed and active inventory with 14 calls and no ownership change', () => {
  const p = buildProposal(fixture());
  assert.equal(p.calls.length, 14);
  assert.equal(p.seedTickets, '322580619831775698905');
  assert.equal(p.restoreTickets, '49611300239693020746053278');
  assert.equal(p.minimumLiquidity, '1778092420255829566187');
  assert.equal(p.ownershipTransferIncluded, false);
  assert(!p.calls.some(c => c.entrypoint === 'transfer_ownership'));
  assert.equal(p.calls[8].calldata[1], p.calls[9].calldata[1]);
  assert.equal(p.calls[9].calldata[1], p.calls[10].calldata[6]);
});

for (const [name, mutate] of [
  ['changed Ekubo implementation', s => { s.classes.core = '0x1'; }],
  ['a different multisig threshold', s => { s.threshold = ['0x1']; }],
  ['an active sale', s => { s.order[0] = '0x1'; }],
  ['missing seed funds', s => { s.balances.lords_owner = '0'; }],
  ['a different sale end', s => { s.getters.get_distribution_order_key[4] = '0x123'; }],
]) test(`proposal refuses ${name}`, () => { const s = fixture(); mutate(s); assert.throws(() => buildProposal(s)); });

function wallet(account = A.owner, chain = '0x534e5f4d41494e') {
  const requests = [];
  return { requests, request: async r => {
    requests.push(r);
    if (r.type === 'wallet_requestAccounts') return [account];
    if (r.type === 'wallet_requestChainId') return chain;
    if (r.type === 'wallet_addInvokeTransaction') return { transaction_hash: '0x123' };
    throw new Error('Unexpected wallet request');
  } };
}

test('requests the complete reviewed batch exactly once using the standard wallet API', async () => {
  const w = wallet(), p = buildProposal(fixture());
  await openWalletReview(w, p);
  const sends = w.requests.filter(r => r.type === 'wallet_addInvokeTransaction');
  assert.equal(sends.length, 1);
  assert.deepEqual(sends[0].params.calls, p.calls.map(c => ({ contract_address: c.contractAddress, entry_point: c.entrypoint, calldata: c.calldata })));
});

for (const [name, w] of [['wrong account', wallet(A.dao)], ['wrong network', wallet(A.owner, '0x534e5f5345504f4c4941')]]) {
  test(`never invokes the wallet with ${name}`, async () => {
    await assert.rejects(openWalletReview(w, buildProposal(fixture())));
    assert(!w.requests.some(r => r.type === 'wallet_addInvokeTransaction'));
  });
}

test('a fifteen-call ownership variant cannot reach the wallet', async () => {
  const w = wallet(), p = buildProposal(fixture());
  p.calls.push({ contractAddress: A.ticket, entrypoint: 'transfer_ownership', calldata: [A.dao] });
  await assert.rejects(openWalletReview(w, p));
  assert(!w.requests.some(r => r.type === 'wallet_addInvokeTransaction'));
});

test('expired drafts are refused; future timestamps do not bypass expiry', () => {
  const p = buildProposal(fixture());
  assert.doesNotThrow(() => assertFresh(p, p.snapshotTimestamp + 239));
  assert.throws(() => assertFresh(p, p.snapshotTimestamp + 241));
  assert.throws(() => assertFresh(p, p.snapshotTimestamp - 31));
});

test('the RPC helper refuses transaction broadcast methods', async () => {
  let fetched = false;
  const rpc = createRpc(async () => { fetched = true; });
  await assert.rejects(rpc('starknet_addInvokeTransaction', {}));
  assert.equal(fetched, false);
});

test('a reverted or missing simulation cannot be reported successful', async () => {
  const s = fixture(); s.header = {};
  const p = buildProposal(s);
  const rpc = async method => method === 'starknet_getNonce' ? '0x1' : [{ transaction_trace: { execute_invocation: { revert_reason: 'Not authorized' } } }];
  await assert.rejects(simulate(rpc, s, p), /Not authorized/);
  await assert.rejects(simulate(async method => method === 'starknet_getNonce' ? '0x1' : [], s, p));
});

const { walletMovements, formatUnits } = await import('./movements.mjs');
const { hash } = await import('starknet');
const transferSelector = hash.getSelectorFromName('Transfer');
const rawTransfer = (from, to, low, high = '0x0', indexed = false, order = 0) => ({ order,
  keys: indexed ? [transferSelector, from, to] : [transferSelector],
  data: indexed ? [low, high] : [from, to, low, high] });
function movementTrace() {
  return { contract_address: A.owner, events: [], calls: [
    { contract_address: A.lords, events: [rawTransfer(A.owner, A.positions, '0x64'), rawTransfer(A.positions, A.owner, '0x2')], calls: [] },
    { contract_address: A.ticket, events: [rawTransfer(A.ticket, A.owner, '0x3e8', '0x1', true), rawTransfer(A.owner, A.positions, '0x3f2', '0x1', true), rawTransfer(A.positions, A.core, '0x3f2', '0x1', true)], calls: [] },
    { contract_address: A.nft, events: [rawTransfer(A.owner, A.ticket, '0x2250e9'), rawTransfer(A.owner, A.ticket, '0x2250e3')], calls: [] },
  ] };
}
test('gross receive and send retain pass-through inventory; net counts only wallet boundary', () => {
  const result = walletMovements(movementTrace());
  assert.deepEqual(result.totals[0], { asset: 'lords', symbol: 'LORDS', sent: '100', received: '2', net: '-98' });
  assert.equal(result.totals[1].received, (1000n + (1n << 128n)).toString());
  assert.equal(result.totals[1].sent, (1010n + (1n << 128n)).toString());
  assert.equal(result.totals[1].net, '-10');
  assert.equal(result.transfers.length, 6);
  assert.deepEqual(result.transfers.filter(t => t.asset === 'nft').map(t => t.tokenId), ['2248937', '2248931']);
});
test('missing or unsupported transfer events cannot produce a complete-looking summary', () => {
  const trace = movementTrace(); trace.calls[0].events = [];
  assert.throws(() => walletMovements(trace), /Missing LORDS/);
  const unsupported = movementTrace(); unsupported.calls[1].events[0].data.pop();
  assert.throws(() => walletMovements(unsupported), /Unrecognized transfer/);
});
test('full decimal formatting preserves tiny refunds and large ticket amounts exactly', () => {
  assert.equal(formatUnits('2'), '0.000000000000000002');
  assert.equal(formatUnits('-322580619831775698791'), '−322.580619831775698791');
  assert.equal(formatUnits('49611059365700000000000000'), '49,611,059.3657');
});

const { buildControllerProposal, validateControllerDraft, controllerRelease, controllerDeclaration } = await import('./controller-proposal.mjs');
const { openControllerReview, openDeclarationReview } = await import('./controller-protocol.mjs');
function controllerFixture() {
  return { ...fixture(), controllerDeclared: false, orderOwner: [A.ticket], lpOwner: [A.ticket],
    order: ['0x123', '0x1000', '0x99'], poolLiquidity: ['0x888'],
    lp: ['0x1', '0x0', '0x1', '0x0', '0x888', '0x1000', '0x1000', '0x0', '0x0'],
    balances: { ...fixture().balances, lords_ticket: '5788620457280262621088' },
    legacyBuybacks: [{ key: [A.lords, A.survivor, '0x1', '0x0', '1791819776'], info: ['0x0', '0x0', '0x12'] }] };
}
test('controller handover preserves LORDS parameters, settles old buybacks and imports proceeds separately from seed', () => {
  const p = buildControllerProposal(controllerFixture());
  assert.equal(p.route, 'LORDS_CONTROLLER_HANDOVER'); assert.equal(p.calls.length, 11);
  assert.equal(p.additionalSeedLords, '0'); assert.equal(p.additionalSeedTickets, '0');
  assert.equal(p.legacyLords, '5788620457280262621088');
  assert.equal(p.calls[0].entrypoint, 'claim_and_distribute_buybacks');
  assert.equal(p.calls.at(-3).entrypoint, 'import_proceeds');
  assert.deepEqual(p.calls.at(-2).calldata.slice(1), ['0x0', '0x0']);
  assert(!p.calls.some(c => ['initialize_pool', 'mint_v2', 'swap', 'deposit_amounts', 'increase_sell_amount'].includes(c.entrypoint) || /ownership|upgrade/.test(c.entrypoint)));
  assert.equal(p.declarationRequired, true);
  assert.equal(hash.computeSierraContractClassHash({ ...controllerDeclaration.contract_class,
    abi: JSON.parse(controllerDeclaration.contract_class.abi) }), controllerRelease.classHash);
  assert.equal(controllerDeclaration.contract_class.abi, hash.formatSpaces(JSON.stringify(JSON.parse(controllerDeclaration.contract_class.abi))));
  assert.deepEqual(Object.keys(controllerDeclaration.contract_class).sort(), ['abi', 'contract_class_version', 'entry_points_by_type', 'sierra_program']);
});
test('an unfinished legacy conversion blocks moving its NFT', () => {
  const s = controllerFixture(); s.legacyBuybacks[0].key[4] = String(s.timestamp + 86400);
  assert.throws(() => buildControllerProposal(s), /still active/);
  s.legacyBuybacks[0].key[4] = '1'; s.legacyBuybacks[0].info[1] = '1';
  assert.throws(() => buildControllerProposal(s), /still active/);
});
test('controller preflight refuses undeclared class or changed old proceeds, while retaining exact reviewed inventory', () => {
  const s = controllerFixture(), p = buildControllerProposal(s);
  assert.throws(() => validateControllerDraft(p, s), /not declared/);
  s.controllerDeclared = true; s.timestamp += 10;
  assert.doesNotThrow(() => validateControllerDraft(p, s));
  s.balances.lords_ticket = '1';
  assert.throws(() => validateControllerDraft(p, s), /legacy LORDS changed/);
});
test('controller wallet request sends the reviewed calls without changes and rejects an ownership call', async () => {
  const s = controllerFixture(); s.controllerDeclared = true;
  const p = buildControllerProposal(s), w = wallet();
  await openControllerReview(w, p);
  assert.deepEqual(w.requests.at(-1).params.calls, p.calls.map(c => ({ contract_address: c.contractAddress, entry_point: c.entrypoint, calldata: c.calldata })));
  const changed = structuredClone(p); changed.calls[0].entrypoint = 'transfer_ownership';
  await assert.rejects(openControllerReview(wallet(), changed));
  await assert.rejects(openControllerReview(wallet(A.dao), p));
  await assert.rejects(openControllerReview(wallet(), buildControllerProposal(controllerFixture())));
});
test('declaration review uses the frozen Sierra and compiled hash with the founding mainnet multisig', async () => {
  const w = wallet(); const originalRequest = w.request;
  w.request = async r => r.type === 'wallet_addDeclareTransaction' ? (w.requests.push(r), { transaction_hash: '0xabc' }) : originalRequest(r);
  await openDeclarationReview(w);
  assert.deepEqual(w.requests.at(-1), { type: 'wallet_addDeclareTransaction', params: controllerDeclaration });
  await assert.rejects(openDeclarationReview(wallet(A.dao)));
});
test('pending declaration is simulated before the exact handover at the next nonce', async () => {
  const s = controllerFixture(); s.header = {};
  const p = buildControllerProposal(s), trace = movementTrace();
  trace.calls[2].events = [rawTransfer(A.ticket, A.owner, '0x2250e9'), rawTransfer(A.ticket, A.owner, '0x2250e3'),
    rawTransfer(A.owner, p.controller, '0x2250e9'), rawTransfer(A.owner, p.controller, '0x2250e3')];
  trace.calls[1].events = []; // Handover moves no ticket inventory.
  let request;
  const result = await simulate(async (method, params) => {
    if (method === 'starknet_getNonce') return '0x9';
    request = params; return [{ transaction_trace: { type: 'DECLARE', state_diff: { declared_classes: [{
      class_hash: controllerDeclaration.class_hash, compiled_class_hash: controllerDeclaration.compiled_class_hash }] } } },
      { transaction_trace: { execute_invocation: trace } }];
  }, s, p, controllerDeclaration);
  assert.equal(request.transactions[0].type, 'DECLARE');
  assert.equal(request.transactions[0].nonce, '0x9');
  assert.equal(request.transactions[1].nonce, '0xa');
  assert(!('calldata' in request.transactions[0]));
  assert.equal(result.declarationSimulated, true);
  assert.equal(result.walletMovements.transfers.filter(t => t.asset === 'nft' && t.direction === 'send').length, 2);
});


test('standalone handover refuses the pre-restart state and cannot include another seed', async () => {
  const s = controllerFixture(); s.orderOwner = [A.owner]; s.lpOwner = [A.owner];
  assert.throws(() => buildControllerProposal(s), /original restart first/);
  const running = controllerFixture(); running.controllerDeclared = true;
  const p = buildControllerProposal(running);
  p.calls[0].entrypoint = 'deposit_amounts';
  await assert.rejects(openControllerReview(wallet(), p));
});
test('handover works without stored proceeds or old buybacks and allows zero wallet token movement', () => {
  const s = controllerFixture(); s.legacyBuybacks = []; s.balances.lords_ticket = '0';
  const p = buildControllerProposal(s); assert.equal(p.calls.length, 6);
  assert.equal(p.calls.at(-1).entrypoint, 'claim');
  const trace = movementTrace(); trace.calls[0].events = []; trace.calls[1].events = [];
  trace.calls[2].events = [rawTransfer(A.ticket, A.owner, '0x2250e9'), rawTransfer(A.ticket, A.owner, '0x2250e3'),
    rawTransfer(A.owner, p.controller, '0x2250e9'), rawTransfer(A.owner, p.controller, '0x2250e3')];
  assert(walletMovements(trace, p.route).totals.every(t => t.net === '0'));
});


import pricing from './pricing.cjs';
import sharedProposal from './proposal.cjs';
test('USD estimate uses the exact restart seed ratio and fresh LORDS quote', () => {
  const now = 1800000000000;
  const quote = { usd: 0.005, updatedAt: now - 60000 };
  const seed = sharedProposal.seedAmounts();
  const proposal = buildProposal(fixture());
  assert.equal(seed.seedTickets.toString(), proposal.seedTickets);
  assert.equal(seed.seedLords.toString(), proposal.seedLords);
  const value = pricing.seedValuation(seed.seedLords, seed.seedTickets, quote, now);
  assert(Math.abs(value.lordsPerTicket - 31) < 0.00001);
  assert(Math.abs(value.usdPerTicket - 0.155) < 0.000001);
  assert.equal(pricing.seedValuation('200', '10', quote, now).usdPerTicket, 0.1);
});
test('USD estimate rejects absent, invalid, future and stale quotes and invalid seed amounts', () => {
  const now = 1800000000000;
  for (const quote of [null, {}, { usd: 0, updatedAt: now }, { usd: -1, updatedAt: now },
    { usd: Infinity, updatedAt: now }, { usd: 1, updatedAt: now - 3600001 },
    { usd: 1, updatedAt: now + 60001 }])
    assert.throws(() => pricing.seedValuation('200', '10', quote, now));
  assert.throws(() => pricing.seedValuation('200', '0', { usd: 1, updatedAt: now }, now));
});
