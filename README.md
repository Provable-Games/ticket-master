# TicketMaster

TicketMaster leverages Ekubo's TWAMM extension to deliver demand-based, market-rate pricing for Dungeon Tickets. Delivered as an extension to OpenZeppelin
ERC20 component, this system provides a stateful flow that automates TWAMM pool initialization, order creation, and distribution of proceeds. The contract now
monitors a three-day average price feed and can temporarily throttle issuance when the market trades below a configured threshold, resuming once conditions
recover.

## Repository Layout

- `src/contract.cairo` – TicketMaster contract that owns the ERC20 logic and the TWAMM orchestration
- `src/interfaces.cairo` – Starknet interface exposing the on-chain API consumed by clients/tests
- `src/utils.cairo` – Time-alignment and TWAMM fee helpers shared by the contract and inline tests
- `src/constants.cairo` – Error strings and math constants reused across modules
- `tests/` – Starknet Foundry integration and fork tests
- `target/`, `.snfoundry_cache/` – Build artefacts (kept out of version control)

## Contract Overview

### Lifecycle & State Machine

TicketMaster keeps a strict deployment state to protect critical actions:

1. **0 – Initial**: Deployment finished, Ekubo pools not yet initialized
2. **1 – DistributionPoolInitialized**: `init_distribution_pool` stored the caller-supplied tick,
   initialized the distribution pool, and cached its identifier
3. **2 – LiquidityProvided**: `provide_initial_liquidity` minted/seeded the pool and cached bounds
4. **3 – DistributionStarted**: `start_token_distribution` opened the TWAMM order and locked supply

Transition enforcement (assertions on `deployment_state`) is the primary access-control barrier.

### Constructor Responsibilities

```
constructor(
    owner: ContractAddress,
    name: ByteArray,
    symbol: ByteArray,
    total_supply: u128,
    buyback_pool_fee: u128,
    distribution_pool_fee: u128,
    payment_token: ContractAddress,
    buyback_token: ContractAddress,
    core_address: ContractAddress,
    positions_address: ContractAddress,
    position_nft_address: ContractAddress,
    extension_address: ContractAddress,
    registry_address: ContractAddress,
    oracle_address: ContractAddress,
    velords_address: ContractAddress,
    issuance_reduction_price_x128: u256,
    issuance_reduction_bips: u128,
    treasury_address: ContractAddress,
    recipients: Array<ContractAddress>,
    amounts: Array<u256>,
    distribution_end_time: u64,
)
```

- Registers the token with Ekubo's on-chain registry (mints 1 unit directly to the registry)
- Mints the distribution ERC20 to a configurable list of recipients and records the remainder for
  TWAMM execution (`tokens_for_distribution`)
- Stores Ekubo dispatchers (core, positions, registry, extension), the associated position NFT
  address, oracle access, the veLords revenue recipient, and bootstrap parameters for both the
  distribution and buyback legs
- Defers pool ticks and seed liquidity to owner-only bootstrap calls so deployment-time pricing can
  be computed off-chain after the contract address is known
- Validates and caches issuance throttling configuration: a Q128 price threshold and a basis-point
  reduction that can be invoked when prices fall
- Aligns both optional start and mandatory end times to Ekubo's TWAMM bucket size; the current start
  time is tracked separately so restarts and throttling can reuse the most recent activation point
- `deployment_state` starts at `0`; time metadata is populated later by TWAMM calls

### Pool Bootstrap Flow

1. **Initialize Distribution Pool** – `init_distribution_pool(distribution_tick)` (owner-only) stores the
   caller-provided tick, invokes `ICore.initialize_pool`, and records the resulting pool identifier
2. **Seed Liquidity** – `provide_initial_liquidity(payment_amount, dungeon_amount, min_liquidity)`
   (owner-only) transfers the payment token from the caller, mints dungeon tickets directly to the
   positions contract, and calls `mint_and_deposit_and_clear_both` with symmetric bounds
3. **Start Distribution** – `start_token_distribution()` mints the cached distribution supply to
   positions and opens a TWAMM order via `mint_and_increase_sell_amount`. The requested end time is
   aligned with `utils::get_buyback_endtime` and capped by `utils::get_max_twamm_duration()`
4. **Recycle Proceeds** – `claim_proceeds()` withdraws realized sales from the distribution order for
   treasury routing, while `claim_and_distribute_buybacks(limit)` walks matured buyback orders and
   forwards their proceeds to veLords once their end-time has elapsed

### Issuance Reduction Guard

- `enable_low_issuance_mode()` checks the three-day average price returned by the Ekubo oracle. When it
  drops below the configured Q128 threshold, the function reduces the active distribution sale rate
  by `issuance_reduction_bips` and holds the reclaimed tokens on the contract.
