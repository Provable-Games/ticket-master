import { A, config, createRpc, readSnapshot, buildProposal, simulate, checkWallet, openWalletReview, assertFresh } from './protocol.mjs';
import { readControllerSnapshot, buildControllerProposal, controllerDeclaration, controllerRelease, openControllerReview, openDeclarationReview } from './controller-protocol.mjs';
import { validateControllerDraft } from './controller-proposal.mjs';
import { formatUnits } from './movements.mjs';
import pricing from './pricing.cjs';
import sharedProposal from './proposal.cjs';

const $ = id => document.getElementById(id);
const rpc = createRpc();
let proposal = null, simulation = null, provider = null, connected = false, busy = false, walletPending = false;
let activeRoute = 'lords';
let usdQuote = null, quotePending = null, quoteError = false;
const usd = value => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 4, maximumFractionDigits: 6 }).format(value);
function renderSeedPrice() {
  $('seed-valuation').hidden = activeRoute !== 'lords';
  if (activeRoute !== 'lords') return;
  try {
    const seed = proposal || sharedProposal.seedAmounts();
    const price = pricing.seedValuation(seed.seedLords, seed.seedTickets, usdQuote);
    $('ticket-usd').textContent = `≈ ${usd(price.usdPerTicket)} / DTICKET`;
    $('seed-price-detail').textContent = `${price.lordsPerTicket.toFixed(6)} LORDS / DTICKET × ${usd(usdQuote.usd)} / LORDS. Quote: ${new Date(usdQuote.updatedAt).toLocaleString()} · `;
  } catch {
    $('ticket-usd').textContent = quoteError || usdQuote ? 'USD estimate unavailable' : 'Loading USD estimate…';
    $('seed-price-detail').textContent = 'Seed-implied starting price. A recent LORDS/USD quote is required. Source: ';
  }
}
async function refreshSeedPrice() {
  if (quotePending) return quotePending;
  quotePending = (async () => {
    try {
      const response = await fetch('/api/lords-usd', { signal: AbortSignal.timeout(12000), cache: 'no-store' });
      if (!response.ok) throw new Error('Price unavailable');
      usdQuote = pricing.validateQuote(await response.json()); quoteError = false;
    } catch { usdQuote = null; quoteError = true; }
    finally { renderSeedPrice(); }
  })();
  try { await quotePending; } finally { quotePending = null; }
}
const names = [
  ['Set aside repricing dust', 'LORDS → Router · 1 raw unit'], ['Restore the initial pool price', 'Router → swap · approximately 31 LORDS per ticket'],
  ['Refund unused dust', 'Router → clear LORDS'], ['Fund the LORDS side', 'LORDS → Positions · 10,000 LORDS'],
  ['Fund the D-ticket side', 'D ticket → Positions · approximately 322.580620 tickets'], ['Refill the existing LP position', 'Positions → deposit_amounts · NFT 2248931'],
  ['Refund unused LORDS', 'Positions → clear LORDS'], ['Refund unused D tickets', 'Positions → clear D ticket'],
  ['Withdraw active sale inventory', 'TicketMaster → multisig · amount refreshed from current state'], ['Fund the ticket sale', 'D ticket → Positions · same sale inventory'],
  ['Refill the existing sell order', 'Positions → increase_sell_amount · NFT 2248937'], ['Refund unused order funding', 'Positions → clear D ticket'],
  ['Return the order to TicketMaster', 'Positions NFT → transfer_from · NFT 2248937'], ['Return the LP to TicketMaster', 'Positions NFT → transfer_from · NFT 2248931'],
];
const phases = { 0: '01 / RESTORE THE POOL PRICE', 3: '02 / PROVIDE LIQUIDITY', 8: '03 / RESTART TICKET DISTRIBUTION', 12: '04 / RESTORE CONTRACT CUSTODY' };
const message = (id, text, kind = '') => { $(id).textContent = text; $(id).className = `status ${kind}`; };
const format = value => {
  const n = BigInt(value), unit = 10n ** 18n;
  return `${(n / unit).toLocaleString('en-US')}.${((n % unit) * 1000000n / unit).toString().padStart(6, '0')}`;
};
function update() {
  const reviewingMigration = activeRoute === 'survivor';
  $('route-lords').disabled = busy || walletPending;
  $('route-survivor').disabled = busy || walletPending;
  $('route-controller').disabled = busy || walletPending;
  $('refresh').disabled = reviewingMigration || busy || walletPending;
  $('connect').disabled = reviewingMigration || busy || walletPending;
  $('download').disabled = reviewingMigration || !proposal || busy || walletPending;
  $('ack').disabled = !simulation || busy || walletPending;
  $('declare').disabled = !simulation || !connected || !$('ack').checked || busy || walletPending || !proposal?.declarationRequired;
  $('stage').disabled = !!proposal?.declarationRequired || reviewingMigration || !simulation || !connected || !$('ack').checked || busy || walletPending;
}

