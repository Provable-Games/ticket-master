# Beast Mode original ticket-sale restart

Read-only mainnet inspection, an unsigned multisig call bundle, and a local
mainnet-fork rehearsal for the existing D-ticket/LORDS setup. The tool has no
mainnet submission command and reads no signing credentials.

The original ticket token, LP NFT and order NFT are reused. This restores the
original revenue flow: 20% LORDS to veLords, 80% LORDS buys SURVIVOR for the DAO.
Moving ticket sales to SURVIVOR is a later, separate operation.

## Run

Requires Node 22+, npm, and Starknet Devnet 0.10.1. Obtain Devnet from its
[official release](https://github.com/starknet-io/starknet-devnet/releases/tag/v0.10.1).

```sh
cd scripts/beast-mode-restart
npm ci --ignore-scripts
node restart.cjs inspect
BEAST_RESTART_DEVNET=/absolute/path/to/starknet-devnet node restart.cjs rehearse
```

Configuration:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BEAST_RESTART_OUTPUT` | `/workspace/.scratch/beast-mode-restart` | Snapshot, deployed ABIs, bundle, receipts and fork results |
| `BEAST_RESTART_BLOCK` | Latest mainnet block | Pin a repeatable inspection/rehearsal |
| `BEAST_RESTART_SEED_LORDS` | `10000` | Whole LORDS units for the rehearsal; requires final owner selection |
| `BEAST_RESTART_DEVNET` | Required for rehearsal | Absolute Devnet binary path |

Devnet binds a free loopback port, impersonates the existing multisig, and mints
only local STRK for transaction fees. Real fork balances fund the LORDS and
D-ticket liquidity. The owned Devnet process is stopped on success or failure.
Impersonation skips signature validation; this does not prove multisig signatures
or production fee estimates. It does execute the actual deployed account's
multicall and the deployed token, Ekubo and TicketMaster contracts.

## Restart transaction

`restart-bundle.json` contains the ordered Starknet calls and economic parameters;
`restart-calldata.json` contains the Cairo 1 account `__execute__` calldata. Both
are unsigned and initially marked `REHEARSAL_ONLY`.

The atomic call sequence:

1. Use a dust LORDS swap with an explicit sqrt-price limit to move the empty
   pool back to the original initial tick. Refund the unused dust.
2. Seed the original LP NFT from existing multisig LORDS and tickets. Enforce
   minimum liquidity at 99% of the expected full-range amount; refund surplus.
3. Withdraw enough D tickets from TicketMaster to restore its recorded active
   Q32 sale rate over the original remaining duration, leaving reserve tickets.
4. Fund and refill the original order, then return both NFTs to TicketMaster.

The preflight refuses nonempty pools/orders, other aggregate TWAMM orders,
changed NFT custody, changed revenue destinations or insufficient seed balances.
Old LORDS proceeds remain on TicketMaster; they are not used as liquidity capital.

The amount needed to restore a rate depends on the execution timestamp. The
fixed unsigned bundle records the rehearsal timestamp and must be regenerated
and simulated before signing. Its parameters are not valid indefinitely. The
fork asserts actual-versus-stored rate drift is at most 100 parts per billion.
One Q32 rounding unit is approximately 2.33e-28 tickets per second.

Before live signing, select the seed budget, recheck all preconditions and class
hashes, and simulate the **exact final account transaction**. Receipt hashes from
this tool refer to the disposable fork, not mainnet. No live transaction has been
sent by the tool.

## Fork acceptance

The rehearsal asserts:

- The single account transaction succeeds and its swap event records the exact
  intended initial sqrt-price.
- LP liquidity is funded; both NFTs return to TicketMaster.
- The active order rate matches recorded telemetry within the stated tolerance;
  reserve tickets and old LORDS proceeds are preserved.
- The outstanding old buyback is claimable through TicketMaster and reaches DAO.
- A real LORDS purchase receives D tickets.
- After time advances, ticket sales produce claimable LORDS.
- `distribute_proceeds` sends exactly one fifth of LORDS to veLords and starts
  the SURVIVOR buyback with the remainder.
- After buyback maturity, SURVIVOR reaches the DAO.
- Both low-issuance reserve transitions execute and retain rate consistency.

The rehearsal does not enter a replacement Beast Mode dungeon or change client
purchase routing. Its address is independent of restoring ticket distribution.
Automatic keeper transitions also require reviewing the existing oracle history
and tiny issuance threshold before enabling the keeper.

Reference: [Ekubo mainnet contracts](https://docs.ekubo.org/reference/contracts/starknet/).
The company brain's `knowledge/beast-mode-ticket-restart.md` records the migration
plan, source pointers and the original investigation snapshot.


## Browser staging page

`npm run build:web` builds a static page into
`/workspace/.scratch/beast-mode-restart/web-dist` (override `BEAST_STAGING_DIST`).
`npm run preview:web` serves those assets on localhost port 4178 and records its owned
PID/port in the scratch directory. No server API receives signing keys.

The page generates a fixed 10,000 LORDS / approximately 322.580620 D-ticket seed
using the same `web/proposal.cjs` builder as the CLI rehearsal. The former
`BEAST_RESTART_SEED_LORDS` override is superseded by this agreed fixed seed.
It keeps ownership unchanged, checks the seven pinned class hashes, state,
NFT custody, reserve/seed balances and two-signature threshold, then simulates
all 14 calls against a pinned mainnet block with signature validation and fee
charging skipped. This is an unsigned execution check, not signature validation
or a production fee quote.

Opening Ready requires a successful simulation, review acknowledgement, the
correct wallet/account/network, fresh state preflight and a draft less than four
minutes old. The preflight never changes reviewed calls silently. All calls are
sent together using `wallet_addInvokeTransaction`; the browser RPC helper
cannot broadcast a transaction. Ready confirmation supplies a signer signature;
the second signature can execute the proposal. An RPC simulation or unsigned
JSON download does not create a proposal. A returned wallet reference is displayed
without claiming a confirmed proposal or onchain execution.

The four-minute freshness guard applies before requesting wallet review. Later
multisig execution can still be delayed by co-signers: fixed inventory over the
remaining original approximately 130-year duration produces a small rate drift
if executed later (roughly 0.0021% per day). Co-signers should review the execution
timing and latest simulation before the final signature. Existing oracle/keeper
configuration still needs its separate operational review.

Run locally, with no hosting account or login:

```sh
cd scripts/beast-mode-restart
npm ci --ignore-scripts
npm start
```

Use Node 22 or newer. Open `http://localhost:4178` in your browser with Ready
installed. If using the shared devcontainer, forward port 4178 in VS Code's Ports
panel first. Then refresh/simulate, connect the multisig, review and open Ready.
The server binds loopback by default. Set `PORT` to choose a different port;
set `HOST=0.0.0.0` only when deploying behind a host such as Railway.
No ChatGPT account, Sites hosting or authentication is part of the app.

## Railway team review

Share **https://beast-mode-staging-production.up.railway.app**. Viewing the
page, inspecting calls and refreshing the unsigned simulation need no login or
wallet. Wallet confirmation is a separate action and supplies a signature.

The dedicated private Railway project is `Beast Mode Staging`, project
`a89da434-1d28-4ea7-ad06-87ea8af5c01f`, production environment
`09748e14-f22a-4218-b010-9b52eea60c8c`, service
`05cc54bf-010b-4be2-81d0-9e10fe9a0798`. Its generated service domain is public.
There are no server secrets, signing keys or database. The multi-stage Dockerfile
builds the static browser assets with Node 22 and runs a Node static server as
a non-root user. Railway checks `/` for health and routes port 8080.

To deploy this folder explicitly (no GitHub auto-deploy connection):

```sh
railway up scripts/beast-mode-restart --path-as-root \
  --project a89da434-1d28-4ea7-ad06-87ea8af5c01f \
  --environment 09748e14-f22a-4218-b010-9b52eea60c8c \
  --service 05cc54bf-010b-4be2-81d0-9e10fe9a0798 --detach
```

Run that command from the repository root after `npm test` in the tool folder.
The Docker build installs pinned dependencies and compiles the browser bundle.

The browser's **Final wallet change** section shows the net balance change first.
An initially collapsed **Intermediate Send / Receive** section contains gross outgoing,
incoming amounts and individual transfers from the successful simulation's actual
Transfer events, preserving all 18 decimals and including rounding refunds. It shows
both Ekubo NFTs and an expandable chronological list of wallet transfers with
counterparty addresses. Sale inventory received from TicketMaster is shown on
both sides when it is forwarded to Ekubo. Internal Ekubo movements and network
fees do not contribute to the wallet totals; no USD valuation is applied. The
same movement data is included in the unsigned draft's simulation result.

## Fork-only rollback rehearsal

The rollback runner uses a throttled, read-only loopback proxy to Cartridge
mainnet RPC. Successful reads pinned to a block are cached under the rollback
scratch directory; unpinned reads are never cached and write methods are refused.
Run cases sequentially to avoid origin rate limits.

The rollback runner uses the deployed contracts on an owned loopback Devnet,
with the same no-mainnet-write guard and automatic child-process cleanup as the
restart runner. It requires the same Node 22 and Devnet 0.10.1 setup:

```sh
BEAST_RESTART_DEVNET=/absolute/path/to/starknet-devnet npm run rehearse:rollback -- immediate
BEAST_RESTART_DEVNET=/absolute/path/to/starknet-devnet npm run rehearse:rollback -- traded
```

Use `BEAST_RESTART_BLOCK` to pin both scenarios to the same mainnet block.
Artifacts default to `/workspace/.scratch/beast-mode-rollback/<scenario>/`;
override `BEAST_RESTART_OUTPUT` only with a separate directory for each run.
The runner removes an old success verdict before starting, records failures,
and stops its own Devnet in `finally`. No signing credentials are used.

Each scenario starts from the original paused setup and executes the actual
14-call restart. The `immediate` case then unwinds without an external purchase;
TWAMM virtual execution can still sell tickets between the two transactions.
The `traded` case first funds a separate Devnet trader with 31 real fork LORDS
from the multisig **before recording its baseline**, executes a ticket purchase,
and advances one hour before unwinding. Only local fee STRK is minted.

Recovery uses one five-call atomic multisig transaction:

1. Withdraw the order NFT from TicketMaster to the multisig.
2. Withdraw the LP NFT from TicketMaster to the multisig.
3. Claim the sale's LORDS proceeds directly to TicketMaster, preserving the old
   proceeds and the existing revenue entitlement.
4. Cancel the full actual sale rate; send unsold tickets directly to TicketMaster.
   Ekubo requires proceeds to be claimed before a rate decrease in the same
   transaction (`MUST_WITHDRAW_PROCEEDS`).
5. Withdraw all LP liquidity and fees to the multisig, with minimum amounts at
   99% of the inspected LP principal.

A separate four-call dust swap then tests restoring the **original empty-pool
price**, after verifying the pool and aggregate sale rates are empty. Restoring
that stale price is an optional comparison step, not a requirement to recover
assets. Recovery bundles have state-dependent rates, liquidity and minimums;
they are marked `FORK_REHEARSAL_ONLY` and must not be signed as a standing undo.
No rollback action has been added to the production staging app.

Assertions cover an empty order, empty LP including fees, zero aggregate rates,
both NFTs back in the multisig, unchanged contract configuration/classes and
DAO/veLords balances, preserved legacy LORDS proceeds, and restart preflight
acceptance. The traded scenario also deliberately reverts after all unwind
calls and verifies their changes did not persist, then executes a valid unwind.
Its buyer must retain purchased tickets. `before.json`, `after.json` and
`result.json` record token balance deltas separately from operational recovery.

A successful unwind cannot erase transactions, fees, account nonces,
oracle/TWAMM history or trades already executed. New sale proceeds stay on
TicketMaster for its normal distribution; recovered LP capital is separate.
These scenarios do not claim old buybacks, distribute proceeds or exercise
issuance transitions. Mainnet signatures and fee estimates are not verified.

### Verified rollback results — 2026-10-15

Both cases passed on mainnet fork **16432906**, Devnet **0.10.1**, Node
**22.18.0**. Both returned the two NFTs to the multisig; emptied the order, LP
and aggregate sale rates; restored the original empty-pool price; preserved all
checked contract settings/classes, old LORDS proceeds and DAO/veLords balances;
and passed the restart builder's preflight again. The traded case's deliberately
failed sixth call reverted the five preceding recovery calls, leaving the NFTs,
LP principal, order rate and wallet/contract token balances unchanged.

Exact balances did **not** return to baseline, even without an external buyer:
the TWAMM already executes between restart and cancellation. Deltas below are
relative to each scenario's baseline; fees in STRK are excluded.

| Change | No external buyer | Buyer + one hour |
| --- | ---: | ---: |
| Multisig LORDS | -2.616462375370542557 | -1,163.966960520954010399 |
| Multisig D tickets | +0.084424094728098057 | +42.493411003666239358 |
| TicketMaster new LORDS proceeds | +2.616462375370542554 | +1,194.966960520954010396 |
| TicketMaster D-ticket reserve | -0.084424094728098060 | -43.490469369931657042 |
| Buyer LORDS | — | -31 |
| Buyer D tickets | — | +0.997058366265417680 |

Across the tracked multisig, TicketMaster and buyer, the unrecovered difference
was 3 raw LORDS units in each case, and 3 / 4 raw D-ticket units respectively
(1 raw unit = 1e-18 tokens). The larger per-account differences are asset
movements from executed sales, not missing capital. Proceeds remain on
TicketMaster for its original distribution rules. The buyer retains its tickets.
These results do not erase transaction history, nonces or oracle observations.

Reproducible evidence: `immediate/result.json`, `traded/result.json`, before/after
snapshots, unsigned recovery bundles and local receipts under
`/workspace/.scratch/beast-mode-rollback/`. The initial rejected ordering is
retained in `immediate/attempt-1/receipt-unwind.json`; it proves that sale proceeds
must be claimed before decreasing the rate. Both final run statuses are passed;
both Devnet processes and their read proxies are stopped.

## Separate controller prototype (fork only)

`controller/` contains a Cairo prototype that holds the Ekubo order and LP NFTs
while the existing D-ticket ERC20 and its founding-multisig ownership stay in
place. It uses OpenZeppelin two-step ownership, ERC20/ERC721 interfaces and
reentrancy protection pinned to git revision
`ddd3338e787a3fbf4a92b366640a57ee364390cb`. Scarb 2.15.0 and Foundry 0.55.0
build/test it. It has **not** been deployed to mainnet or added to the Railway
staging batch.

The constructor fixes the sale pool/key, position IDs, payment currency and
recipients. The prototype supports both payout modes:

| Sale currency | Direct share | Conversion share | Conversion destination |
| --- | --- | --- | --- |
| LORDS | 20% LORDS to veLords | 80% LORDS buys SURVIVOR | SURVIVOR to DAO |
| SURVIVOR | 80% SURVIVOR to DAO | 20% SURVIVOR buys LORDS | LORDS to veLords |

Conversions use the existing 1% LORDS/SURVIVOR TWAMM pool with a 3–7 day end;
the trials use approximately four days and advance local time to settlement.
Only newly claimed sale proceeds enter the split ledger. LP withdrawals return
only the principal/fees received by that withdrawal to the owner. Unrelated
payment-token donations can be recovered while paused without withdrawing
reserved proceeds. Conversion refunds have a separate ledger and are never
split a second time.

Owner-only methods claim/distribute proceeds, settle conversions, pause and
refill the sale, withdraw LP capital, recover surplus and release both NFTs.
Pausing claims proceeds before cancelling the rate and sends unsold tickets
back to the D-ticket contract. LP withdrawal requires a paused sale. NFT release
requires the sale/LP to be empty and proceeds/conversions fully settled. This
prototype **does not implement cancellation of an in-flight conversion**, so
its recovery demonstration settles conversions before NFT release. It also
has no upgrade entrypoint or automatic low-issuance/oracle keeper. Those are
production design decisions, not features implied by moving the NFTs.

Build and test (from `scripts/beast-mode-restart/controller`):

```sh
scarb --target-dir /workspace/.scratch/beast-mode-controller/target build
SCARB_TARGET_DIR=/workspace/.scratch/beast-mode-controller/target snforge test
```

Then run the two trials sequentially from `scripts/beast-mode-restart`:

```sh
BEAST_RESTART_BLOCK=16432906 BEAST_RESTART_DEVNET=/absolute/path/to/starknet-devnet npm run rehearse:controller -- lords
BEAST_RESTART_BLOCK=16432906 BEAST_RESTART_DEVNET=/absolute/path/to/starknet-devnet npm run rehearse:controller -- survivor
```

`BEAST_CONTROLLER_ARTIFACTS` can override the compiled artifact directory
(default `/workspace/.scratch/beast-mode-controller/target/dev`). Scenario
artifacts default to `/workspace/.scratch/beast-mode-controller/<mode>/`;
`BEAST_RESTART_OUTPUT` can override that with a separate directory per run.
Declaration/invocation writes are guarded to the owned loopback Devnet. The
read-only origin proxy cannot forward either write method to Cartridge.
Generated local trader keys are used only in memory; no mainnet keys are read.

Verified on fork **16432906** with controller class hash
`0x7108356c382eb98a975c512115e66c41cb8fd26ce2b5565b1642b5bd68dc975`:

- LORDS mode adopted original order #2248937 and LP #2248931, after settling the
  old NFT's outstanding buyback (2,948.420568398164817913 SURVIVOR to DAO).
  Original TicketMaster LORDS proceeds of 5,788.620457280262621088 stayed there.
  New proceeds of 1,199.903214708608612341 LORDS sent
  239.980642941721722468 LORDS to veLords and converted
  959.922571766886889873 LORDS into 88.911199901007972447 SURVIVOR for DAO.
- SURVIVOR mode created a separate fee-zero pool/order using the same D-ticket,
  existing sale end, stored active issuance rate, full range and TWAMM extension.
  A fork pool quote converted the original LORDS price/seed: initial tick
  -1069140; 939.635860959948717420 SURVIVOR paired with
  322.580575914001546305 D tickets. This quote is historical fork evidence and
  must be refreshed for any mainnet proposal.
  New proceeds of 112.883513541037522710 SURVIVOR sent
  **90.306810832830018168 SURVIVOR directly to DAO** and converted
  **22.576702708207504542 SURVIVOR into 237.610797443891432545 LORDS for veLords**.

Both cases verified a separately signed buyer purchase, rejected unauthorized
pause and active LP withdrawal, paused/refilled/paused again, excluded and
recovered a 7-token unrelated donation, kept LP capital out of the split,
settled real conversions, blocked premature NFT release and finally returned
both NFTs plus remaining LP capital to the multisig. Buyers kept their tickets;
original D-ticket ownership and old LORDS proceeds were unchanged. Conversion
refunds were zero in these runs; the separate refund-ledger path was not
exercised on the fork.

Both fork statuses passed and Devnets stopped. Cairo boundary tests and
256-run conservation/rounding fuzzing pass; all 28 JS tests pass, including
mainnet declaration rejection and proxy write refusal. Initial inspection,
controller configuration, tested amounts, setup, results and local receipts are retained in the
scenario artifact directories. The existing Railway app continues to stage
only the original 14-call restart; this trial does not alter that proposal.

## Compare routes in the Railway app

The route selector keeps **Plan A: Restore LORDS sale** and **Plan B: Migrate to
SURVIVOR** available in the same app. Share `/#lords` for the existing 14-call
restart, or `/#survivor` for the controller migration review plan.

Plan B shows the intended migration phases, payout split, historical fork
parameters/results, source link and outstanding production decisions. Its JSON
export is explicitly `REVIEW_PLAN_ONLY`, `executable: false`, with no mainnet
controller address or transaction calldata. It cannot request a wallet signature.
The full legacy-settlement-to-SURVIVOR production cutover still needs its final
rehearsal; the controller trials alone do not establish that entire batch.

Switching routes clears the current LORDS draft, simulation and acknowledgement.
Route switching is blocked during simulation or an outstanding wallet request.
The LORDS refresh/connect/download/stage handlers also guard the selected route,
and returning to Plan A requires refreshing its unsigned simulation again.

## Standalone LORDS controller handover

The app has two independently staged transactions:

1. `/#lords`: the original **14-call restart**, including the 10,000 LORDS seed,
   restores the pool/order and leaves both NFTs in TicketMaster custody.
2. `/#controller`: a later **6–11-call handover** reads the then-current running
   sale. It settles matured legacy buybacks, withdraws both existing NFTs,
   deploys the controller and transfers both NFTs into it. If TicketMaster holds
   LORDS, the batch withdraws and imports precisely that amount with a temporary
   exact allowance, then clears it. Finally the new controller claims unclaimed
   order proceeds directly into its ledger. No old-controller sale claim is
   needed: unclaimed sales follow the NFT and remain accounted for.

The second batch makes **no additional liquidity deposit**, takes no D-ticket
inventory from reserve and does not reprice, refill, cancel or replace the sale.
The pool, order key, actual active rate and LP liquidity are retained. Both
contracts remain owned by the founding multisig; the revenue split remains20%
LORDS to veLords /80% LORDS buys SURVIVOR for DAO. Wallet net token and NFT
movements are zero for the handover, excluding network fees; gross transfers
show the existing proceeds and both NFTs passing through the multisig.

The handover refuses a pre-restart setup, changed implementations/configuration,
missing TicketMaster NFT custody, inactive order/LP or immature legacy buybacks.
Its frozen calls are revalidated and simulated against fresh state before wallet
review. It can follow a running sale that has already traded. The `/#survivor`
tab remains an optional future review plan, without wallet staging.

Controller class declaration is a separate wallet transaction if the class has
not yet been declared. Refresh after it executes before reviewing the handover.
The app can simulate DECLARE followed by the exact handover before declaration.
`wallet_addDeclareTransaction` is the standard API; support by the team's actual
Ready multisig installation and real signatures have not been verified. The
unsigned JSON includes the declaration for a compatible wallet/tool if needed.
A wallet response does not prove onchain execution; check Ready activity/receipts.
The second signature can execute. Drafts expire in the page after four minutes;
already-signed wallet proposals have no added onchain expiration and need fresh
review if execution is delayed, particularly if legacy balances change.

The controller requires **manual multisig operations** for claim, distribute,
conversion claim, pause and refill. It has no automatic issuance/oracle keeper
or upgrade entrypoint. Pending conversions must mature before NFT release.
Implementation is fork-tested, not independently audited. Imported legacy and
claimed sales await a later multisig `distribute` call.

The exact **11-call standalone** handover passed on a pinned mainnet fork at
block16432906, after separately executing the original restart, making a LORDS
purchase and advancing one hour. Tests proved no additional wallet LORDS/tickets,
unchanged sale rate and LP liquidity, settlement/import of legacy proceeds,
claiming already-earned sales, whole-handover rollback when a final call fails,
unauthorized/unfunded import refusal, later buyer purchase, original revenue
split and conversion settlement, pause/refill, donation/LP capital separation,
and recovery of both NFTs and LP capital.36 JavaScript checks and the browser
build pass. No Cairo source or frozen controller release changed in this split.
The historical combined24-call simulation is superseded by this standalone flow;
current mainnet preparation remains blocked until the original restart executes.

Rehearse the separated sequence:

```sh
BEAST_CONTROLLER_STAGED=1 BEAST_RESTART_BLOCK=16432906 \
  BEAST_RESTART_DEVNET=/absolute/path/to/starknet-devnet \
  BEAST_RESTART_OUTPUT=/workspace/.scratch/beast-mode-controller/standalone \
  node controller-rehearsal.cjs lords
```

The reviewed release is reproducible:

```sh
cd controller
scarb --target-dir /workspace/.scratch/beast-mode-controller/target build
cd ..
node build-controller-release.cjs /workspace/.scratch/beast-mode-controller/target/dev
```

`web/release/` intentionally tracks the exact RPC Sierra artifact and release
hashes required for declaration. ABI canonical spacing is required for the
expected mainnet class hash; compiler debug information is excluded from RPC
payloads. Regenerating this artifact requires reviewing and rehearsing that class.

### Stage A USD estimate

The original restart route displays a seed-implied USD price per DTICKET:
`(seed LORDS / seed DTICKET) × LORDS/USD`. The displayed ratio and the transaction
builder share the same seed calculation; with the proposed seed this is about
31 LORDS per DTICKET. It is an initial spot estimate, not a fixed execution price.

The read-only `/api/lords-usd` endpoint fetches CoinGecko's LORDS/USD price with
its provider timestamp, caches successful responses for five minutes and rejects
quotes older than one hour, invalid values and future timestamps. Browser refresh
and the visible page's five-minute refresh update the estimate; unavailable prices
show an explicit unavailable state. This quote is informational and does not feed
transaction calldata, simulation minimums or wallet signing. The controller and
SURVIVOR routes do not display this seed valuation.
