import { hash, constants } from 'starknet';
import shared from './proposal.cjs';
import release from './release/controller.json' with { type: 'json' };
import contractClass from './release/controller-class.json' with { type: 'json' };
const { A, config, u256 } = shared;
const hex = n => `0x${BigInt(n).toString(16)}`;
const check = (ok, message) => { if (!ok) throw new Error(message); };
const call = (address, entrypoint, calldata) => ({ contractAddress: address, entrypoint, calldata: calldata.map(hex) });
export const controllerRelease = release;
export const controllerDeclaration = { class_hash: release.classHash, compiled_class_hash: release.compiledClassHash, contract_class: contractClass };

export function buildControllerProposal(snapshot) {
  const g = snapshot.getters;
  for (const [name, expected] of Object.entries(config.classes))
    check(BigInt(snapshot.classes[name]) === BigInt(expected), `Deployed ${name} class changed. Review required.`);
  for (const [name, expected] of Object.entries(config.getters)) {
    if (name === 'get_token_distribution_rate') continue;
    check(g[name].length === expected.length && expected.every((value, i) => BigInt(g[name][i]) === BigInt(value)), `${name} changed.`);
  }
  for (const [name, expected] of [['owner', A.owner], ['get_payment_token', A.lords], ['get_buyback_token', A.survivor], ['get_treasury_address', A.dao], ['get_velords_address', A.velords]])
    check(BigInt(g[name][0]) === BigInt(expected), `${name} changed.`);
  check(BigInt(snapshot.threshold[0]) === 2n, 'Multisig signature threshold changed.');
  check(BigInt(snapshot.orderOwner[0]) === BigInt(A.ticket) && BigInt(snapshot.lpOwner[0]) === BigInt(A.ticket),
    'Complete the original restart first: both existing NFTs must be held by TicketMaster.');
  check(BigInt(snapshot.order[0]) > 0n && BigInt(snapshot.order[1]) > 0n && BigInt(snapshot.poolLiquidity[0]) > 0n && BigInt(snapshot.lp[4]) > 0n,
    'The original sale and LP must be running before this standalone handover.');
  check(BigInt(g.get_distribution_order_key[4]) > BigInt(snapshot.timestamp), 'The original sale has ended.');
  check(snapshot.legacyBuybacks.every(b => BigInt(b.key[4]) <= BigInt(snapshot.timestamp) && BigInt(b.info[1]) === 0n),
    'A legacy buyback is still active. Wait for maturity and refresh before moving its NFT.');
  check(snapshot.legacyBuybacks.length < 100, 'Unexpected legacy buyback backlog.');
  const constructor = [A.owner, A.positions, A.nft, A.lords, A.survivor, A.dao, A.velords,
    ...g.get_distribution_pool_key, ...g.get_distribution_order_key, 88368108, 1, 88368108, 0,
    g.get_position_token_id[0], g.get_liquidity_position_id[0]].map(hex);
  const salt = 1042;
  const controller = hash.calculateContractAddressFromHash(salt, release.classHash, constructor, 0);
  const calls = [];
  if (snapshot.legacyBuybacks.length) calls.push(call(A.ticket, 'claim_and_distribute_buybacks', [0]));
  for (const id of [g.get_position_token_id[0], g.get_liquidity_position_id[0]])
    calls.push(call(A.ticket, 'withdraw_erc721', [A.nft, ...u256(id)]));
  calls.push(call(constants.UDC.ADDRESS, constants.UDC.ENTRYPOINT, [release.classHash, salt, 0, constructor.length, ...constructor]));
  for (const id of [g.get_position_token_id[0], g.get_liquidity_position_id[0]])
    calls.push(call(A.nft, 'transfer_from', [A.owner, controller, ...u256(id)]));
  const legacyLords = BigInt(snapshot.balances.lords_ticket);
  check(legacyLords >= 0n && legacyLords < (1n << 128n), 'Legacy proceeds overflow.');
  if (legacyLords) calls.push(
    call(A.ticket, 'withdraw_erc20', [A.lords, ...u256(legacyLords)]),
    call(A.lords, 'approve', [controller, ...u256(legacyLords)]),
    call(controller, 'import_proceeds', [legacyLords]),
    call(A.lords, 'approve', [controller, 0, 0]),
  );
  // Unclaimed sales follow the existing order NFT. Claim only after custody
  // changes, so execution-time proceeds go directly into the new ledger.
  calls.push(call(controller, 'claim', []));
  return { network: 'SN_MAIN', sender: A.owner, signatureThreshold: 2, status: 'UNSIGNED_DRAFT',
    ownershipTransferIncluded: false, snapshotBlock: snapshot.block, snapshotBlockHash: snapshot.blockHash,
    snapshotTimestamp: snapshot.timestamp, classes: snapshot.classes,
    route: 'LORDS_CONTROLLER_HANDOVER', standalone: true, additionalSeedLords: '0', additionalSeedTickets: '0',
    observedSaleRateQ32: snapshot.order[0], observedLiquidity: snapshot.lp[4], controller, controllerClassHash: release.classHash,
    controllerCompiledClassHash: release.compiledClassHash, constructor, salt,
    declarationRequired: !snapshot.controllerDeclared, legacyLords: legacyLords.toString(), calls,
    management: 'MANUAL_MULTISIG', payout: '20% LORDS to veLords; 80% buys SURVIVOR for DAO',
    caveats: ['Controller has no automatic issuance/oracle keeper or upgrade entrypoint.',
      'Active conversion orders must mature before both NFTs can be released.',
      'Imported legacy LORDS stays in the proceeds ledger until the multisig distributes it.'] };
}

export function validateControllerDraft(reviewed, current) {
  const rebuilt = buildControllerProposal(current);
  check(!rebuilt.declarationRequired, 'Controller class is not declared on mainnet yet. Finish declaration, then refresh.');
  check(reviewed.controller === rebuilt.controller && reviewed.legacyLords === rebuilt.legacyLords,
    'Controller configuration or legacy LORDS changed. Refresh and review again.');
  check(reviewed.route === 'LORDS_CONTROLLER_HANDOVER' && reviewed.standalone === true,
    'Expected a standalone controller handover. Refresh this page.');
  check(JSON.stringify(reviewed.calls) === JSON.stringify(rebuilt.calls),
    'Custody or legacy buyback state changed. Refresh and review again.');
}
