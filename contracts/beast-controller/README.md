# Beast Mode controller: contract and declaration review

This PR isolates the exact controller source and declaration artifact used by the
existing fork rehearsals. It does not deploy a contract, restart the sale, transfer
NFTs or funds, or change the staging website. The source retains its prototype
warning and `TrialController` name: review has not approved production custody.

This is an independent Scarb package under `contracts/beast-controller`, with
its own pinned toolchain and lockfiles. Run the commands below from this directory.
The root TicketMaster package keeps its existing compiler and dependencies.

## First step: review, then declare

Review this source and the immutable release hashes before requesting a mainnet
declaration. Declaration registers code; it does not run the constructor, create
the controller instance, transfer custody, or approve its production use.

| Artifact | Expected hash |
| --- | --- |
| Sierra class | `0x31d9c6a818101ef6f44ce316212f9b9ee304ab98790c34929fcdeb646cccdda` |
| Compiled class | `0x368ad3b4366ca947b110f11d4bf67974c3b0b5a5299569cac44f09cd3c78d1a` |

`release/controller-class.json` is the exact RPC Sierra class for a compatible
DECLARE v3 wallet/tool. `release/controller.json` records both hashes. A signed
declaration also needs the account's nonce, fee/resource bounds and signatures;
these files are not a signed or broadcast-ready transaction. Ready multisig
declaration support has not been verified with the real wallet.

The artifact excludes compiler debug information and preserves canonical ABI
spacing because the serialized ABI affects the class hash. Any source/compiler
change requires rebuilding, reviewing the new hashes and updating the staging
release before declaration. Keep the package/contract names unchanged when
reproducing this release.

After declaration, verify the exact class on mainnet. Deployment and custody
transfer remain a later, separately reviewed atomic transaction. The proposed
direct route leaves both position NFTs with the multisig during restart, then
transfers them directly to the new controller. That route still needs a new batch
and fork rehearsal, including old buyback settlement and legacy LORDS accounting.
The existing staging handover instead expects TicketMaster custody after restart;
do not use it unchanged for the direct route.

## Contract behavior

The constructor fixes the protocol/token addresses, payout recipients, pool/order
keys, bounds and both NFT IDs. It accepts either LORDS or SURVIVOR payment mode;
the intended immediate deployment is LORDS mode with the existing D-ticket token,
order NFT 2248937 and LP NFT 2248931. Declaration alone chooses neither mode.
The intended owner is the existing founding multisig. OpenZeppelin two-step
ownership transfer and a reentrancy guard are included.

All fund-management entrypoints require the owner:

| Method | Behavior |
| --- | --- |
| `import_proceeds` | Pull explicitly approved payment tokens into the proceeds ledger, checking the exact balance increase. |
| `claim` | Claim the ticket order's proceeds into that ledger. |
| `distribute` | Claim and split proceeds; in LORDS mode send 20% to veLords and create a 3–7 day SURVIVOR buyback with the remainder. |
| `claim_conversion` | After maturity, send the actual buyback output to DAO in LORDS mode. |
| `pause_sale` | Claim proceeds and cancel the active ticket-sale rate; return unsold tickets to the original ticket contract. |
| `refill_sale` | While paused, add controller-held tickets to the sale and resume. Tickets returned to TicketMaster must first be recovered/funded through owner operations. |
| `withdraw_lp` | While paused, withdraw LP capital and fees to the owner with supplied minimum outputs. |
| `recover_surplus` | While paused, recover unreserved sale/payment tokens without consuming tracked proceeds. |
| `release_positions` | Return both NFTs to the owner only after the sale, LP, proceeds and conversions are fully settled. |

LP capital and donations are excluded from the proceeds split. Conversion refunds
are reserved and carried into a later conversion without splitting them again.
The SURVIVOR mode in this same class instead sends 80% directly to DAO and
converts 20% into LORDS for veLords; it is not the immediate rollout plan.

## Review limits and evidence

There is no automatic issuance/oracle keeper, upgrade entrypoint, or early
cancellation of conversion orders. All operations require multisig transactions.
Existing TicketMaster automation loses position authority after custody changes.
In-flight conversions must mature before NFT release. The conversion-refund carry
path has not been exercised with a nonzero refund on the fork. This code has not
been independently audited.

The two checked-in Cairo tests cover split boundaries and 256 fuzz runs for
conservation/rounding only. They are not contract authorization or integration
tests. The broader rehearsal lives in the existing
[staging PR #51](https://github.com/Provable-Games/cairo-devcontainer/pull/51),
source commit `5b1e221`; use its `controller-rehearsal.cjs` and README to reproduce
the mainnet-fork integration checks. That rehearsal tested restart followed by a
TicketMaster-to-controller handover, not the proposed direct route.

At fork block 16432906 the standalone 11-call handover passed after restart, a
signed 31 LORDS purchase and one hour of elapsed time. Checks covered unchanged
sale rate/liquidity and owner balances, legacy buyback settlement, proceeds
import, exact allowance clearance, whole-batch rollback on a failing final call,
owner authorization, later purchases, payout/conversion settlement, pause/refill,
donation/LP separation and NFT recovery. This is historical fork evidence, not a
fresh mainnet handover simulation.

## Reproduce the declaration

Use Scarb/Cairo 2.15.0, snforge 0.55.0, Node 22+ and the checked-in lockfiles.
Run from this directory; generated build output belongs outside the repository:

```bash
export SCARB_TARGET_DIR=/workspace/.scratch/beast-controller-review/target
scarb fmt --check
scarb build
scarb test
npm ci
npm run verify:release -- "$SCARB_TARGET_DIR/dev"
```

The verifier compares the entire RPC artifact against the fresh build and checks
both class hashes. It does not modify the release or submit transactions.
