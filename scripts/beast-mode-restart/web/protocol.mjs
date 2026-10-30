import { hash } from 'starknet';
import shared from './proposal.cjs';
import { walletMovements } from './movements.mjs';

export const { A, config, buildProposal } = shared;
export const MAINNET = '0x534e5f4d41494e';
const RPC = 'https://api.cartridge.gg/x/starknet/mainnet/rpc/v0_10';
const hex = value => `0x${BigInt(value).toString(16)}`;
const same = (a, b) => BigInt(a) === BigInt(b);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const serialize = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v);

export function createRpc(fetcher = globalThis.fetch.bind(globalThis)) {
  const permitted = new Set(['starknet_chainId', 'starknet_blockNumber', 'starknet_getBlockWithTxHashes',
    'starknet_call', 'starknet_getClassHashAt', 'starknet_getNonce', 'starknet_simulateTransactions',
    'starknet_getTransactionReceipt', 'starknet_getClass']);
  return async (method, params = {}) => {
    check(permitted.has(method), 'This page only makes read-only RPC requests.');
    const response = await fetcher(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: serialize({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(90000) });
    const result = await response.json();
    if (!response.ok || result.error) {
      const error = new Error(result.error?.message || `RPC returned HTTP ${response.status}`);
      error.code = result.error?.code; throw error;
    }
    return result.result;
  };
}

async function mapLimit(items, fn) {
  const results = new Array(items.length);
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(3, items.length) }, async () => {
    while (cursor < items.length) { const index = cursor++; results[index] = await fn(items[index]); }
  }));
  return results;
}

export async function readSnapshot(rpc) {
  check(await rpc('starknet_chainId') === MAINNET, 'RPC must be Starknet mainnet.');
  const block = Number(await rpc('starknet_blockNumber'));
  const blockId = { block_number: block };
  const header = await rpc('starknet_getBlockWithTxHashes', { block_id: blockId });
  const call = (address, entrypoint, calldata = []) => rpc('starknet_call', {
    block_id: blockId, request: { contract_address: address,
      entry_point_selector: hash.getSelectorFromName(entrypoint), calldata: calldata.map(hex) },
  });
  const s = { block, blockHash: header.block_hash, timestamp: header.timestamp, header, getters: {}, classes: {}, balances: {} };
  const getters = [...new Set([...Object.keys(config.getters), 'owner', 'get_payment_token', 'get_buyback_token',
    'get_treasury_address', 'get_velords_address', 'get_deployment_state', 'is_low_issuance_mode'])];
  await mapLimit(getters, async name => { s.getters[name] = await call(A.ticket, name); });
  await mapLimit(Object.keys(config.classes), async name => {
    s.classes[name] = await rpc('starknet_getClassHashAt', { block_id: blockId, contract_address: A[name] });
  });
  const g = s.getters, bounds = [88368108, 1, 88368108, 0];
  const queries = [
    ['order', A.positions, 'get_order_info', [...g.get_position_token_id, ...g.get_distribution_order_key]],
    ['lp', A.positions, 'get_token_info', [...g.get_liquidity_position_id, ...g.get_distribution_pool_key, ...bounds]],
    ['poolLiquidity', A.core, 'get_pool_liquidity', g.get_distribution_pool_key],
    ['orderOwner', A.nft, 'owner_of', [...g.get_position_token_id, 0]],
    ['lpOwner', A.nft, 'owner_of', [...g.get_liquidity_position_id, 0]],
    ['aggregateRates', A.extension, 'get_sale_rate_and_last_virtual_order_time', g.get_distribution_pool_key.slice(0, 3)],
    ['threshold', A.owner, 'get_threshold', []],
  ];
  await mapLimit(queries, async ([key, address, method, calldata]) => { s[key] = await call(address, method, calldata); });
  await mapLimit(['lords', 'ticket'], async token => {
    const result = await call(A[token], 'balance_of', [A.owner]);
    s.balances[`${token}_owner`] = (BigInt(result[0]) + (BigInt(result[1]) << 128n)).toString();
  });
  const reserve = await call(A.ticket, 'balance_of', [A.ticket]);
  s.balances.ticket_ticket = (BigInt(reserve[0]) + (BigInt(reserve[1]) << 128n)).toString();
  return s;
}