function selectRoute(route) {
  if (busy || walletPending) return;
  activeRoute = ['survivor', 'controller'].includes(route) ? route : 'lords';
  proposal = null; simulation = null; $('ack').checked = false;
  renderSeedPrice();
  if (activeRoute === 'lords') void refreshSeedPrice();
  const migration = activeRoute === 'survivor', controller = activeRoute === 'controller';
  $('controller-note').hidden = !controller;
  $('seed-budget-label').textContent = controller ? 'ADDITIONAL LIQUIDITY' : 'LIQUIDITY SEED';
  $('seed-budget').textContent = controller ? '0' : '10,000';
  $('seed').textContent = controller ? '0 · EXISTING LP RETAINED' : '322.580620 D TICKET';
  $('price-label').textContent = controller ? 'POOL & ORDER' : 'STARTING PRICE';
  $('price-value').textContent = controller ? 'Keep running' : '31';
  $('price-unit').textContent = controller ? 'NO REPRICE OR REFILL' : 'LORDS / TICKET';
  $('declare').hidden = !controller; $('declaration-status').hidden = !controller;
  $('route-controller').setAttribute('aria-pressed', String(controller));
  $('lords-route').hidden = migration; $('survivor-route').hidden = !migration;
  $('route-lords').setAttribute('aria-pressed', String(!migration && !controller));
  $('route-survivor').setAttribute('aria-pressed', String(migration));
  $('route-title').textContent = migration ? 'Move ticket sales\nto SURVIVOR.' : 'Bring the ticket\nsale back online.';
  $('route-description').textContent = migration ? 'Compare the fork-tested controller route.\nKeep the same D ticket and multisig ownership.' : 'Review one batch. Keep the existing token, pool and order.\nYour multisig stays in control.';
  $('route-eyebrow').textContent = migration ? 'EXISTING D TICKET / NEW SURVIVOR POOL' : 'ORIGINAL D-TICKET / LORDS POOL';
  $('route-number').textContent = migration ? '03' : '01';
  $('route-stamp').textContent = migration ? 'MIGRATION\nREVIEW' : 'RESTART\nPROPOSAL';
  if (controller) {
    $('route-title').textContent = 'Stage the controller\nhandover separately.';
    $('route-description').textContent = 'After the original restart, transfer the existing positions into a controller.\nThe LORDS pool and order keep running.';
    $('route-eyebrow').textContent = 'EXISTING LORDS POOL / NEW CONTROLLER';
    $('route-number').textContent = '02'; $('route-stamp').textContent = 'CONTROLLER\nHANDOVER';
  }
  $('batch-title').textContent = controller ? 'The standalone handover batch' : 'The restart batch';
  $('batch-count').textContent = controller ? 'REFRESH FOR EXACT CALLS' : '14 CALLS · ONE TRANSACTION';
  $('inventory-intro').textContent = controller ? '' : 'Sale inventory moves from the D-ticket contract through your multisig into the Ekubo sell order. ';
  $('custody-note').textContent = controller ? 'Both existing NFTs move from TicketMaster through the multisig into the new controller. Their net wallet change is zero. There is no additional seed; existing liquidity and the running order are retained.' : 'Both position NFTs return to the D-ticket contract; your multisig keeps ownership of that contract.';
  $('ack-text').textContent = controller ? 'I reviewed the controller, its manual operations and all calls. Wallet confirmation adds my signature; the second signature can execute.' : 'I reviewed the 14 calls and understand that wallet confirmation adds my signature.';
  message('declaration-status', 'A new controller class requires a separate DECLARE transaction before the handover can execute.');
  $('freshness').textContent = migration ? 'Migration plan · mainnet batch not prepared' : 'Unsigned · Not queued · Not executed';
  message('simulation', 'No draft prepared yet. Refresh and simulate to prepare the LORDS restart.');
  message('submission', 'Nothing has been sent to a wallet for this draft.');
  $('controller-address').textContent = 'Refresh to prepare the exact controller address and calls.';
  history.replaceState(null, '', `#${activeRoute}`);
  renderCalls(); renderMovements(); update();
}
function renderCalls() {
  $('calls').replaceChildren();
  const controllerLabels = { claim_and_distribute_buybacks: 'Settle matured legacy buybacks to DAO', withdraw_erc721: 'Withdraw existing NFT from TicketMaster', deploy_contract: 'Deploy the separate LORDS controller', transfer_from: 'Move existing NFT into controller custody', withdraw_erc20: 'Withdraw existing LORDS proceeds', approve: 'Set or clear the exact temporary LORDS allowance', import_proceeds: 'Record existing LORDS in the proceeds ledger', claim: 'Claim unclaimed sales through the new controller' };
  const labels = activeRoute === 'controller' ? (proposal ? proposal.calls.map(call => [controllerLabels[call.entrypoint], call.entrypoint]) : [
    ['Settle matured legacy buybacks', 'Fresh state required after the original restart'], ['Deploy and transfer NFT custody', 'Existing LORDS pool and order remain running'], ['Account for existing and unclaimed proceeds', 'No additional liquidity seed'],
  ]) : names;
  labels.forEach(([title, detail], index) => {
    if (activeRoute !== 'controller' && phases[index]) { const phase = document.createElement('div'); phase.className = 'phase'; phase.textContent = phases[index] || '05 / LEGACY SETTLEMENT & CONTROLLER HANDOVER'; $('calls').append(phase); }
    const details = document.createElement('details'); details.className = 'call';
    const summary = document.createElement('summary');
    const number = document.createElement('span'); number.className = 'number'; number.textContent = String(index + 1).padStart(2, '0');
    const text = document.createElement('div'); text.className = 'call-name'; text.textContent = title;
    const sub = document.createElement('span'); sub.textContent = detail; text.append(sub);
    const arrow = document.createElement('span'); arrow.className = 'arrow'; arrow.textContent = '›'; summary.append(number, text, arrow);
    const body = document.createElement('div'); body.className = 'call-body';
    const call = proposal?.calls[index];
    if (call) {
      const target = document.createElement('a'); target.href = `https://voyager.online/contract/${call.contractAddress}`; target.target = '_blank'; target.rel = 'noreferrer'; target.textContent = call.contractAddress;
      const p = document.createElement('p'); p.append('Target: ', target);
      const pre = document.createElement('pre'); pre.textContent = `${call.entrypoint}\n${JSON.stringify(call.calldata, null, 2)}`; body.append(p, pre);
    } else body.textContent = 'Refresh mainnet state to generate exact calldata for review.';
    details.append(summary, body); $('calls').append(details);
  });
}

