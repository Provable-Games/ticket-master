# TicketMaster Smart Contract - Comprehensive Test Plan

## Overview

This test plan provides complete coverage for the TicketMaster smart contract (`src/contract.cairo`), which implements an ERC20 token distribution system using Ekubo's TWAMM (Time-Weighted Average Market Maker) protocol with dynamic issuance throttling based on oracle price feeds.

**Contract State Machine:**
- State 0: Initial (deployed)
- State 1: Distribution pool initialized
- State 2: Initial liquidity provided
- State 3: Distribution started

**Current Test Coverage:** ~62 tests exist
**Target:** Complete edge case, security, and integration coverage

---

## 1. Constructor Tests

### 1.1 Valid Initialization
- [x] **EXISTING**: `constructor_sets_initial_state` - Validates all storage variables are set correctly
- [ ] Constructor with empty recipients array (valid edge case)
- [ ] Constructor with maximum recipients array (stress test)
- [ ] Constructor with single recipient receiving entire supply
- [ ] Constructor with recipients receiving unequal amounts
- [ ] Constructor initializes ERC20 component correctly (name, symbol, decimals)
- [ ] Constructor initializes Ownable component correctly

### 1.2 Address Validation
- [x] **EXISTING**: `constructor_rejects_zero_payment_token`
- [x] **EXISTING**: `constructor_rejects_zero_reward_token` (buyback_token)
- [x] **EXISTING**: `constructor_rejects_zero_core_address`
- [x] **EXISTING**: `constructor_rejects_zero_positions_address`
- [x] **EXISTING**: `constructor_rejects_zero_position_nft_address`
- [x] **EXISTING**: `constructor_rejects_zero_extension_address`
- [x] **EXISTING**: `constructor_rejects_zero_registry_address`
- [x] **EXISTING**: `constructor_rejects_zero_oracle_address`
- [x] **EXISTING**: `constructor_rejects_zero_velords_address`
- [x] **EXISTING**: `constructor_rejects_zero_treasury_address`
- [x] **EXISTING**: `constructor_rejects_zero_recipient`
- [ ] Constructor rejects when owner is zero address

### 1.3 Parameter Validation
- [x] **EXISTING**: `constructor_rejects_mismatched_lengths` - Recipients/amounts array length mismatch
- [x] **EXISTING**: `constructor_rejects_distribution_exceeding_supply` - Total distributed > total supply
- [x] **EXISTING**: `constructor_rejects_end_before_now` - Distribution end time in past
- [x] **EXISTING**: `constructor_rejects_end_past_max_duration` - End time exceeds TWAMM max
- [ ] Constructor rejects zero total supply
- [ ] Constructor rejects when issuance_reduction_bips >= BIPS_BASIS (10000)
- [ ] Constructor with issuance_reduction_bips == BIPS_BASIS - 1 (boundary)
- [ ] Constructor with distribution_end_time == current_time + max_duration (boundary)
- [ ] Constructor validates recipient is not zero address in array iteration

### 1.4 Token Distribution
- [ ] Constructor mints 1 token to registry (ERC20_UNIT)
- [ ] Constructor correctly calculates tokens_for_distribution
- [ ] Constructor correctly distributes tokens to multiple recipients
- [ ] tokens_for_distribution = total_supply - distributed - ERC20_UNIT

### 1.5 Buyback Order Config
- [ ] Constructor stores buyback_order_config correctly
- [ ] Constructor with min_delay = 0 (orders can start immediately)
- [ ] Constructor with max_delay = 0 (orders must start immediately)
- [ ] Constructor with various min/max duration combinations

---

## 2. State Machine & Lifecycle Tests

### 2.1 init_distribution_pool()
- [x] **EXISTING**: `init_distribution_pool_sets_state` - State 0 → 1
- [x] **EXISTING**: `init_distribution_pool_wrong_state` - Rejects when state != 0
- [x] **EXISTING**: `init_distribution_pool_rejects_non_owner` - Owner-only check
- [ ] init_distribution_pool stores distribution_initial_tick correctly
- [ ] init_distribution_pool stores pool_id correctly
- [ ] init_distribution_pool with negative tick value
- [ ] init_distribution_pool with maximum positive tick value
- [ ] init_distribution_pool with maximum negative tick value
- [ ] init_distribution_pool can only be called once (idempotency)