export function accountCalldata(calls) {
  return [hex(calls.length), ...calls.flatMap(c => [c.contractAddress,
    hash.getSelectorFromName(c.entrypoint), hex(c.calldata.length), ...c.calldata])];
}

export async function simulate(rpc, snapshot, proposal, declaration = null) {
  const block_id = { block_number: snapshot.block };
  const nonce = await rpc('starknet_getNonce', { block_id, contract_address: A.owner });
  const bound = name => ({ max_amount: '0x3b9aca00',
    max_price_per_unit: hex(BigInt(snapshot.header[name]?.price_in_fri || '0x2540be400') * 2n) });
  const transaction = { type: 'INVOKE', version: '0x3', sender_address: A.owner,
    calldata: accountCalldata(proposal.calls), nonce, signature: [],
    resource_bounds: { l1_gas: bound('l1_gas_price'), l1_data_gas: bound('l1_data_gas_price'), l2_gas: bound('l2_gas_price') },
    tip: '0x0', paymaster_data: [], account_deployment_data: [],
    nonce_data_availability_mode: 'L1', fee_data_availability_mode: 'L1' };
  const transactions = declaration ? [{ ...transaction, type: 'DECLARE', contract_class: declaration.contract_class,
    compiled_class_hash: declaration.compiled_class_hash }, { ...transaction, nonce: hex(BigInt(nonce) + 1n) }] : [transaction];
  if (declaration) { delete transactions[0].calldata; }
  const result = await rpc('starknet_simulateTransactions', {
    block_id, transactions, simulation_flags: ['SKIP_VALIDATE', 'SKIP_FEE_CHARGE'],
  });
  if (declaration) check(result?.[0]?.transaction_trace?.state_diff?.declared_classes?.some(
    c => same(c.class_hash, declaration.class_hash) && same(c.compiled_class_hash, declaration.compiled_class_hash)),
    'Declaration simulation returned a different class hash. Do not sign; review the controller artifact.');
  const invocation = result?.at(-1)?.transaction_trace?.execute_invocation;
  check(invocation && !invocation.revert_reason && Array.isArray(invocation.calls),
    invocation?.revert_reason || 'RPC did not return a successful execution trace.');
  return { block: snapshot.block, feeEstimate: result.at(-1).fee_estimation,
    ...(declaration ? { declarationFeeEstimate: result[0].fee_estimation } : {}), signatureValidationSkipped: true,
    declarationSimulated: !!declaration, walletMovements: walletMovements(invocation, proposal.route) };
}

export async function checkWallet(provider) {
  check(provider && typeof provider.request === 'function', 'Connect Ready/Argent in a browser with its wallet extension.');
  const accounts = await provider.request({ type: 'wallet_requestAccounts', params: { silent_mode: false } });
  check(accounts?.length && same(accounts[0], A.owner), 'Select the founding multisig in Ready, then connect again.');
  const chain = await provider.request({ type: 'wallet_requestChainId' });
  check(same(chain, MAINNET), 'Switch Ready to Starknet mainnet, then connect again.');
  return accounts[0];
}

export async function openWalletReview(provider, proposal) {
  await checkWallet(provider);
  check(proposal.calls.length === 14 && proposal.ownershipTransferIncluded === false,
    'Expected the 14-call restart with ownership unchanged.');
  const calls = proposal.calls.map(c => ({ contract_address: c.contractAddress,
    entry_point: c.entrypoint, calldata: [...c.calldata] }));
  return provider.request({ type: 'wallet_addInvokeTransaction', params: { calls } });
}

export function assertFresh(proposal, currentTimestamp = Date.now() / 1000) {
  check(currentTimestamp - proposal.snapshotTimestamp <= 240 && currentTimestamp >= proposal.snapshotTimestamp - 30,
    'Draft is older than four minutes. Refresh and simulate, then review the new amounts.');
}
