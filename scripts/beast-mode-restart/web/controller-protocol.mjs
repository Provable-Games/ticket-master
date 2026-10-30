import { hash } from 'starknet';
import { A, readSnapshot, checkWallet } from './protocol.mjs';
import { controllerRelease, controllerDeclaration, buildControllerProposal } from './controller-proposal.mjs';
const hex = x => `0x${BigInt(x).toString(16)}`;
export async function readControllerSnapshot(rpc) {
  const s = await readSnapshot(rpc), block_id = { block_number: s.block };
  const call = (address, entrypoint, calldata = []) => rpc('starknet_call', { block_id,
    request: { contract_address: address, entry_point_selector: hash.getSelectorFromName(entrypoint), calldata: calldata.map(hex) } });
  const balance = await call(A.lords, 'balance_of', [A.ticket]);
  s.balances.lords_ticket = (BigInt(balance[0]) + (BigInt(balance[1]) << 128n)).toString();
  const bookmark = BigInt((await call(A.ticket, 'get_buyback_order_key_bookmark'))[0]);
  const counter = BigInt((await call(A.ticket, 'get_buyback_order_key_counter'))[0]);
  if (counter < bookmark || counter - bookmark >= 100n) throw new Error('Unexpected legacy buyback backlog.');
  s.legacyBuybacks = [];
  for (let index = bookmark; index < counter; index++) {
    const end = (await call(A.ticket, 'get_buyback_order_key_end_time', [index]))[0];
    const key = await call(A.ticket, 'get_buyback_order_key', [0, end]);
    const info = await call(A.positions, 'get_order_info', [s.getters.get_position_token_id[0], ...key]);
    s.legacyBuybacks.push({ index: index.toString(), key, info });
  }
  try { await rpc('starknet_getClass', { block_id, class_hash: controllerRelease.classHash }); s.controllerDeclared = true; }
  catch (error) { if (error.code !== 28) throw error; s.controllerDeclared = false; }
  return s;
}
export async function openControllerReview(provider, proposal) {
  await checkWallet(provider);
  if (proposal.declarationRequired || proposal.route !== 'LORDS_CONTROLLER_HANDOVER' || proposal.standalone !== true || proposal.ownershipTransferIncluded !== false ||
    proposal.controllerClassHash !== controllerRelease.classHash || ![6, 7, 10, 11].includes(proposal.calls.length) ||
    proposal.calls.some(c => !['claim_and_distribute_buybacks', 'withdraw_erc721', 'deploy_contract', 'transfer_from', 'withdraw_erc20', 'approve', 'import_proceeds', 'claim'].includes(c.entrypoint))) throw new Error('Expected the reviewed LORDS controller handover with unchanged multisig ownership.');
  return provider.request({ type: 'wallet_addInvokeTransaction', params: { calls: proposal.calls.map(c => ({
    contract_address: c.contractAddress, entry_point: c.entrypoint, calldata: [...c.calldata] })) } });
}
export async function openDeclarationReview(provider) {
  await checkWallet(provider);
  return provider.request({ type: 'wallet_addDeclareTransaction', params: structuredClone(controllerDeclaration) });
}
export { buildControllerProposal, controllerDeclaration, controllerRelease };