### 2.2 provide_initial_liquidity()
- [x] **EXISTING**: `provide_initial_liquidity_happy_path` - Successful state 1 → 2
- [x] **EXISTING**: `provide_initial_liquidity_wrong_state` - Rejects when state != 1
- [x] **EXISTING**: `provide_initial_liquidity_rejects_non_owner` - Owner-only check
- [x] **EXISTING**: `provide_initial_liquidity_without_pool_id` - Rejects when pool not initialized
- [x] **EXISTING**: `provide_initial_liquidity_rejects_zero_payment_amount`
- [x] **EXISTING**: `provide_initial_liquidity_rejects_zero_dungeon_amount`
- [x] **EXISTING**: `provide_initial_liquidity_rejects_when_tokens_insufficient`
- [x] **EXISTING**: `provide_initial_liquidity_rejects_insufficient_remaining_supply`
- [x] **EXISTING**: `provide_initial_liquidity_updates_tokens_for_distribution`
- [x] **EXISTING**: `provide_initial_liquidity_consumes_stored_config` (fuzz test)
- [x] **EXISTING**: `insufficient_payment_tokens_edge` - Caller lacks payment tokens
- [ ] provide_initial_liquidity updates deployment_state to 2
- [ ] provide_initial_liquidity returns correct position_id, liquidity, cleared amounts
- [ ] provide_initial_liquidity transfers payment tokens from caller
- [ ] provide_initial_liquidity mints dungeon tickets to positions contract
- [ ] provide_initial_liquidity with minimum_liquidity threshold not met
- [ ] provide_initial_liquidity with exact remaining tokens_for_distribution
- [ ] provide_initial_liquidity can only be called once

### 2.3 start_token_distribution()
- [x] **EXISTING**: `start_token_distribution_happy_path` - Successful state 2 → 3
- [x] **EXISTING**: `start_token_distribution_wrong_state` - Rejects when state != 2
- [x] **EXISTING**: `start_token_distribution_without_pool` - Rejects when pool_id == 0
- [x] **EXISTING**: `test_start_token_distribution_without_tokens` - No tokens available
- [x] **EXISTING**: `distribution_start_succeeds_with_minimal_tokens_for_distribution`
- [ ] start_token_distribution stores position_token_id correctly
- [ ] start_token_distribution stores token_distribution_rate correctly
- [ ] start_token_distribution mints tokens to positions contract
- [ ] start_token_distribution creates TWAMM order with correct parameters
- [ ] start_token_distribution can only be called once
- [ ] start_token_distribution with 1 token available (minimum edge case)

