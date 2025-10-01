# TicketMaster

TicketMaster leverages Ekubo's TWAMM extension to deliver demand-based, market-rate pricing for Dungeon Tickets. Built as an extension to OpenZeppelin's
ERC20 component, this system provides a stateful flow that automates TWAMM pool initialization, order creation, and distribution of proceeds. The contract
monitors Ekubo's on-chain oracle price feed over a configurable lookback period and can temporarily throttle issuance when the market trades below a
configured threshold, resuming once conditions recover.

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
    issuance_reduction_price_duration: u64,
    issuance_reduction_bips: u128,
    treasury_address: ContractAddress,
    recipients: Array<ContractAddress>,
    amounts: Array<u256>,
    distribution_end_time: u64,
    buyback_order_config: BuybackOrderConfig,
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
- Validates and caches issuance throttling configuration: a Q128 price threshold (`issuance_reduction_price_x128`),
  a lookback duration in seconds (`issuance_reduction_price_duration`, owner-configurable post-deployment), and a
  basis-point reduction (`issuance_reduction_bips`) that controls how much the distribution rate decreases when
  Ekubo's on-chain oracle reports prices below the threshold
- Accepts `buyback_order_config` to configure buyback TWAMM order constraints (min/max delay, min/max duration, fee)
- Aligns both optional start and mandatory end times to Ekubo's TWAMM bucket size; the current start
  time is tracked separately so restarts and throttling can reuse the most recent activation point
- `deployment_state` starts at `0`; time metadata is populated later by TWAMM calls

### Pool Bootstrap Flow

The contract follows a strict four-phase deployment sequence:

1. **Initialize Distribution Pool** – `init_distribution_pool(distribution_tick)` (owner-only)
   - Takes the distribution pool's initial tick as a parameter (must be computed off-chain after contract deployment)
   - Invokes Ekubo Core's `initialize_pool` to create the distribution pool
   - Caches the resulting pool identifier and advances state to `1 (DistributionPoolInitialized)`

2. **Seed Initial Liquidity** – `provide_initial_liquidity(payment_amount, dungeon_amount, min_liquidity)` (owner-only)
   - Transfers `payment_amount` of payment tokens from the caller to the contract
   - Mints `dungeon_amount` of dungeon tickets directly to Ekubo Positions contract
   - Calls Ekubo's `mint_and_deposit_and_clear_both` with symmetric bounds to establish the initial liquidity position
   - Validates that the resulting liquidity meets the `min_liquidity` threshold
   - Advances state to `2 (LiquidityProvided)`

3. **Start Token Distribution** – `start_token_distribution()` (callable by anyone once liquidity is provided)
   - Mints the remaining distribution supply (`tokens_for_distribution`) to Ekubo Positions
   - Opens a TWAMM sell order via `mint_and_increase_sell_amount`
   - Aligns the end time using `utils::get_buyback_endtime` and caps it with `utils::get_max_twamm_duration()`
   - Caches the position NFT token ID and advances state to `3 (DistributionStarted)`

4. **Recycle Proceeds** – Ongoing operations after distribution starts:
   - `claim_proceeds()`: Withdraws realized payment token sales from the distribution TWAMM order, then splits proceeds 80% to treasury and 20% for buybacks
   - `distribute_proceeds()`: Creates a new TWAMM buyback order using the accumulated 20% share, converting payment tokens back to buyback tokens over time
   - `claim_and_distribute_buybacks(limit)`: Iterates through matured buyback orders, withdrawing completed buyback tokens and forwarding them to the veLords address

### Buyback Order Configuration

The constructor accepts a `BuybackOrderConfig` structure that defines constraints for buyback TWAMM orders created
during proceeds distribution. This configuration includes:

- `min_delay` / `max_delay`: Valid time window (in seconds) between claiming proceeds and when the buyback order can start
- `min_duration` / `max_duration`: Valid duration range (in seconds) for the buyback order execution
- `fee`: The pool fee tier to use for buyback orders (encoded as a Q128 value)

These constraints ensure buyback orders are created with parameters that match the protocol's operational requirements
and prevent invalid TWAMM order configurations.

