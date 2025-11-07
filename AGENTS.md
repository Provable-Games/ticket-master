# Repository Guidelines

## Project Structure & Module Organization

- Source contracts live under `src/`; `contract.cairo` is the TicketMaster entrypoint, `interfaces.cairo` exposes the Starknet ABI, and `utils.cairo` holds TWAMM and fee utilities.
- Shared constants sit in `src/constants.cairo`; unit-style specs live alongside their modules (for example, TWAMM helper tests remain in `src/utils.cairo`).
- End-to-end and fork tests belong in `tests/`, consumable by Starknet Foundry. Keep build outputs (`target/`, `.snfoundry_cache/`) untracked.

## Build, Test, and Development Commands

- `scarb build` — compile the Cairo package and verify dependency locks resolve.
- `snforge test` — run the full Foundry suite; use `snforge test util_tests::` when iterating on time helpers.
- `snforge test --detailed-resources` — capture gas/resource deltas before merging.
- `scarb fmt` — format all Cairo modules to the project standard.

## Coding Style & Naming Conventions

- Favor four-space indentation and grouped imports; always run `scarb fmt` before committing.
- Functions and modules use `snake_case`; structs and type aliases use `UpperCamelCase`; constants follow `SCREAMING_SNAKE_CASE` per `src/constants.cairo`.
- Document public ABIs with triple-slash comments so tooling surfaces them.

## Testing Guidelines

- Write positive and guard-path assertions for new behavior; regressions need reproducing tests.
- Keep unit helpers alongside their modules (for example, TWAMM helpers stay in `src/utils.cairo`); scenario tests stay in `tests/`.
- Name tests `test_<feature>_<expectation>` for searchable failures.
- Leverage Foundry fuzzing, storage inspection, and forking when edge cases demand it.

## Feature Notes

- TicketMaster now tracks a low-issuance mode controlled by oracle pricing. Enter the mode when the three-day average price is below `issuance_reduction_price_x128`, and exit only after the average rises back above the threshold.
- Reducing issuance relies on `issuance_reduction_bips`; validate inputs remain `< BIPS_BASIS` and ensure tests cover both entry and exit paths.
- Constructor calls must supply the Ekubo oracle address plus issuance reduction parameters, and tests in `tests/test_contract.cairo` set expectations for the new getters (`is_low_issuance_mode`, `get_low_issuance_returned_tokens`, etc.).
- Constructor now also accepts the veLords revenue recipient address; deployment tooling and tests must thread this parameter and leverage `set_velords_address` for post-deploy rotations.
- Constructor now also requires the address of the position NFT contract; make sure helpers and deployment scripts thread this through whenever the positions deployment differs from the NFT address.
- `init_distribution_pool` now accepts a single distribution tick (owner-only), persists it, and returns the pool identifier; `provide_initial_liquidity` likewise takes payment/dungeon/minimum amounts and is owner-only. Deployment tooling should derive the distribution tick after the contract address is known and pass the liquidity values to this step.
- proceeds distribution splits payment token balances 20/80 between the stored veLords address and TWAMM buybacks; use the new setter when rotating recipients.

## Commit & Pull Request Guidelines

- Follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`); keep subjects under ~70 characters.
- Squash fixups locally and avoid merge commits in feature branches.
- PRs should outline context, cite `snforge` commands run, link issues, and flag security-sensitive changes.

## Security & Review Focus

- Treat reentrancy, access control, and math safety as audit priorities; justify deviations from established patterns.
- Prefer incremental, tested changes; validate risky modifications locally before requesting review.