### 2.4 State Transition Guards
- [ ] All state-dependent functions check deployment_state correctly
- [ ] State transitions are irreversible (can't go backwards)
- [ ] State 3 is terminal (no further state changes)

---

## 3. Proceeds Distribution Tests

### 3.1 claim_proceeds()
- [x] **EXISTING**: `claim_proceeds_returns_value` - Successfully claims proceeds
- [x] **EXISTING**: `claim_proceeds_before_pool_initialized` - Rejects when pool_id == 0
- [x] **EXISTING**: `claim_proceeds_before_distribution_started` - Rejects when state != 3
- [ ] claim_proceeds rejects when position_token_id == 0
- [ ] claim_proceeds rejects when proceeds == 0
- [ ] claim_proceeds returns correct amount
- [ ] claim_proceeds can be called multiple times
- [ ] claim_proceeds transfers payment tokens to contract
- [ ] claim_proceeds with maximum u128 proceeds value

### 3.2 distribute_proceeds()
- [x] **EXISTING**: `distribute_proceeds_before_pool_initialized` - Rejects when pool_id == 0
- [x] **EXISTING**: `distribute_proceeds_before_distribution_started` - Rejects when state != 3
- [ ] distribute_proceeds rejects when position_token_id == 0
- [ ] distribute_proceeds rejects when end_time <= start_time
- [ ] distribute_proceeds rejects when end_time <= current_time (expired)
- [ ] distribute_proceeds rejects when duration < min_duration
- [ ] distribute_proceeds rejects when duration > max_duration
- [ ] distribute_proceeds rejects when start_time delay < min_delay (if min_delay != 0)
- [ ] distribute_proceeds rejects when start_time delay >= max_delay
- [ ] distribute_proceeds rejects when proceeds == 0
- [ ] distribute_proceeds sends exactly 20% to veLords
- [ ] distribute_proceeds sends exactly 80% to buybacks
- [ ] distribute_proceeds with proceeds = 5 (rounding edge case)
- [ ] distribute_proceeds increments buyback_order_key_counter
- [ ] distribute_proceeds stores order end_time in mapping
- [ ] distribute_proceeds updates buyback_rate correctly
- [ ] distribute_proceeds creates buyback order with correct parameters
- [ ] distribute_proceeds with start_time == current_time (immediate start)
- [ ] distribute_proceeds with start_time in future
- [ ] distribute_proceeds with maximum valid duration
- [ ] distribute_proceeds with minimum valid duration

### 3.3 claim_and_distribute_buybacks()
- [x] **EXISTING**: `test_claim_and_distribute_buybacks_success_path`
- [x] **EXISTING**: `test_claim_and_distribute_buybacks_without_mature_proceeds`
- [x] **EXISTING**: `claim_and_distribute_buybacks_when_all_claimed`
- [x] **EXISTING**: `claim_and_distribute_buybacks_claims_limited_matured_orders`
- [x] **EXISTING**: `claim_and_distribute_buybacks_limit_zero_claims_remaining`
- [x] **EXISTING**: `fuzz_buyback_claim_limits` - Fuzz test for limit parameter
- [ ] claim_and_distribute_buybacks rejects when position_token_id == 0
- [ ] claim_and_distribute_buybacks with limit = 1 (claims exactly one order)
- [ ] claim_and_distribute_buybacks with limit > available orders
- [ ] claim_and_distribute_buybacks updates bookmark correctly
- [ ] claim_and_distribute_buybacks returns total_proceeds correctly
- [ ] claim_and_distribute_buybacks skips future orders (early exit)
- [ ] claim_and_distribute_buybacks with mixed mature/immature orders
- [ ] claim_and_distribute_buybacks sends proceeds to treasury
- [ ] claim_and_distribute_buybacks with zero proceeds from all orders (should revert)
- [ ] claim_and_distribute_buybacks bookmark persistence across calls
- [ ] claim_and_distribute_buybacks with exactly end_time == current_time (boundary)

---

## 4. Low Issuance Mode Tests

### 4.1 enable_low_issuance_mode()
- [x] **EXISTING**: `low_issuance_mode_adjusts_distribution_rate` - Full flow test
- [ ] enable_low_issuance_mode rejects when state != 3
- [ ] enable_low_issuance_mode rejects when position_token_id == 0
- [ ] enable_low_issuance_mode rejects when already active
- [ ] enable_low_issuance_mode rejects when reduction_price == 0
- [ ] enable_low_issuance_mode rejects when reduction_bips == 0
- [ ] enable_low_issuance_mode rejects when average_price >= reduction_price
- [ ] enable_low_issuance_mode rejects when distribution_rate == 0
- [ ] enable_low_issuance_mode rejects when rate_delta == 0 (reduction too small)
- [ ] enable_low_issuance_mode rejects when rate_delta > current_rate
- [ ] enable_low_issuance_mode rejects when returned_tokens == 0
- [ ] enable_low_issuance_mode reduces distribution rate correctly
- [ ] enable_low_issuance_mode sets low_issuance_mode_active to true
- [ ] enable_low_issuance_mode returns correct number of returned tokens
- [ ] enable_low_issuance_mode with reduction_bips = 1 (minimum reduction)
- [ ] enable_low_issuance_mode with reduction_bips = 9999 (maximum reduction)
- [ ] enable_low_issuance_mode with average_price = reduction_price - 1 (boundary)
- [ ] enable_low_issuance_mode calls oracle with THREE_DAYS_IN_SECONDS

### 4.2 disable_low_issuance_mode()
- [ ] disable_low_issuance_mode rejects when not active
- [ ] disable_low_issuance_mode rejects when reduction_price == 0
- [ ] disable_low_issuance_mode rejects when average_price <= reduction_price
- [ ] disable_low_issuance_mode rejects when no tickets in contract
- [ ] disable_low_issuance_mode transfers tickets to positions contract
- [ ] disable_low_issuance_mode increases sale rate correctly
- [ ] disable_low_issuance_mode sets low_issuance_mode_active to false
- [ ] disable_low_issuance_mode updates token_distribution_rate correctly
- [ ] disable_low_issuance_mode with average_price = reduction_price + 1 (boundary)
- [ ] disable_low_issuance_mode restores original rate after enable

### 4.3 Low Issuance Mode Integration
- [ ] Enable → Disable → Enable cycle works correctly
- [ ] Low issuance mode persists across multiple claim_proceeds calls
- [ ] Rate changes are reflected in subsequent distributions

---

## 5. Administrative Functions Tests

### 5.1 set_issuance_reduction_price_x128()
- [ ] set_issuance_reduction_price_x128 requires owner
- [ ] set_issuance_reduction_price_x128 rejects zero price
- [ ] set_issuance_reduction_price_x128 updates storage correctly
- [ ] set_issuance_reduction_price_x128 can be called multiple times
- [ ] set_issuance_reduction_price_x128 with maximum u256 value

### 5.2 set_issuance_reduction_bips()
- [ ] set_issuance_reduction_bips requires owner
- [ ] set_issuance_reduction_bips rejects zero bips
- [ ] set_issuance_reduction_bips rejects bips > BIPS_BASIS
- [ ] set_issuance_reduction_bips accepts bips == BIPS_BASIS
- [ ] set_issuance_reduction_bips updates storage correctly
- [ ] set_issuance_reduction_bips with bips = 1 (minimum)
- [ ] set_issuance_reduction_bips with bips = BIPS_BASIS (boundary)

### 5.3 set_buyback_order_config()
- [ ] set_buyback_order_config requires owner
- [ ] set_buyback_order_config updates all fields correctly
- [ ] set_buyback_order_config with min_delay = 0
- [ ] set_buyback_order_config with max_delay = 0
- [ ] set_buyback_order_config with min_duration > max_duration (should work at setter level)
- [ ] set_buyback_order_config affects subsequent distribute_proceeds calls

### 5.4 set_treasury_address()
- [x] **EXISTING**: `set_treasury_address_updates_for_owner`
- [x] **EXISTING**: `set_treasury_address_rejects_non_owner`
- [x] **EXISTING**: `set_treasury_address_no_zero_address`
- [ ] set_treasury_address affects claim_and_distribute_buybacks destination

### 5.5 set_velords_address()
- [ ] set_velords_address requires owner
- [ ] set_velords_address rejects zero address
- [ ] set_velords_address updates storage correctly
- [ ] set_velords_address affects distribute_proceeds veLords recipient

### 5.6 withdraw_position_token()
- [x] **EXISTING**: `transfer_distribution_position_token_moves_nft`
- [x] **EXISTING**: `transfer_distribution_position_token_requires_owner`
- [ ] withdraw_position_token rejects when position_token_id == 0
- [ ] withdraw_position_token rejects zero recipient address
- [ ] withdraw_position_token clears position_token_id to 0
- [ ] withdraw_position_token transfers NFT ownership
- [ ] withdraw_position_token prevents future distribution operations

### 5.7 withdraw_funds()
- [ ] withdraw_funds requires owner
- [ ] withdraw_funds transfers tokens to owner
- [ ] withdraw_funds with payment token
- [ ] withdraw_funds with buyback token
- [ ] withdraw_funds with dungeon ticket token
- [ ] withdraw_funds with arbitrary ERC20 token
- [ ] withdraw_funds with zero amount
- [ ] withdraw_funds with maximum available balance

---

## 6. ERC20 Token Functions Tests

### 6.1 burn()
- [x] **EXISTING**: `burn_reduces_balance_and_total_supply`
- [ ] burn from caller with zero balance (should revert)
- [ ] burn partial balance
- [ ] burn entire balance
- [ ] burn updates total supply correctly
- [ ] burn with amount > balance (should revert)

### 6.2 burn_from()
- [x] **EXISTING**: `burn_from_reduces_balance_and_total_supply`
- [x] **EXISTING**: `burn_from_rejects_without_allowance`
- [ ] burn_from reduces allowance correctly
- [ ] burn_from with exact allowance
- [ ] burn_from with amount > allowance (should revert)
- [ ] burn_from with unlimited allowance (max u256)

### 6.3 Standard ERC20 (via OpenZeppelin component)
- [ ] transfer() works correctly
- [ ] transfer() rejects insufficient balance
- [ ] transferFrom() with allowance
- [ ] approve() sets allowance
- [ ] balanceOf() returns correct balance
- [ ] totalSupply() reflects mints and burns
- [ ] name(), symbol(), decimals() return correct values

---

## 7. View Functions Tests

### 7.1 Storage Getters
- [x] **EXISTING**: `test_get_distribution_end_time_after_constructor`
- [ ] get_token_distribution_rate returns correct value
- [ ] get_buyback_rate returns correct value
- [ ] get_buyback_order_key_counter increments correctly
- [ ] get_buyback_order_key_bookmark updates correctly
- [ ] get_buyback_order_key_end_time returns correct end time for index
- [ ] get_distribution_initial_tick returns stored tick
- [ ] get_distribution_pool_fee returns stored fee
- [ ] is_low_issuance_mode returns correct boolean
- [ ] get_issuance_reduction_price_x128 returns stored price
- [ ] get_issuance_reduction_bips returns stored bips
- [ ] get_buyback_order_config returns all fields correctly
- [ ] get_pool_id returns correct pool identifier
- [ ] get_position_token_id returns correct NFT token id
- [ ] get_payment_token returns correct address
- [ ] get_extension_address returns correct address
- [ ] get_buyback_token returns correct address
- [ ] get_position_nft_address returns correct address
- [ ] get_core_dispatcher returns correct dispatcher
- [ ] get_positions_dispatcher returns correct dispatcher
- [ ] get_registry_dispatcher returns correct dispatcher
- [ ] get_oracle_address returns correct dispatcher
- [ ] get_tokens_for_distribution tracks correctly through lifecycle
- [ ] get_treasury_address returns correct address
- [ ] get_velords_address returns correct address
- [ ] is_pool_initialized returns false initially, true after init
- [ ] get_deployment_state returns 0, 1, 2, 3 through lifecycle

### 7.2 Computed Getters
- [x] **EXISTING**: `get_distribution_pool_key_respects_token_ordering` - Token ordering
- [ ] get_distribution_order_key returns correct OrderKey structure
- [ ] get_distribution_pool_key with this_token < payment_token
- [ ] get_distribution_pool_key with this_token > payment_token
- [ ] get_distribution_pool_key_hash computes correct poseidon hash
- [ ] get_buyback_pool_key returns correct PoolKey structure
- [ ] get_buyback_pool_key with buyback_token < payment_token
- [ ] get_buyback_pool_key with buyback_token > payment_token
- [ ] get_buyback_pool_key_hash computes correct hash
- [ ] get_unclaimed_buyback_orders_count returns counter - bookmark
- [ ] get_unclaimed_buyback_orders_count returns 0 when all claimed
- [ ] is_token0 returns true when contract address < payment token
- [ ] is_token0 returns false when contract address > payment token
- [ ] get_buyback_order_key constructs correct OrderKey for given times
- [ ] get_dungeon_ticket_price_x128 queries oracle correctly
- [ ] get_dungeon_ticket_price_x128 with various duration parameters

---

## 8. Integration & End-to-End Tests

### 8.1 Full Lifecycle
- [x] **EXISTING**: `mock_simple_flow` - Basic happy path
- [x] **EXISTING**: `simple_mainnet` - Fork test against mainnet
- [ ] Complete deployment → pool init → liquidity → distribution → claim → distribute
- [ ] Full lifecycle with low issuance mode activation mid-distribution
- [ ] Full lifecycle with multiple distribute_proceeds calls
- [ ] Full lifecycle with multiple claim_and_distribute_buybacks calls
- [ ] Full lifecycle with treasury and velords address changes

### 8.2 Complex Scenarios
- [ ] Multiple buyback orders with varying durations
- [ ] Claiming buybacks with some mature, some immature
- [ ] Low issuance enable/disable multiple times
- [ ] Owner transfer mid-lifecycle (via Ownable)
- [ ] Position NFT withdrawal and re-custody
- [ ] Large-scale fuzz test of distribution parameters

### 8.3 Time-Based Scenarios
- [ ] Distribution spanning multiple TWAMM epochs
- [ ] Buyback orders at edge of allowed delay windows
- [ ] Distribution ending exactly at end_time
- [ ] Claims occurring exactly at order maturity

### 8.4 Economic Edge Cases
- [ ] Zero proceeds from distribution (market failure scenario)
- [ ] Maximum proceeds stress test
- [ ] Rounding errors in 20/80 split with small amounts
- [ ] Dust amounts in various operations

---

## 9. Security & Access Control Tests

### 9.1 Ownership
- [x] **EXISTING**: `pause_like_behavior_via_owner_change` - Owner transfer scenario
- [ ] All owner-only functions reject non-owner
- [ ] Owner can renounce ownership (from Ownable)
- [ ] Owner transfer affects all protected functions
- [ ] Non-owner cannot call administrative functions

### 9.2 Reentrancy Protection
- [ ] claim_proceeds is reentrancy-safe
- [ ] distribute_proceeds is reentrancy-safe
- [ ] claim_and_distribute_buybacks is reentrancy-safe
- [ ] ERC20 transfers during operations don't allow reentrancy

### 9.3 State Manipulation
- [ ] Cannot skip states in deployment sequence
- [ ] Cannot call functions out of order
- [ ] State transitions are atomic
- [ ] Storage variables cannot be corrupted through function sequences

### 9.4 Integer Overflow/Underflow
- [ ] All arithmetic operations are overflow-safe (Cairo built-in)
- [ ] Counter increments don't overflow
- [ ] Balance calculations don't underflow
- [ ] Percentage calculations (20/80 split) are safe

### 9.5 External Call Safety
- [ ] Failed external calls to Ekubo contracts revert properly
- [ ] Mock failures in Ekubo dispatcher calls
- [ ] Oracle price feed failures are handled
- [ ] ERC20 transfer failures are handled

---

## 10. Gas & Performance Tests

### 10.1 Gas Optimization
- [ ] claim_and_distribute_buybacks with limit vs limit=0 gas comparison
- [ ] Batch vs individual buyback claims efficiency
- [ ] Storage read/write patterns are optimized

### 10.2 Stress Tests
- [x] **EXISTING**: `fuzz_constructor_valid_configs` - Constructor parameter fuzzing
- [x] **EXISTING**: `fuzz_buyback_claim_limits` - Claim limit fuzzing
- [x] **EXISTING**: `test_distribute_initial_tokens_multiple_recipients` - Recipient array fuzzing
- [ ] Maximum number of buyback orders (1000+)
- [ ] Maximum number of initial token recipients
- [ ] Extremely long distribution periods
- [ ] Rapid succession of distribute_proceeds calls

---

## 11. Edge Cases & Corner Cases

### 11.1 Boundary Values
- [ ] u128::MAX values in various numeric fields
- [ ] u256::MAX values in token amounts
- [ ] i129 tick boundaries (positive/negative extremes)
- [ ] Time at exactly u64::MAX
- [ ] Zero values where allowed vs rejected

### 11.2 Precision & Rounding
- [ ] Percentage calculations with amounts = 1, 2, 3, 4, 5
- [ ] TWAMM rate calculations with minimal amounts
- [ ] Bips calculations with edge values
- [ ] Q128 price calculations

### 11.3 Array Operations
- [ ] Empty arrays where allowed
- [ ] Single-element arrays
- [ ] Large arrays (100+ elements)
- [ ] Arrays with duplicate addresses

### 11.4 Address Edge Cases
- [ ] Contract calling itself (address == get_contract_address())
- [ ] Addresses that are contracts vs EOAs
- [ ] Sequential addresses (n, n+1, n+2)

---

## 12. Negative Tests (Failure Cases)

### 12.1 Expected Failures
- [ ] All validation failures produce correct error messages
- [ ] Error messages match constants in src/constants.cairo
- [ ] Revert reasons are descriptive and actionable

### 12.2 Panic Scenarios
- [ ] Division by zero is prevented
- [ ] Array out of bounds is prevented
- [ ] Type conversion failures are handled

---

## 13. Fork Testing (Mainnet Integration)

### 13.1 Real Ekubo Integration
- [x] **EXISTING**: `simple_mainnet` - Basic mainnet fork test
- [ ] Pool initialization on real Ekubo core
- [ ] Liquidity provision to real pools
- [ ] TWAMM order creation on real extension
- [ ] Oracle price queries from real oracle
- [ ] Token registry interactions

### 13.2 Multi-Block Scenarios
- [ ] Distribution over multiple blocks
- [ ] Time-based state changes across blocks
- [ ] Oracle price changes over time

---

## 14. Upgrade & Migration Tests

### 14.1 Storage Layout
- [ ] Storage variables don't collide
- [ ] Component storage is properly isolated
- [ ] Map storage keys are unique

### 14.2 Contract Interactions
- [ ] Multiple TicketMaster instances don't interfere
- [ ] Shared Ekubo contracts handle multiple callers
- [ ] Token registry supports multiple tokens

---

## Test Implementation Priority

### P0 - Critical (Security & Core Functionality)
1. All remaining constructor validation tests
2. State machine transition guards
3. Access control for all administrative functions
4. Reentrancy and external call safety tests
5. Low issuance mode complete coverage
6. Proceeds distribution arithmetic correctness

### P1 - High (Feature Completeness)
1. All view function tests
2. Buyback claim logic edge cases
3. ERC20 burn functionality
4. Administrative setters complete coverage
5. Position NFT withdrawal scenarios

### P2 - Medium (Edge Cases & Integration)
1. Boundary value tests
2. Time-based scenario tests
3. Rounding and precision tests
4. Multi-order buyback scenarios

### P3 - Low (Performance & Stress)
1. Gas optimization tests
2. Large-scale stress tests
3. Fuzz testing expansion
4. Fork testing expansion

---

## Test Categories Summary

| Category | Total Tests Needed | Existing | To Add |
|----------|-------------------|----------|--------|
| Constructor | 35 | 12 | 23 |
| State Machine | 30 | 13 | 17 |
| Proceeds Distribution | 45 | 7 | 38 |
| Low Issuance Mode | 25 | 1 | 24 |
| Administrative | 30 | 3 | 27 |
| ERC20 Functions | 15 | 2 | 13 |
| View Functions | 50 | 2 | 48 |
| Integration | 20 | 2 | 18 |
| Security | 25 | 1 | 24 |
| Edge Cases | 40 | 3 | 37 |
| **TOTAL** | **315** | **46** | **269** |

*Note: Existing count includes fuzz tests which cover multiple scenarios*

---

## Testing Tools & Utilities Needed

1. **Mock Contracts:**
   - Enhanced Ekubo dispatcher mocks for failure scenarios
   - Oracle mock for controlled price feeds
   - ERC20 mock with configurable transfer failures

2. **Helper Functions:**
   - Time manipulation utilities (already available in snforge_std)
   - State setup shortcuts for each deployment phase
   - Assertion helpers for complex struct comparisons

3. **Fuzzing Targets:**
   - Constructor parameter combinations
   - Distribution amounts and durations
   - Buyback order configurations
   - Low issuance mode transitions

4. **Fork Testing:**
   - Mainnet state snapshots at specific blocks
   - Multi-block test scenarios
   - Real oracle price feed integration

---

## Success Criteria

- [ ] 100% line coverage in src/contract.cairo
- [ ] 100% branch coverage for all conditional logic
- [ ] All state transitions tested
- [ ] All error paths tested
- [ ] All access control enforced
- [ ] All view functions validated
- [ ] Integration tests for complete lifecycle
- [ ] Security tests pass (no reentrancy, overflow, etc.)
- [ ] Fork tests pass against real Ekubo contracts
- [ ] All edge cases identified and tested