function renderMovements() {
  const root = $('movements'); root.replaceChildren();
  const movements = simulation?.walletMovements;
  if (!movements) { root.textContent = 'Refresh & simulate to see your final wallet change.'; return; }
  const columns = document.createElement('div'); columns.className = 'movement-columns';
  const final = document.createElement('div'); final.className = 'final-change';
  for (const [direction, title] of [['net', 'After the complete batch'], ['send', 'Send'], ['receive', 'Receive']]) {
    const column = document.createElement('section');
    const heading = document.createElement('h3'); heading.textContent = title; column.append(heading);
    for (const total of movements.totals) {
      const value = total[direction === 'send' ? 'sent' : direction === 'receive' ? 'received' : 'net'];
      const row = document.createElement('p'); row.className = 'movement-amount';
      const amount = document.createElement('strong');
      amount.textContent = `${BigInt(value) > 0n ? direction === 'send' ? '−' : '+' : ''}${formatUnits(value)}`;
      const label = document.createElement('span'); label.textContent = total.symbol; row.append(amount, label); column.append(row);
    }
    const nftTransfers = movements.transfers.filter(t => t.asset === 'nft');
    const nftNet = [...new Set(nftTransfers.map(t => t.tokenId))].flatMap(tokenId => {
      const transfers = nftTransfers.filter(t => t.tokenId === tokenId);
      const net = transfers.reduce((n, t) => n + (t.direction === 'send' ? -1 : 1), 0);
      return net ? [{ ...transfers[0], direction: net < 0 ? 'send' : 'receive' }] : [];
    });
    for (const transfer of direction === 'net' ? nftNet : nftTransfers.filter(t => t.direction === direction)) {
      const row = document.createElement('p'); row.className = 'movement-amount';
      const amount = document.createElement('strong'); amount.textContent = `${transfer.direction === 'send' ? '−' : '+'}1 NFT`;
      const label = document.createElement('span'); label.textContent = `${transfer.tokenId === String(BigInt(config.getters.get_position_token_id[0])) ? 'TWAP order' : 'LP position'} #${transfer.tokenId}`;
      row.append(amount, label); column.append(row);
    }
    (direction === 'net' ? final : columns).append(column);
  }
  const details = document.createElement('details'); details.className = 'transfer-details';
  const summary = document.createElement('summary'); summary.textContent = 'Intermediate Send / Receive · gross transfers';
  const explanation = document.createElement('p'); explanation.className = 'section-note';
  explanation.textContent = activeRoute === 'controller' ? 'Existing NFTs and already-held LORDS proceeds pass through the multisig into the controller. This handover adds no liquidity and moves no D-ticket inventory. Unclaimed sales are claimed by the new controller directly.' : 'These totals include temporary transfers during the batch. Sale inventory enters the multisig from the D-ticket contract and is forwarded into the Ekubo sell order. Receipts here are already counted in the final wallet change above.';
  const ledger = document.createElement('h3'); ledger.textContent = 'Every wallet transfer · exact amounts and counterparties';
  details.append(summary, explanation, columns, ledger);
  for (const t of movements.transfers) {
    const row = document.createElement('div'); row.className = 'transfer-row';
    const title = document.createElement('strong'); title.textContent = `${t.direction === 'send' ? 'Send −' : 'Receive +'}${t.asset === 'nft' ? `1 Ekubo NFT #${t.tokenId}` : `${formatUnits(t.amount)} ${t.symbol}`}`;
    const address = t.direction === 'send' ? t.to : t.from;
    const name = Object.entries({ 'D-ticket contract': A.ticket, 'Ekubo Positions': A.positions, 'Ekubo Router': A.router }).find(([, a]) => BigInt(a) === BigInt(address))?.[0] || 'Contract';
    const link = document.createElement('a'); link.href = `https://voyager.online/contract/${address}`; link.target = '_blank'; link.rel = 'noreferrer'; link.textContent = `${t.direction === 'send' ? 'To' : 'From'} ${name}: ${address}`;
    row.append(title, link); details.append(row);
  }
  const block = document.createElement('p'); block.className = 'section-note';
  block.textContent = `Simulated at block ${simulation.block.toLocaleString('en-US')}. Refresh to update the current state and amounts. Wallet changes are shown in token units.`;
  root.append(block, final, details);
}

