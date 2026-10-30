'use strict';
const config = require('./config.json');
const A = config.addresses;
const hex = x => `0x${BigInt(x).toString(16)}`;
const u256 = x => [hex(BigInt(x) & ((1n << 128n) - 1n)), hex(BigInt(x) >> 128n)];
const eq = (a, b) => BigInt(a) === BigInt(b);
const assert = (condition, message = 'Mainnet preflight failed') => { if (!condition) throw new Error(message); };
const txCall = (address, entrypoint, calldata = []) => ({ contractAddress: address, entrypoint, calldata: calldata.map(hex) });
const transfer = (token, to, amount) => txCall(token, 'transfer', [to, ...u256(amount)]);
const bounds = [88368108, 1, 88368108, 0];

function validateForBuild(s) {
  const g = s.getters;
  for (const [name, expected] of Object.entries(config.classes)) assert(eq(s.classes[name], expected), `Deployed ${name} class changed. Review required.`);
  for (const [name, expected] of Object.entries(config.getters)) {
    assert(g[name].length === expected.length && expected.every((value, i) => eq(g[name][i], value)), `${name} changed since the tested setup.`);
  }
  for (const [name, expected] of [['owner', A.owner], ['get_payment_token', A.lords], ['get_buyback_token', A.survivor], ['get_treasury_address', A.dao], ['get_velords_address', A.velords]]) assert(eq(g[name][0], expected), `${name} changed.`);
  assert(eq(s.orderOwner[0], A.owner) && eq(s.lpOwner[0], A.owner), 'Position NFTs are no longer with the founding multisig.');
  assert(s.order.every(x => BigInt(x) === 0n), 'Original order is no longer empty.');
  assert(eq(s.poolLiquidity[0], 0), 'Pool is no longer empty.');
  assert(s.lp.slice(4).every(x => BigInt(x) === 0n), 'LP liquidity, principal or fees changed.');
  assert(s.aggregateRates.slice(0, 2).every(x => BigInt(x) === 0n), 'Another TWAMM order is active.');
  assert(eq(g.get_deployment_state[0], 3) && eq(g.is_low_issuance_mode[0], 1), 'Issuance mode changed.');
  assert(eq(s.threshold[0], 2), 'Multisig signature threshold changed.');
}

function buildProposal(s, executionTimestamp = s.timestamp) {
  validateForBuild(s);
  const g = s.getters;
  const pool = g.get_distribution_pool_key;
  const orderKey = g.get_distribution_order_key;
  const orderId = g.get_position_token_id[0];
  const lpId = g.get_liquidity_position_id[0];
  const { seedLords, seedTickets, sqrtPrice } = seedAmounts(g.get_distribution_initial_tick);
  assert(seedLords > 0n && seedLords <= BigInt(s.balances.lords_owner), 'Seed must fit existing multisig LORDS balance');
  assert(seedTickets < BigInt(s.balances.ticket_owner), 'Seed must fit existing multisig tickets; do not take reserve');
  const minimumLiquidity = sqrt(seedLords * seedTickets) * 99n / 100n;
  const now = BigInt(executionTimestamp);
  const duration = BigInt(orderKey[4]) - now;
  assert(duration > 0n && duration <= (1n << 32n) - 1n);
  const storedRate = BigInt(g.get_token_distribution_rate[0]);
  const restoreTickets = (storedRate * duration + (1n << 32n) - 1n) / (1n << 32n);
  assert(restoreTickets <= BigInt(s.balances.ticket_ticket), 'TicketMaster reserve cannot cover the sale inventory.');
  const bundle = [
    // Empty-pool reposition, funded with a single raw LORDS unit and refunded.
    transfer(A.lords, A.router, 1n),
    txCall(A.router, 'swap', [...pool, ...u256(sqrtPrice), 0, A.lords, 1, 0]),
    txCall(A.router, 'clear', [A.lords]),
    // Use the original LP NFT; deposit_amounts consumes pre-funded balances.
    transfer(A.lords, A.positions, seedLords),
    transfer(A.ticket, A.positions, seedTickets),
    txCall(A.positions, 'deposit_amounts', [lpId, ...pool, ...bounds, seedLords, seedTickets, minimumLiquidity]),
    txCall(A.positions, 'clear', [A.lords]),
    txCall(A.positions, 'clear', [A.ticket]),
    // Refill the original order, preserving reserve tickets on TicketMaster.
    txCall(A.ticket, 'withdraw_erc20', [A.ticket, ...u256(restoreTickets)]),
    transfer(A.ticket, A.positions, restoreTickets),
    txCall(A.positions, 'increase_sell_amount', [orderId, ...orderKey, restoreTickets]),
    txCall(A.positions, 'clear', [A.ticket]),
    // Restore original contract custody, enabling its existing operations.
    txCall(A.nft, 'transfer_from', [A.owner, A.ticket, orderId, 0]),
    txCall(A.nft, 'transfer_from', [A.owner, A.ticket, lpId, 0]),
  ];
  return JSON.parse(JSON.stringify({ network: 'SN_MAIN', sender: A.owner, signatureThreshold: 2,
    status: 'UNSIGNED_DRAFT', ownershipTransferIncluded: false,
    snapshotBlock: s.block, snapshotBlockHash: s.blockHash, snapshotTimestamp: s.timestamp,
    executionTimestamp, classes: s.classes, seedLords, seedTickets, sqrtPrice, minimumLiquidity,
    restoreTickets, storedRateQ32: storedRate, end: orderKey[4], calls: bundle,
  }, (_, value) => typeof value === 'bigint' ? value.toString() : value));
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


function seedAmounts(initialTick = config.getters.get_distribution_initial_tick) {
  const seedLords = 10000n * 10n ** 18n;
  const sqrtPrice = tickToSqrtRatio(initialTick);
  const seedTickets = (seedLords * sqrtPrice * sqrtPrice + (1n << 256n) - 1n) / (1n << 256n) + 1n;
  return { seedLords, seedTickets, sqrtPrice };
}

module.exports = { config, A, buildProposal, validateForBuild, u256, seedAmounts };