### Issuance Reduction Guard

The contract implements dynamic issuance throttling that responds to market conditions:

- `enable_low_issuance_mode()` checks the average price over the configured lookback period (specified by
  `issuance_reduction_price_duration` in seconds, owner-configurable) returned by Ekubo's on-chain oracle.
  When the average price drops below the configured Q128 threshold (`issuance_reduction_price_x128`), the
  function reduces the active distribution sale rate by `issuance_reduction_bips` (basis points) and holds
  the reclaimed tokens on the contract.
- `disable_low_issuance_mode()` performs the inverse operation: once the average price climbs back above
  the threshold over the same lookback period (querying Ekubo's on-chain oracle), the stored tokens are
  re-supplied to the TWAMM position and the original sale rate is restored.
- The contract exposes `is_low_issuance_mode()`, `get_low_issuance_returned_tokens()`,
  `get_issuance_reduction_price_x128()`, `get_issuance_reduction_price_duration()`, and
  `get_issuance_reduction_bips()` so off-chain monitoring can track throttle state and configuration.

This mechanism protects against oversupply during unfavorable market conditions while maintaining flexibility to
resume normal distribution rates when conditions improve.

### Public Interface Highlights

The on-chain interface (`ITicketMaster`) exposes:

- **Lifecycle actions**: `init_distribution_pool`, `provide_initial_liquidity`, `start_token_distribution`,
  `claim_proceeds`, `claim_and_distribute_buybacks`, `distribute_proceeds`,
  `enable_low_issuance_mode`, `disable_low_issuance_mode`
- **Pool & order metadata**: `get_distribution_pool_key`, `get_distribution_pool_key_hash`,
  `get_distribution_order_key`, `get_pool_id`, `get_distribution_fee`, `get_buyback_order_config`,
  `get_position_token_id`
- **Distribution telemetry**: `get_token_distribution_rate`, `get_tokens_for_distribution`,
  `get_distribution_end_time`, `get_distribution_initial_tick`, `get_lords_price_x128`,
  `get_dungeon_ticket_price_x128`, `get_survivor_price_x128`
- **Issuance controls**: `is_low_issuance_mode`, `get_low_issuance_returned_tokens`,
  `get_issuance_reduction_price_x128`, `get_issuance_reduction_price_duration`, `get_issuance_reduction_bips`
- **Administrative controls**: `set_treasury_address`, `set_velords_address`, `set_issuance_reduction_price_duration`,
  `withdraw_position_token`, `withdraw_funds`
- **Deployment helpers**: `get_deployed_at`, `get_payment_token`, `get_buyback_token`,
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

- **State machine guards**: Prevent re-entry into lifecycle phases out of order through strict `deployment_state` assertions
- **Address validation**: All external addresses (tokens, Ekubo contracts, treasury, veLords) are validated against the zero address during construction
- **Distribution supply protection**: Distribution supply is only minted when the TWAMM order is opened, preventing stranded balances
- **Time alignment**: Clamps distribution windows and enforces Ekubo's maximum duration to prevent invalid TWAMM operations
- **Issuance throttling safeguards**: Validates the configured oracle price floor, lookback duration, and basis-point reduction before mutating the distribution rate. Ensures reduction bips are less than `BIPS_BASIS` (10000) to prevent arithmetic errors
- **Emergency controls**: The owner can reclaim the distribution position NFT with `withdraw_position_token`, ensuring custody can be revoked if automated execution must halt. The owner can also use `withdraw_funds` to recover any ERC20 tokens from the contract
- **Administrative flexibility**: The owner can adjust `issuance_reduction_price_duration` via `set_issuance_reduction_price_duration` to tune the oracle lookback period without redeployment
- **Revenue distribution**: The 20% veLords revenue share ships with a constructor-provided address that the owner can rotate post-deployment via `set_velords_address`. Treasury address can similarly be updated via `set_treasury_address`
- **Registry integration**: Token registration with Ekubo's registry is part of deployment, ensuring the token metadata is discoverable on-chain

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
