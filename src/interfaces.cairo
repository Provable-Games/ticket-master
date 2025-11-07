use ekubo::interfaces::core::ICoreDispatcher;
use ekubo::interfaces::extensions::twamm::OrderKey;
use ekubo::interfaces::positions::IPositionsDispatcher;
use ekubo::interfaces::token_registry::ITokenRegistryDispatcher;
use ekubo::types::i129::i129;
use ekubo::types::keys::PoolKey;
use ekubo_oracle_extension::oracle::IOracleDispatcher;
use starknet::ContractAddress;

#[starknet::interface]
pub trait ITicketMaster<TContractState> {
    fn init_distribution_pool(ref self: TContractState, distribution_initial_tick: i129) -> u256;
    fn provide_initial_liquidity(
        ref self: TContractState,
        payment_token_amount: u128,
        dungeon_ticket_amount: u128,
        minimum_liquidity: u128,
    ) -> (u64, u128, u256, u256);
    fn start_token_distribution(ref self: TContractState) -> (u64, u128);
    fn claim_proceeds(ref self: TContractState) -> u128;
    fn claim_and_distribute_buybacks(ref self: TContractState, limit: u16) -> (u128, u128);
    fn distribute_proceeds(ref self: TContractState, start_time: u64, end_time: u64);
    fn enable_low_issuance_mode(ref self: TContractState) -> u128;
    fn disable_low_issuance_mode(ref self: TContractState);
    fn burn(ref self: TContractState, amount: u256);
    fn burn_from(ref self: TContractState, from: ContractAddress, amount: u256);
    fn set_buyback_order_config(ref self: TContractState, config: BuybackOrderConfig);
    fn set_issuance_reduction_price_x128(ref self: TContractState, price: u256);
    fn set_issuance_reduction_price_duration(ref self: TContractState, duration: u64);
    fn set_issuance_reduction_bips(ref self: TContractState, bips: u128);
    fn set_treasury_address(ref self: TContractState, treasury_address: ContractAddress);
    fn set_velords_address(ref self: TContractState, velords_address: ContractAddress);
    fn withdraw_erc20(ref self: TContractState, token_address: ContractAddress, amount: u256);
    fn withdraw_erc721(ref self: TContractState, token_address: ContractAddress, token_id: u256);
    fn get_token_distribution_rate(self: @TContractState) -> u128;
    fn get_buyback_rate(self: @TContractState) -> u128;
    fn get_buyback_order_key_counter(self: @TContractState) -> u128;
    fn get_buyback_order_key_bookmark(self: @TContractState) -> u128;
    fn get_buyback_order_key_end_time(self: @TContractState, index: u128) -> u64;
    fn get_distribution_end_time(self: @TContractState) -> u64;
    fn get_distribution_initial_tick(self: @TContractState) -> i129;
    fn get_distribution_order_key(self: @TContractState) -> OrderKey;
    fn get_distribution_pool_key(self: @TContractState) -> PoolKey;
    fn get_distribution_pool_fee(self: @TContractState) -> u128;
    fn is_low_issuance_mode(self: @TContractState) -> bool;
    fn get_issuance_reduction_price_x128(self: @TContractState) -> u256;
    fn get_issuance_reduction_price_duration(self: @TContractState) -> u64;
    fn get_core_dispatcher(self: @TContractState) -> ICoreDispatcher;
    fn get_positions_dispatcher(self: @TContractState) -> IPositionsDispatcher;
    fn get_buyback_order_config(self: @TContractState) -> BuybackOrderConfig;
    fn get_pool_id(self: @TContractState) -> u256;
    fn get_position_token_id(self: @TContractState) -> u64;
    fn get_payment_token(self: @TContractState) -> ContractAddress;
    fn get_extension_address(self: @TContractState) -> ContractAddress;
    fn get_buyback_token(self: @TContractState) -> ContractAddress;
    fn get_registry_dispatcher(self: @TContractState) -> ITokenRegistryDispatcher;
    fn get_oracle_address(self: @TContractState) -> IOracleDispatcher;
    fn get_tokens_for_distribution(self: @TContractState) -> u256;
    fn get_treasury_address(self: @TContractState) -> ContractAddress;
    fn get_velords_address(self: @TContractState) -> ContractAddress;
    fn get_distribution_pool_key_hash(self: @TContractState) -> felt252;
    fn is_pool_initialized(self: @TContractState) -> bool;
    fn get_deployment_state(self: @TContractState) -> u8;
    fn get_dungeon_ticket_price_x128(self: @TContractState, duration: u64) -> u256;
    fn get_position_nft_address(self: @TContractState) -> ContractAddress;
    fn get_issuance_reduction_bips(self: @TContractState) -> u128;
    fn get_buyback_pool_key(self: @TContractState) -> PoolKey;
    fn get_buyback_pool_key_hash(self: @TContractState) -> felt252;
    fn get_unclaimed_buyback_orders_count(self: @TContractState) -> u128;
    fn is_token0(self: @TContractState) -> bool;
    fn get_buyback_order_key(self: @TContractState, start_time: u64, end_time: u64) -> OrderKey;
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub struct BuybackOrderConfig {
    // The minimum amount of time that can be between the start time and the current time. A value
    // of 0 means the orders _can_ start immediately
    pub min_delay: u64,
    // The maximum amount of time that can be between the start time and the current time. A value
    // of 0 means that the orders _must_ start immediately
    pub max_delay: u64,
    // The minimum duration of the buyback
    pub min_duration: u64,
    // The maximum duration of the buyback
    pub max_duration: u64,
    // The fee for the buyback orders
    pub fee: u128,
}