async function refresh() {
  if (activeRoute === 'survivor' || busy || walletPending) return;
  if (activeRoute === 'lords') void refreshSeedPrice();
  busy = true; proposal = null; simulation = null; $('ack').checked = false; update(); renderCalls(); renderMovements();
  message('simulation', activeRoute === 'controller' ? 'Reading the running original sale and current NFT custody…' : 'Reading current mainnet state and checking the paused sale…');
  message('submission', 'Nothing has been sent to a wallet.');
  try {
    const snapshot = activeRoute === 'controller' ? await readControllerSnapshot(rpc) : await readSnapshot(rpc);
    proposal = activeRoute === 'controller' ? buildControllerProposal(snapshot) : buildProposal(snapshot);
    $('batch-count').textContent = `${proposal.calls.length} CALLS · ONE TRANSACTION`;
    if (activeRoute === 'controller') {
      $('controller-address').textContent = `Proposed controller: ${proposal.controller}`;
      message('declaration-status', proposal.declarationRequired ? 'Class not declared. Review the declaration first; after it executes, refresh and simulate the handover again.' : 'Exact controller class is declared. The handover is ready for simulation.');
    }
    if (activeRoute !== 'controller' && BigInt(snapshot.balances.ticket_ticket) < BigInt(proposal.restoreTickets)) throw new Error('TicketMaster reserve cannot cover the sale inventory.');
    renderCalls(); if (activeRoute !== 'controller') $('seed').textContent = `${format(proposal.seedTickets)} D TICKET`;
    renderSeedPrice();
    message('simulation', `Block ${snapshot.block.toLocaleString()} checked. Simulating ${proposal.calls.length} calls${proposal.declarationRequired ? ' after a simulated declaration' : ''}…`);
    simulation = await simulate(rpc, snapshot, proposal, proposal.declarationRequired ? controllerDeclaration : null);
    proposal.simulation = simulation;
    renderMovements();
    message('simulation', `Simulation passed at block ${snapshot.block.toLocaleString()}. ${activeRoute === 'controller' ? 'Transfers existing positions without reseeding, repricing or refilling.' : `Restores ${format(proposal.restoreTickets)} D tickets to the sell order.`} Signature validation skipped.${proposal.declarationRequired ? ' Declaration must execute first; the handover cannot be signed yet.' : ''}`, 'good');
    $('freshness').textContent = `Block ${snapshot.block.toLocaleString()} · unsigned · not queued`;
  } catch (error) { simulation = null; message('simulation', `Unable to prepare: ${error.message}`, 'error'); }
  finally { busy = false; update(); }
}

