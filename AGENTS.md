# Repository Guidelines

## Project Structure & Module Organization
Keep contract sources under `src/`. `contract.cairo` serves as the TicketMaster entrypoint, `interfaces.cairo` exposes the Starknet ABI, and `utils.cairo` hosts TWAMM and fee helpers. Shared values live in `src/constants.cairo`. Unit-style specs stay beside their modules, while end-to-end and fork tests belong in `tests/` for Starknet Foundry (`snforge`) to discover. Build artifacts such as `target/` and `.snfoundry_cache/` remain untracked.

## Build, Test, and Development Commands
Use `scarb build` to compile the Cairo package and confirm lockfiles resolve. Run `snforge test` for the full suite, or narrow with targets like `snforge test util_tests::` while iterating on helpers. Capture resource deltas before merging via `snforge test --detailed-resources`. Format all Cairo modules with `scarb fmt` before committing. Deployment scripts reside in `scripts/` and expect environment variables sourced from the provided `.env.*` files.

## Coding Style & Naming Conventions
Adopt four-space indentation, grouped imports, and snake_case for functions/modules. Structs and type aliases use UpperCamelCase, while constants follow SCREAMING_SNAKE_CASE (see `src/constants.cairo`). Document public ABI functions with triple-slash comments so downstream tooling surfaces them. Always run `scarb fmt` and address formatter feedback instead of manual spacing tweaks.

## Testing Guidelines
Favor positive and guard-path assertions for any new logic; regressions need reproducing tests. Unit helpers should live with their modules (e.g., TWAMM helpers in `src/utils.cairo`), while end-to-end scenarios stay under `tests/`. Name tests `test_<feature>_<expectation>` to keep failure output searchable. For fork tests, annotate with `#[fork("<network>")]` and verify prerequisites such as approvals or oracle mocks. Leverage Foundry fuzzing and storage inspection when defending edge cases like low-issuance mode transitions. When adding new storage variables or getters (e.g., `liquidity_position_id`), ensure corresponding getter tests verify storage consistency after relevant state transitions.

## Commit & Pull Request Guidelines
Follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`) with subjects under ~70 characters. Squash fixups locally and avoid merge commits in feature branches. PR descriptions should summarize context, cite the `snforge` commands run, link relevant issues, and highlight security-sensitive touchpoints (reentrancy, access control, math safety). Before requesting review, ensure formatting is clean, fork tests are green, and new parameters (e.g., oracle, position NFT addresses) are wired through constructors and deployment helpers.

## Security & Review Focus
Validate oracle-driven low-issuance flows (`enable_low_issuance_mode`, `disable_low_issuance_mode`) with both entry and exit tests. Treat proceeds distribution, TWAMM interactions, and owner-only pathways as audit priorities—justify any departure from existing patterns. Confirm external calls (registries, Ekubo dispatchers, ERC20/ERC721 withdrawals) respect access control and cannot strand tokens. When touching deployment scripts, thread new addresses and ticks end-to-end to prevent misconfigured mainnet operations.