- `disable_low_issuance_mode()` performs the inverse operation: once the average price climbs back above
  the threshold, the stored tokens are re-supplied to the TWAMM position and the original sale rate is
  restored.
- The contract exposes `is_low_issuance_mode()`, `get_low_issuance_returned_tokens()`, and
  `get_issuance_reduction_price_x128()` so off-chain monitoring can track throttle state.

### Public Interface Highlights

The on-chain interface (`ITicketMaster`) exposes:

- Lifecycle actions: `init_distribution_pool`, `provide_initial_liquidity`, `start_token_distribution`,
  `claim_proceeds`, `claim_and_distribute_buybacks`, `distribute_proceeds`,
  `enable_low_issuance_mode`, `disable_low_issuance_mode`
- Pool & order metadata: `get_distribution_pool_key`, `get_distribution_pool_key_hash`,
  `get_distribution_order_key`, `get_pool_id`, `get_buyback_pool_fee`,
  `get_position_token_id`
- Distribution telemetry: `get_token_distribution_rate`,
  `get_distribution_end_time`, `get_distribution_initial_tick`, `get_lords_price_x128`,
  `get_dungeon_ticket_price_x128`, `get_survivor_price_x128`
- Issuance controls: `is_low_issuance_mode`, `get_low_issuance_returned_tokens`,
  `get_issuance_reduction_price_x128`
- Administrative controls: `set_treasury_address`, `set_velords_address`, `withdraw_position_token`
- Deployment helpers: `get_deployed_at`, `get_payment_token`, `get_buyback_token`,
  `get_extension_address`, `get_core_dispatcher`, `get_positions_dispatcher`,
  `get_registry_dispatcher`, `get_oracle_address`, `get_velords_address`, `get_treasury_address`,
  `is_pool_initialized`, `get_deployment_state`

### Time Utilities

`src/utils.cairo` contains the shared helpers that power TWAMM alignment and fee validation:

- `get_buyback_endtime` – aligns a timestamp to the closest valid TWAMM bucket (rounds to nearest
  bucket instead of always rounding up)
- `time_difference_to_step_size` – returns the correct Ekubo step size for a time delta
- `get_max_twamm_duration` – global upper bound enforced by `start_token_distribution`

## Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) **v2.12.2+**
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) **v0.49.0+**
- Cairo compiler **2.12.x**
- Access to Ekubo core, positions, TWAMM extension and registry addresses for your target chain

## Setup

```bash
# Clone the repository
git clone <repo-url>
cd ticket-master

# Create your environment file from the example
cp .env.example .env
# Then edit .env to fill in your account, RPC, token config, and initial liquidity

# Compile the package
scarb build
```

## Development Workflow

### Build

```bash
scarb build
```

### Test

```bash
# Run the complete suite
snforge test

# Focus on time rounding helpers
snforge test util_tests::

# Execute against configured forks (see Scarb.toml for RPC details)
snforge test --fork mainnet
snforge test --fork sepolia

# Inspect Cairo resource usage
snforge test --detailed-resources
```

### Format

```bash
scarb fmt
```

## Testing Strategy

- **Unit tests** live alongside their modules (for example, `src/utils.cairo` covers TWAMM time
  alignment and fee validation)
- **Integration & fork tests** under `tests/` deploy TicketMaster, mock Ekubo calls where needed and
  exercise the full bootstrap flow; the `#[fork("mainnet")]` scenario turns real Ekubo addresses
  into regression coverage
- Use `snforge test --detailed-resources` to capture resource deltas whenever distribution logic
  changes

## Security Considerations

- State machine guards prevent re-entry into lifecycle phases out of order
- All external addresses are validated against the zero address during construction
- Distribution supply is only minted when the TWAMM order is opened, preventing stranded balances
- Time alignment clamps distribution windows and enforces Ekubo's maximum duration
- Issuance throttling enforces the configured oracle price floor and validates the basis-point
  reduction before mutating the distribution rate
- The owner can reclaim the distribution position NFT with `withdraw_position_token`,
  ensuring custody can be revoked if automated execution must halt
- The 20% veLords revenue share ships with a constructor-provided address that the owner can
  rotate post-deployment via `set_velords_address`
- Registry registration is part of deployment, ensuring the token metadata is discoverable

## Contributing

1. Format Cairo sources with `scarb fmt`
2. Run `snforge test` (add fork or fuzzing runs if behaviour touches Ekubo integrations)
3. Update documentation and tests alongside code changes
4. Follow Conventional Commits (`feat:`, `fix:`, `refactor:`, …) for git history

## License

This project is released under the MIT License. See `LICENSE` for the full text.

## Acknowledgements

- [Ekubo](https://www.ekubo.org/) for the TWAMM infrastructure
- [OpenZeppelin](https://www.openzeppelin.com/) for audited Cairo components
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) for the testing toolkit