function findReady() {
  return [window.starknet_argentX, window.starknet_ready, window.starknet,
    ...Object.keys(window).filter(k => k.startsWith('starknet_')).map(k => window[k])]
    .find(w => w && typeof w.request === 'function' && /^(argentX|argent|ready)$/i.test(w.id || ''));
}

async function connect() {
  if (activeRoute === 'survivor' || busy || walletPending) return;
  busy = true; connected = false; update();
  try {
    provider = findReady();
    if (!provider) throw new Error('Ready/Argent is not available here. Open this page in your normal browser with the Ready extension installed.');
    await checkWallet(provider); connected = true;
    message('wallet', 'Founding multisig connected · Starknet mainnet.', 'good');
    const invalidate = () => { connected = false; $('ack').checked = false; message('wallet', 'Wallet changed. Select the founding multisig on mainnet and reconnect.'); update(); };
    provider.on?.('accountsChanged', invalidate); provider.on?.('networkChanged', invalidate);
  } catch (error) { message('wallet', error.message, 'error'); }
  finally { busy = false; update(); }
}

async function stage() {
  if (activeRoute === 'survivor' || busy || walletPending || !simulation || !connected || !$('ack').checked) return;
  busy = true; update();
  // Freeze the exact reviewed calls. A new preflight never silently changes them.
  const reviewed = structuredClone(proposal);
  try {
    assertFresh(reviewed);
    message('submission', 'Rechecking current state before opening your wallet…');
    const current = activeRoute === 'controller' ? await readControllerSnapshot(rpc) : await readSnapshot(rpc);
    if (activeRoute === 'controller') {
      validateControllerDraft(reviewed, current);
      await simulate(rpc, current, reviewed);
    } else buildProposal(current); // Refuse changed contracts, custody, inventory or issuance state.
    if (activeRoute !== 'controller' && BigInt(current.balances.ticket_ticket) < BigInt(reviewed.restoreTickets)) throw new Error('TicketMaster reserve changed; refresh and review again.');
    assertFresh(reviewed);
    walletPending = true; update();
    message('submission', 'Wallet review requested. Check Ready. A proposal is not confirmed until your wallet accepts it; the second signature can execute it.');
    const result = activeRoute === 'controller' ? await openControllerReview(provider, reviewed) : await openWalletReview(provider, reviewed);
    const reference = typeof result === 'object' ? result?.transaction_hash : result;
    message('submission', `Wallet returned ${reference || JSON.stringify(result)}. Check the multisig activity for pending signatures. Onchain execution has not been verified.`, 'good');
    simulation = null; $('ack').checked = false;
    $('freshness').textContent = 'Wallet response received · check Ready activity';
  } catch (error) { simulation = null; $('ack').checked = false; message('submission', `No successful wallet submission confirmed: ${error.message}`, 'error'); }
  finally { busy = false; walletPending = false; update(); }
}

