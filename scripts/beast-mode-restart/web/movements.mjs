import { hash } from 'starknet';
import shared from './proposal.cjs';

const { A } = shared;
const same = (a, b) => BigInt(a) === BigInt(b);
const transferKey = hash.getSelectorFromName('Transfer');
const assets = [['lords', 'LORDS'], ['ticket', 'DTICKET'], ['nft', 'Ekubo NFT']];

// Read actual execution events, including both legacy and indexed Transfer ABIs.
// Only movements across the multisig boundary contribute to gross totals.
export function walletMovements(invocation, route = 'LORDS') {
  const transfers = [];
  function visit(node) {
    const asset = assets.find(([key]) => same(node.contract_address, A[key]));
    if (asset) for (const event of node.events || []) {
      if (!event.keys?.length || !same(event.keys[0], transferKey)) continue;
      let from, to, value;
      if (event.keys.length === 1 && event.data.length === 4) {
        [from, to] = event.data; value = event.data.slice(2);
      } else if (event.keys.length === 3 && event.data.length === 2) {
        [, from, to] = event.keys; value = event.data;
      } else throw new Error('Unrecognized transfer event; cannot show complete wallet movements.');
      const outgoing = same(from, A.owner), incoming = same(to, A.owner);
      if (outgoing === incoming) continue;
      const amount = BigInt(value[0]) + (BigInt(value[1]) << 128n);
      if (asset[0] !== 'nft' && amount === 0n) continue;
      transfers.push({ asset: asset[0], symbol: asset[1], direction: outgoing ? 'send' : 'receive',
        from, to, amount: asset[0] === 'nft' ? '1' : amount.toString(),
        ...(asset[0] === 'nft' ? { tokenId: amount.toString() } : {}), order: event.order });
    }
    for (const child of node.calls || []) visit(child);
  }
  visit(invocation);
  transfers.sort((a, b) => a.order - b.order);
  const totals = assets.slice(0, 2).map(([asset, symbol]) => {
    const sum = direction => transfers.filter(t => t.asset === asset && t.direction === direction)
      .reduce((n, t) => n + BigInt(t.amount), 0n);
    const sent = sum('send'), received = sum('receive');
    if (sent === 0n && route !== 'LORDS_CONTROLLER_HANDOVER') throw new Error(`Missing ${symbol} transfer events in simulation.`);
    return { asset, symbol, sent: sent.toString(), received: received.toString(), net: (received - sent).toString() };
  });
  if (transfers.filter(t => t.asset === 'nft' && t.direction === 'send').length !== 2)
    throw new Error('Missing position NFT transfer events in simulation.');
  return { totals, transfers };
}

export function formatUnits(value) {
  const n = BigInt(value), magnitude = n < 0n ? -n : n, unit = 10n ** 18n;
  const fraction = (magnitude % unit).toString().padStart(18, '0').replace(/0+$/, '') || '0';
  return `${n < 0n ? '−' : ''}${(magnitude / unit).toLocaleString('en-US')}.${fraction}`;
}
