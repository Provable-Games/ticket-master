use openzeppelin_token::erc20::interface::IERC20Dispatcher;
use snforge_std::{
    ContractClass, ContractClassTrait, DeclareResult, start_cheat_caller_address, start_mock_call,
};
use starknet::ContractAddress;
use ticket_master::interfaces::{BuybackOrderConfig, ITicketMasterDispatcher};
use super::constants::{
    BUYBACK_ORDER_CONFIG, DEPLOYER_ADDRESS, DISTRIBUTION_END_TIME, DISTRIBUTION_POOL_FEE_BPS,
    DUNGEON_TICKET_SUPPLY, MOCK_CORE_ADDRESS, PAYMENT_TOKEN_INITIAL_SUPPLY,
    REWARD_TOKEN_INITIAL_SUPPLY,
};

pub fn setup(
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
) -> (ITicketMasterDispatcher, IERC20Dispatcher, IERC20Dispatcher) {
    // deploy two tokens
    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    // deploy ticket master
    let ticket_master_class = declare_class("TicketMaster");
    let ticket_master_address = deploy(
        ticket_master_class,
        ticket_master_calldata(
            payment_token_address,
            reward_token_address,
            core_address,
            positions_address,
            position_nft_address,
            extension_address,
            registry_address,
            oracle_address,
            velords_address,
            issuance_reduction_price_x128,
            issuance_reduction_price_duration,
            issuance_reduction_bips,
            treasury_address,
        ),
    );

    // return ticket master and token dispatchers
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let payment_token_dispatcher = IERC20Dispatcher { contract_address: payment_token_address };
    let reward_token_dispatcher = IERC20Dispatcher { contract_address: reward_token_address };

    // default to use deployer address as caller
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS);

    (ticket_master_dispatcher, payment_token_dispatcher, reward_token_dispatcher)
}

pub fn declare_class(contract_name: ByteArray) -> ContractClass {
    match snforge_std::declare(contract_name) {
        Result::Ok(declare_result) => match declare_result {
            DeclareResult::Success(contract_class) => contract_class,
            DeclareResult::AlreadyDeclared(contract_class) => contract_class,
        },
        Result::Err(panic_data) => panic!("{}", panic_data_to_byte_array(panic_data)),
    }
}

pub fn deploy(contract_class: ContractClass, calldata: Array<felt252>) -> ContractAddress {
    match contract_class.deploy(@calldata) {
        Result::Ok((contract_address, _)) => contract_address,
        Result::Err(panic_data) => panic!("{}", panic_data_to_byte_array(panic_data)),
    }
}

pub fn panic_data_to_byte_array(panic_data: Array<felt252>) -> ByteArray {
    let mut panic_data = panic_data.span();

    // Remove BYTE_ARRAY_MAGIC from the panic data.
    panic_data.pop_front().expect('Empty panic data provided');

    match Serde::<ByteArray>::deserialize(ref panic_data) {
        Option::Some(string) => string,
        Option::None => { #[allow(panic)]
        panic!("Failed to deserialize panic data.") },
    }
}

pub fn token_calldata(
    name: ByteArray, symbol: ByteArray, initial_supply: u256, recipient: ContractAddress,
) -> Array<felt252> {
    let mut calldata = array![];

    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    initial_supply.serialize(ref calldata);
    recipient.serialize(ref calldata);

    calldata
}

pub fn ticket_master_calldata_custom(
    owner: ContractAddress,
    name: ByteArray,
    symbol: ByteArray,
    total_supply: u128,
    distribution_pool_fee: u128,
    payment_token: ContractAddress,
    reward_token: ContractAddress,
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
    distribution_end_time: u64,
    buyback_order_config: BuybackOrderConfig,
) -> Array<felt252> {
    let mut calldata = array![];

    owner.serialize(ref calldata);
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    total_supply.serialize(ref calldata);
    distribution_pool_fee.serialize(ref calldata);
    payment_token.serialize(ref calldata);
    reward_token.serialize(ref calldata);
    core_address.serialize(ref calldata);
    positions_address.serialize(ref calldata);
    position_nft_address.serialize(ref calldata);
    extension_address.serialize(ref calldata);
    registry_address.serialize(ref calldata);
    oracle_address.serialize(ref calldata);
    velords_address.serialize(ref calldata);
    issuance_reduction_price_x128.serialize(ref calldata);
    issuance_reduction_price_duration.serialize(ref calldata);
    issuance_reduction_bips.serialize(ref calldata);
    treasury_address.serialize(ref calldata);
    distribution_end_time.serialize(ref calldata);
    buyback_order_config.serialize(ref calldata);

    calldata
}

pub fn ticket_master_calldata(
    payment_token: ContractAddress,
    reward_token: ContractAddress,
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
) -> Array<felt252> {
    let owner: ContractAddress = DEPLOYER_ADDRESS;
    let name: ByteArray = "Beasts Dungeon Ticket";
    let symbol: ByteArray = "BDT";
    let total_supply: u128 = DUNGEON_TICKET_SUPPLY;
    let distribution_pool_fee: u128 = DISTRIBUTION_POOL_FEE_BPS;
    let distribution_end_time: u64 = DISTRIBUTION_END_TIME;
    let buyback_order_config = BUYBACK_ORDER_CONFIG;

    ticket_master_calldata_custom(
        owner,
        name,
        symbol,
        total_supply,
        distribution_pool_fee,
        payment_token,
        reward_token,
        core_address,
        positions_address,
        position_nft_address,
        extension_address,
        registry_address,
        oracle_address,
        velords_address,
        issuance_reduction_price_x128,
        issuance_reduction_price_duration,
        issuance_reduction_bips,
        treasury_address,
        distribution_end_time,
        buyback_order_config,
    )
}

pub fn mock_ekubo_core(pool_id: u256) {
    // Mock Ekubo core's initialize_pool to return the provided pool id
    start_mock_call(MOCK_CORE_ADDRESS, selector!("initialize_pool"), pool_id);
}