$('owner-link').textContent = A.owner; $('owner-link').href = `https://voyager.online/contract/${A.owner}`;
$('refresh').addEventListener('click', refresh); $('connect').addEventListener('click', connect);
$('stage').addEventListener('click', stage); $('ack').addEventListener('change', update);
$('download').addEventListener('click', () => {
  if (activeRoute === 'survivor' || !proposal) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify({ ...proposal, ...(proposal.declarationRequired ? { declaration: controllerDeclaration } : {}) }, null, 2)], { type: 'application/json' }));
  const a = document.createElement('a'); a.href = url; a.download = `beast-mode-${activeRoute}-${proposal.snapshotBlock}-unsigned.json`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});
setInterval(() => { if (proposal && simulation && !busy && !walletPending) { try { assertFresh(proposal); } catch { simulation = null; $('ack').checked = false; message('simulation', 'Draft expired after four minutes. Refresh and review the updated amounts.'); update(); } } }, 1000);
for (const [id, address] of [['ticket', A.ticket], ['owner', A.owner], ['dao', A.dao], ['velords', A.velords]]) $('migration-' + id).textContent = address;
$('controller-release').textContent = `Controller class: ${controllerRelease.classHash}. Compiled class: ${controllerRelease.compiledClassHash}.`;
$('route-controller').addEventListener('click', () => selectRoute('controller'));
$('declare').addEventListener('click', async () => {
  if (activeRoute !== 'controller' || !simulation || !connected || !$('ack').checked || !proposal?.declarationRequired || busy || walletPending) return;
  busy = true; walletPending = true; update();
  try {
    assertFresh(proposal);
    message('declaration-status', 'Requesting controller class declaration review in Ready. This does not deploy the controller or move funds.');
    const result = await openDeclarationReview(provider);
    if (result?.class_hash && BigInt(result.class_hash) !== BigInt(controllerRelease.classHash)) throw new Error('Wallet returned a different controller class hash. Stop and review the declaration.');
    message('declaration-status', `Wallet returned ${result?.transaction_hash || JSON.stringify(result)}. Check Ready activity. Once declaration executes, refresh and review the handover. Execution has not been verified.`, 'good');
  } catch (error) { message('declaration-status', `No successful declaration submission confirmed: ${error.message}. The unsigned download includes the exact declaration for a compatible wallet/tool.`, 'error'); }
  finally { simulation = null; $('ack').checked = false; busy = false; walletPending = false; update(); }
});
$('route-lords').addEventListener('click', () => selectRoute('lords'));
$('route-survivor').addEventListener('click', () => selectRoute('survivor'));
window.addEventListener('hashchange', () => selectRoute(location.hash.slice(1)));
$('download-migration').addEventListener('click', () => {
  const plan = { status: 'REVIEW_PLAN_ONLY', route: 'SURVIVOR_CONTROLLER', executable: false,
    mainnetBatchPrepared: false, ownershipTransferIncluded: false,
    addresses: { ticket: A.ticket, owner: A.owner, payment: A.survivor, dao: A.dao, velords: A.velords },
    split: { directSurvivorToDaoPercent: 80, survivorToLordsForVelordsPercent: 20 },
    controllerMainnetAddress: null, priceAndSeed: 'Fresh quote and final seed selection required',
    phases: [...document.querySelectorAll('.migration-steps li')].map(li => li.textContent),
    pending: [...document.querySelectorAll('.migration-gaps li')].map(li => li.textContent),
    evidence: { network: 'LOCAL_MAINNET_FORK', block: 16432906, date: '2026-10-15',
      source: 'https://github.com/Provable-Games/cairo-devcontainer/pull/51',
      note: 'Controller trials passed; complete production cutover batch not yet rehearsed.' } };
  const url = URL.createObjectURL(new Blob([JSON.stringify(plan, null, 2)], { type: 'application/json' }));
  const a = document.createElement('a'); a.href = url; a.download = 'beast-mode-survivor-migration-review-plan.json'; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
selectRoute(location.hash.slice(1));
setInterval(() => { if (activeRoute === 'lords' && !document.hidden) void refreshSeedPrice(); }, 300000);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && activeRoute === 'lords') { renderSeedPrice(); void refreshSeedPrice(); }
});
