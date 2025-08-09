use core::integer::u256;
use core::result::ResultTrait;
use core::traits::{Into, TryInto};
use openzeppelin_access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    CheatSpan, ContractClassTrait, cheat_caller_address, load, map_entry_address, mock_call,
    start_cheat_block_timestamp_global, start_cheat_caller_address, start_mock_call,
    stop_cheat_caller_address, store,
};
use starknet::ContractAddress;
use starknet::syscalls::call_contract_syscall;
use ticket_master::constants::{BIPS_BASIS, ERC20_UNIT};
use ticket_master::interfaces::{
    BuybackOrderConfig, ITicketMasterDispatcher, ITicketMasterDispatcherTrait,
};
use ticket_master::utils::get_max_twamm_duration;
use super::constants::{
    BUYBACK_ORDER_CONFIG, DEPLOYER_ADDRESS, DISTRIBUTION_END_TIME, DISTRIBUTION_INITIAL_TICK,
    DISTRIBUTION_POOL_FEE_BPS, DUNGEON_TICKET_SUPPLY, EKUBO_ORACLE_MAINNET,
    INITIAL_LIQUIDITY_DUNGEON_TICKETS, INITIAL_LIQUIDITY_MIN_LIQUIDITY,
    INITIAL_LIQUIDITY_PAYMENT_TOKEN, ISSUANCE_REDUCTION_BIPS, ISSUANCE_REDUCTION_PRICE_DURATION,
    ISSUANCE_REDUCTION_PRICE_X128, MAINNET_CORE_ADDRESS, MAINNET_POSITIONS_ADDRESS,
    MAINNET_POSITION_NFT_ADDRESS, MAINNET_REGISTRY_ADDRESS, MAINNET_TREASURY,
    MAINNET_TWAMM_EXTENSION_ADDRESS, MOCK_CORE_ADDRESS, MOCK_POSITIONS_ADDRESS,
    MOCK_POSITION_NFT_ADDRESS, MOCK_REGISTRY_ADDRESS, MOCK_TREASURY, MOCK_TWAMM_EXTENSION_ADDRESS,
    MOCK_VELORDS_ADDRESS, PAYMENT_TOKEN_INITIAL_SUPPLY, REWARD_TOKEN_INITIAL_SUPPLY, ZERO_ADDRESS,
};
use super::helper::{
    declare_class, deploy, mock_ekubo_core, panic_data_to_byte_array, setup,
    ticket_master_calldata_custom, token_calldata,
};

#[test]
fn constructor_sets_initial_state() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");

    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let alice: ContractAddress = 'alice'.try_into().unwrap();
    let bob: ContractAddress = 'bob'.try_into().unwrap();

    let amount_alice: u128 = 1_000_000_000_000_000_000;
    let amount_bob: u128 = 2_000_000_000_000_000_000;

    let recipients = array![alice, bob];
    let amounts = array![amount_alice.into(), amount_bob.into()];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    assert!(
        ticket_master_dispatcher.get_payment_token() == payment_token_address,
        "payment token mismatch",
    );
    assert!(
        ticket_master_dispatcher.get_buyback_token() == reward_token_address,
        "buyback token mismatch",
    );
    assert!(ticket_master_dispatcher.get_treasury_address() == MOCK_TREASURY, "treasury mismatch");
    assert!(
        ticket_master_dispatcher.get_velords_address() == MOCK_VELORDS_ADDRESS,
        "veLords address mismatch",
    );
    assert!(
        ticket_master_dispatcher.get_core_dispatcher().contract_address == MOCK_CORE_ADDRESS,
        "core dispatcher mismatch",
    );
    assert!(
        ticket_master_dispatcher
            .get_positions_dispatcher()
            .contract_address == MOCK_POSITIONS_ADDRESS,
        "positions dispatcher mismatch",
    );
    assert!(
        ticket_master_dispatcher
            .get_registry_dispatcher()
            .contract_address == MOCK_REGISTRY_ADDRESS,
        "registry dispatcher mismatch",
    );
    assert!(
        ticket_master_dispatcher.get_oracle_address().contract_address == EKUBO_ORACLE_MAINNET,
        "oracle mismatch",
    );
    assert!(
        ticket_master_dispatcher.get_extension_address() == MOCK_TWAMM_EXTENSION_ADDRESS,
        "extension mismatch",
    );
    assert!(
        ticket_master_dispatcher
            .get_issuance_reduction_price_x128() == ISSUANCE_REDUCTION_PRICE_X128,
        "reduction price mismatch",
    );
    assert!(
        !ticket_master_dispatcher.is_low_issuance_mode(), "low issuance mode should start inactive",
    );

    assert!(
        ticket_master_dispatcher.get_distribution_pool_fee() == DISTRIBUTION_POOL_FEE_BPS,
        "pool fee mismatch",
    );

    assert!(ticket_master_dispatcher.get_deployment_state() == 0, "deployment state should be 0");
    assert!(!ticket_master_dispatcher.is_pool_initialized(), "pool should start uninitialized");
    assert!(ticket_master_dispatcher.get_pool_id() == 0, "pool id should be 0");
    assert!(ticket_master_dispatcher.get_position_token_id() == 0, "position token id should be 0");
    assert!(
        ticket_master_dispatcher.get_token_distribution_rate() == 0,
        "distribution rate should start at 0",
    );
    assert!(ticket_master_dispatcher.get_buyback_rate() == 0, "buyback rate should start at 0");

    let registry_token_amount: u256 = 1000000000000000000_u128.into();
    let distributed_to_recipients: u256 = amount_alice.into() + amount_bob.into();
    let expected_minted_supply = distributed_to_recipients + registry_token_amount;
    assert!(
        ticket_token_dispatcher.total_supply() == expected_minted_supply,
        "unexpected total supply after constructor",
    );
    assert!(
        ticket_token_dispatcher.balance_of(alice) == amount_alice.into(),
        "alice should receive requested amount",
    );
    assert!(
        ticket_token_dispatcher.balance_of(bob) == amount_bob.into(),
        "bob should receive requested amount",
    );
    assert!(
        ticket_token_dispatcher.balance_of(MOCK_REGISTRY_ADDRESS) == registry_token_amount,
        "registry should receive single token",
    );

    let total_supply_u256: u256 = DUNGEON_TICKET_SUPPLY.into();
    let expected_tokens_for_distribution = total_supply_u256 - expected_minted_supply;
    assert!(
        ticket_master_dispatcher.get_tokens_for_distribution() == expected_tokens_for_distribution,
        "tokens_for_distribution mismatch",
    );
}

#[test]
#[fuzzer]
fn test_distribute_initial_tokens_multiple_recipients(delta_a: u64, delta_b: u64, delta_c: u64) {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");

    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let alice: ContractAddress = 'alice_multi'.try_into().unwrap();
    let bob: ContractAddress = 'bob_multi'.try_into().unwrap();
    let carol: ContractAddress = 'carol_multi'.try_into().unwrap();

    let registry_token_amount: u128 = 1_000_000_000_000_000_000;
    let base_alice: u128 = 1_000_000_000_000_000_000;
    let base_bob: u128 = 2_000_000_000_000_000_000;
    let base_carol: u128 = 3_000_000_000_000_000_000;

    let perturbation_bound: u128 = 1_000;
    let amount_alice: u128 = base_alice + ((delta_a.into()) % perturbation_bound);
    let amount_bob: u128 = base_bob + ((delta_b.into()) % perturbation_bound);
    let amount_carol: u128 = base_carol + ((delta_c.into()) % perturbation_bound);

    let recipients = array![alice, bob, carol];
    let amounts = array![amount_alice.into(), amount_bob.into(), amount_carol.into()];

    let total_recipient_mints: u128 = amount_alice + amount_bob + amount_carol;
    if total_recipient_mints + registry_token_amount >= DUNGEON_TICKET_SUPPLY {
        return;
    }

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = match ticket_master_class.deploy(@calldata) {
        Result::Ok((address, _)) => address,
        Result::Err(_) => { return; },
    };
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    assert_eq!(ticket_token_dispatcher.balance_of(alice), amount_alice.into());
    assert_eq!(ticket_token_dispatcher.balance_of(bob), amount_bob.into());
    assert_eq!(ticket_token_dispatcher.balance_of(carol), amount_carol.into());

    let distributed_total: u256 = amount_alice.into()
        + amount_bob.into()
        + amount_carol.into()
        + registry_token_amount.into();
    let expected_remaining = DUNGEON_TICKET_SUPPLY.into() - distributed_total;

    assert_eq!(ticket_master_dispatcher.get_tokens_for_distribution(), expected_remaining);
}

#[test]
fn burn_reduces_balance_and_total_supply() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let burner: ContractAddress = 'burner'.try_into().unwrap();
    let minted_amount: u128 = 10_u128 * ERC20_UNIT;
    let burn_amount: u128 = 4_u128 * ERC20_UNIT;

    let recipients = array![burner];
    let amounts = array![minted_amount.into()];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    let initial_balance = ticket_token_dispatcher.balance_of(burner);
    assert_eq!(initial_balance, minted_amount.into());

    let initial_supply = ticket_token_dispatcher.total_supply();
    let burn_amount_u256: u256 = burn_amount.into();

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, burner);
    ticket_master_dispatcher.burn(burn_amount_u256);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);

    let post_burn_balance = ticket_token_dispatcher.balance_of(burner);
    assert_eq!(post_burn_balance + burn_amount_u256, initial_balance);

    let post_burn_supply = ticket_token_dispatcher.total_supply();
    assert_eq!(post_burn_supply + burn_amount_u256, initial_supply);
}

#[test]
fn burn_from_reduces_balance_and_total_supply() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let burner: ContractAddress = 'burner'.try_into().unwrap();
    let spender: ContractAddress = 'spender'.try_into().unwrap();
    let minted_amount: u128 = 10_u128 * ERC20_UNIT;
    let burn_amount: u128 = 4_u128 * ERC20_UNIT;

    let recipients = array![burner];
    let amounts = array![minted_amount.into()];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    let initial_balance = ticket_token_dispatcher.balance_of(burner);
    assert_eq!(initial_balance, minted_amount.into());

    let initial_supply = ticket_token_dispatcher.total_supply();
    let burn_amount_u256: u256 = burn_amount.into();

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, burner);
    ticket_token_dispatcher.approve(spender, burn_amount_u256);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, spender);
    ticket_master_dispatcher.burn_from(burner, burn_amount_u256);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);

    let post_burn_balance = ticket_token_dispatcher.balance_of(burner);
    assert_eq!(post_burn_balance + burn_amount_u256, initial_balance);

    let post_burn_supply = ticket_token_dispatcher.total_supply();
    assert_eq!(post_burn_supply + burn_amount_u256, initial_supply);

    let remaining_allowance = ticket_token_dispatcher.allowance(burner, spender);
    assert_eq!(remaining_allowance, 0_u128.into());
}

#[test]
#[should_panic(expected: ('ERC20: insufficient allowance',))]
fn burn_from_rejects_without_allowance() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let burner: ContractAddress = 'burner'.try_into().unwrap();
    let spender: ContractAddress = 'spender'.try_into().unwrap();
    let minted_amount: u128 = 10_u128 * ERC20_UNIT;
    let burn_amount: u128 = 4_u128 * ERC20_UNIT;

    let recipients = array![burner];
    let amounts = array![minted_amount.into()];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    assert_eq!(ticket_token_dispatcher.balance_of(burner), minted_amount.into());
    assert_eq!(ticket_token_dispatcher.allowance(burner, spender), 0_u128.into());

    let burn_amount_u256: u256 = burn_amount.into();

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, spender);
    ticket_master_dispatcher.burn_from(burner, burn_amount_u256);
}

#[test]
#[fuzzer]
fn fuzz_constructor_valid_configs(
    recipient_seed: u64, start_offset: u64, duration_seed: u64, amount_seed_low: u64,
) {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let recipient_count = (recipient_seed % 4) + 1;
    let max_distributable: u128 = DUNGEON_TICKET_SUPPLY - 1_000_000_000_000_000_000;
    let mut recipients: Array<ContractAddress> = array![];
    let mut amounts: Array<u256> = array![];
    let mut remaining: u128 = max_distributable;
    let mut distributed: u128 = 0;
    let amount_seed: u128 = amount_seed_low.into();

    let offset = recipient_seed % 4;

    let mut index: u64 = 0;
    loop {
        if index == recipient_count {
            break;
        }

        let candidate_index = (offset + index) % 4;
        let recipient = match candidate_index {
            0 => 'seed0'.try_into().unwrap(),
            1 => 'seed1'.try_into().unwrap(),
            2 => 'seed2'.try_into().unwrap(),
            _ => 'seed3'.try_into().unwrap(),
        };
        recipients.append(recipient);

        let recipients_left = recipient_count - index;
        let recipients_left_u128: u128 = recipients_left.into();
        let max_for_this = if recipients_left_u128 == 0 {
            0
        } else {
            remaining / recipients_left_u128 + 1
        };
        let index_u128: u128 = index.into();
        let raw = amount_seed + index_u128 * 7919_u128;
        let chosen = if max_for_this == 0 {
            0
        } else {
            raw % max_for_this
        };
        amounts.append(chosen.into());
        distributed += chosen;
        if chosen > remaining {
            remaining = 0;
        } else {
            remaining -= chosen;
        }

        index += 1;
    }

    let base_time = 1_000_u64;
    start_cheat_block_timestamp_global(base_time);

    let max_duration = get_max_twamm_duration();
    let start_time = base_time + (start_offset % 10_000_u64);
    let min_duration: u64 = 10;
    let duration = (duration_seed % (max_duration - min_duration)) + min_duration;
    let end_time = start_time + duration;

    let ticket_master_class = declare_class("TicketMaster");
    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        end_time,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = match ticket_master_class.deploy(@calldata) {
        Result::Ok((address, _)) => address,
        Result::Err(_) => {
            start_cheat_block_timestamp_global(0_u64);
            return;
        },
    };

    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 0_u8);

    let registry_token_amount: u128 = 1_000_000_000_000_000_000;
    let expected_total_minted: u128 = distributed + registry_token_amount;
    let expected_tokens_for_distribution: u128 = DUNGEON_TICKET_SUPPLY - expected_total_minted;

    if expected_tokens_for_distribution == 0 {
        start_cheat_block_timestamp_global(0_u64);
        return;
    }

    let total_supply: u256 = token_dispatcher.total_supply();
    assert_eq!(total_supply, expected_total_minted.into());

    let recorded_tokens_for_distribution = ticket_master_dispatcher.get_tokens_for_distribution();
    assert_eq!(recorded_tokens_for_distribution, expected_tokens_for_distribution.into());

    start_cheat_block_timestamp_global(0_u64);
}

#[test]
fn constructor_rejects_zero_payment_token() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        ZERO_ADDRESS,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid payment token');
}

#[test]
fn constructor_rejects_zero_reward_token() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        ZERO_ADDRESS,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid reward token');
}

#[test]
fn constructor_rejects_zero_core_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        ZERO_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid core address');
}

#[test]
fn constructor_rejects_zero_positions_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        ZERO_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid positions address');
}

#[test]
fn constructor_rejects_zero_position_nft_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        ZERO_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid positions NFT address');
}

#[test]
fn constructor_rejects_zero_extension_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        ZERO_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid extension address');
}

#[test]
fn constructor_rejects_zero_registry_address() {
    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        ZERO_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid registry address');
}

#[test]
fn constructor_rejects_zero_oracle_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        ZERO_ADDRESS,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid oracle address');
}

#[test]
fn constructor_rejects_zero_velords_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        ZERO_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid veLords address');
}

#[test]
fn constructor_rejects_zero_treasury_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        ZERO_ADDRESS,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid treasury address');
}

#[test]
fn constructor_rejects_mismatched_lengths() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let recipient: ContractAddress = 'alice'.try_into().unwrap();
    let recipients = array![recipient];
    let empty_amounts: Array<u256> = array![];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        empty_amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Arrays length mismatch');
}

#[test]
fn constructor_rejects_end_before_now() {
    start_cheat_block_timestamp_global(1_000_u64);
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let invalid_end_time: u64 = 900; // less than current block timestamp
    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        invalid_end_time,
        BUYBACK_ORDER_CONFIG,
    );

    match ticket_master_class.deploy(@calldata) {
        Result::Ok(_) => panic!("constructor should reject end time before now"),
        Result::Err(panic_data) => {
            let message = panic_data_to_byte_array(panic_data);
            assert!(
                message == "End time must be greater than now",
                "unexpected panic message: {}",
                message,
            );
        },
    }

    start_cheat_block_timestamp_global(0_u64);
}

#[test]
fn constructor_rejects_end_past_max_duration() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let max_duration = get_max_twamm_duration();
    let invalid_end_time = starknet::get_block_timestamp() + max_duration + 1_u64;

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        invalid_end_time,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'End time exceeds max limit');
}

#[test]
fn constructor_rejects_zero_recipient() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let recipients = array![ZERO_ADDRESS];
    let amounts = array![1_000_u128.into()];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid recipient address');
}

#[test]
fn constructor_rejects_distribution_exceeding_supply() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let recipient: ContractAddress = 'alice'.try_into().unwrap();
    let recipients = array![recipient];
    let excessive_amount: u256 = DUNGEON_TICKET_SUPPLY.into() + 1_u128.into();
    let amounts = array![excessive_amount];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Distribution exceeds supply');
}

#[test]
fn constructor_rejects_zero_total_supply() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        0, // zero total supply
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid total supply');
}

#[test]
fn constructor_rejects_reduction_bips_at_limit() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        BIPS_BASIS, // issuance_reduction_bips at limit (should reject)
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert_constructor_revert_with_message(deploy_result, 'Invalid reduction bips');
}

#[test]
fn constructor_accepts_reduction_bips_boundary() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        BIPS_BASIS - 1, // issuance_reduction_bips at boundary (should accept)
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata);
    assert!(deploy_result.is_ok(), "constructor should accept bips at BIPS_BASIS - 1");

    let (ticket_master_address, _) = deploy_result.unwrap();
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };

    assert!(
        ticket_master_dispatcher.get_issuance_reduction_bips() == BIPS_BASIS - 1,
        "bips should be set correctly",
    );
}

#[test]
#[should_panic(expected: "init liq too large")]
fn provide_initial_liquidity_rejects_insufficient_remaining_supply() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN, DUNGEON_TICKET_SUPPLY, INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic(expected: "init liq too large")]
fn provide_initial_liquidity_rejects_when_tokens_insufficient() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    let tokens_for_distribution = ticket_master_dispatcher.get_tokens_for_distribution();
    let tokens_for_distribution_u128: u128 = tokens_for_distribution.try_into().unwrap();
    let requested_dungeon_liquidity = tokens_for_distribution_u128 + 1_u128;

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            requested_dungeon_liquidity,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic(expected: ('init pay amt zero',))]
fn provide_initial_liquidity_rejects_zero_payment_amount() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher
        .provide_initial_liquidity(
            0, INITIAL_LIQUIDITY_DUNGEON_TICKETS, INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic(expected: ('init our amt zero',))]
fn provide_initial_liquidity_rejects_zero_dungeon_amount() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN, 0, INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
fn init_distribution_pool_sets_state() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let distribution_pool_id = ticket_master_dispatcher
        .init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    assert!(ticket_master_dispatcher.is_pool_initialized(), "pool should be marked initialized");
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 1_u8);
    assert_eq!(distribution_pool_id, 1_u256);
    assert_eq!(ticket_master_dispatcher.get_pool_id(), distribution_pool_id);
}

#[test]
#[should_panic(expected: ('Pool already initialized',))]
fn init_distribution_pool_wrong_state() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
}

#[test]
#[should_panic]
fn init_distribution_pool_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let intruder: ContractAddress = 'intruder_init'.try_into().unwrap();
    cheat_caller_address(
        ticket_master_dispatcher.contract_address, intruder, CheatSpan::TargetCalls(1),
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
}

#[test]
fn provide_initial_liquidity_happy_path() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    let liquidity_return = (42_u64, 500_u128, 0_u256, 0_u256);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_deposit_and_clear_both"), liquidity_return, 1,
    );

    let (position_id, liquidity, cleared_payment, cleared_our) = ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let (expected_position_id, expected_liquidity, expected_cleared_payment, expected_cleared_our) =
        liquidity_return;

    assert_eq!(position_id, expected_position_id);
    assert_eq!(liquidity, expected_liquidity);
    assert_eq!(cleared_payment, expected_cleared_payment);
    assert_eq!(cleared_our, expected_cleared_our);
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 2_u8);

    let ticket_token_dispatcher = IERC20Dispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };
    assert_eq!(
        ticket_token_dispatcher.balance_of(MOCK_POSITIONS_ADDRESS),
        INITIAL_LIQUIDITY_DUNGEON_TICKETS.into(),
    );
}

#[test]
#[should_panic(expected: ('Wrong state for liquidity',))]
fn provide_initial_liquidity_wrong_state() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic]
fn provide_initial_liquidity_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    let intruder: ContractAddress = 'intruder_liq'.try_into().unwrap();
    cheat_caller_address(
        ticket_master_dispatcher.contract_address, intruder, CheatSpan::TargetCalls(1),
    );

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic(expected: ('dist pool not initialized',))]
fn provide_initial_liquidity_without_pool_id() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(0_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[fuzzer]
fn test_provide_initial_liquidity_consumes_stored_config(
    payment_seed: u64, our_seed: u64, min_seed: u64,
) {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let registry_token_amount: u128 = 1_000_000_000_000_000_000;
    let max_our_liquidity = DUNGEON_TICKET_SUPPLY - registry_token_amount - 1;
    if max_our_liquidity == 0 {
        return;
    }

    let custom_payment_liquidity: u128 = 111 + ((payment_seed.into()) % 1_000);
    let custom_our_liquidity: u128 = 222 + ((our_seed.into()) % 1_000);
    if custom_our_liquidity == 0 || custom_our_liquidity > max_our_liquidity {
        return;
    }
    let custom_min_liquidity: u128 = ((min_seed.into()) % custom_our_liquidity) + 1;
    if custom_min_liquidity > custom_our_liquidity {
        return;
    }

    let ticket_master_class = declare_class("TicketMaster");
    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Configurable Ticket",
        "CTK",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let payment_token_dispatcher = IERC20Dispatcher { contract_address: payment_token_address };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS);
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    let liquidity_return = (13_u64, 37_u128, 0_u256, 0_u256);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_deposit_and_clear_both"), liquidity_return, 1,
    );

    let balance_before = ticket_token_dispatcher.balance_of(MOCK_POSITIONS_ADDRESS);
    let (position_id, liquidity, cleared_payment, cleared_our) = ticket_master_dispatcher
        .provide_initial_liquidity(
            custom_payment_liquidity, custom_our_liquidity, custom_min_liquidity,
        );

    let (expected_position_id, expected_liquidity, expected_cleared_payment, expected_cleared_our) =
        liquidity_return;
    assert_eq!(position_id, expected_position_id);
    assert_eq!(liquidity, expected_liquidity);
    assert_eq!(cleared_payment, expected_cleared_payment);
    assert_eq!(cleared_our, expected_cleared_our);

    let balance_after = ticket_token_dispatcher.balance_of(MOCK_POSITIONS_ADDRESS);
    assert_eq!(balance_after, balance_before + custom_our_liquidity.into());
}

#[test]
fn test_provide_initial_liquidity_updates_tokens_for_distribution() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let custom_payment_liquidity: u128 = 321;
    let custom_our_liquidity: u128 = 654;
    let custom_min_liquidity: u128 = 7;

    let ticket_master_class = declare_class("TicketMaster");
    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Configurable Ticket",
        "CTK",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![],
        array![],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let payment_token_dispatcher = IERC20Dispatcher { contract_address: payment_token_address };
    let ticket_token_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS);
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    let liquidity_return = (11_u64, 22_u128, 0_u256, 0_u256);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_deposit_and_clear_both"), liquidity_return, 1,
    );

    let tokens_for_distribution_before = ticket_master_dispatcher.get_tokens_for_distribution();
    if tokens_for_distribution_before.high != 0 {
        return;
    }
    let tokens_for_distribution_before_low: u128 = tokens_for_distribution_before.low;
    if custom_our_liquidity > tokens_for_distribution_before_low {
        return;
    }

    let custom_our_liquidity_u256: u256 = custom_our_liquidity.into();
    let expected_remaining = tokens_for_distribution_before - custom_our_liquidity_u256;

    let _ = ticket_master_dispatcher
        .provide_initial_liquidity(
            custom_payment_liquidity, custom_our_liquidity, custom_min_liquidity,
        );

    assert_eq!(
        ticket_token_dispatcher.balance_of(MOCK_POSITIONS_ADDRESS), custom_our_liquidity.into(),
    );

    let remaining_distribution = ticket_master_dispatcher.get_tokens_for_distribution();
    assert_eq!(remaining_distribution, expected_remaining);
}

#[test]
#[should_panic(expected: ('Must provide liquidity first',))]
fn start_token_distribution_wrong_state() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.start_token_distribution();
}

#[test]
#[should_panic(expected: ('dist pool not initialized',))]
fn start_token_distribution_without_pool() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(contract_address, selector!("deployment_state"), array![2.into()].span());
    store(contract_address, selector!("pool_id"), array![0.into(), 0.into()].span());

    let stored_pool = load(contract_address, selector!("pool_id"), 2);
    assert!(stored_pool == array![0.into(), 0.into()]);

    ticket_master_dispatcher.start_token_distribution();
}

#[test]
fn start_token_distribution_happy_path() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let sale_result = (77_u64, 888_u128);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), sale_result, 1);

    let (position_token_id, sale_rate) = ticket_master_dispatcher.start_token_distribution();

    let (expected_position_token_id, expected_sale_rate) = sale_result;
    assert_eq!(position_token_id, expected_position_token_id);
    assert_eq!(sale_rate, expected_sale_rate);
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 3_u8);
    assert_eq!(ticket_master_dispatcher.get_position_token_id(), expected_position_token_id);
    assert_eq!(ticket_master_dispatcher.get_token_distribution_rate(), expected_sale_rate);
}

// ================================
// State Machine Edge Case Tests
// ================================

#[test]
fn get_deployment_state_transitions_correctly() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // State 0: initial
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 0_u8, "Should start in state 0");
    assert_eq!(
        ticket_master_dispatcher.is_pool_initialized(), false, "Pool should not be initialized",
    );

    // Transition to state 1
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    assert_eq!(
        ticket_master_dispatcher.get_deployment_state(),
        1_u8,
        "Should be in state 1 after init_distribution_pool",
    );
    assert_eq!(ticket_master_dispatcher.is_pool_initialized(), true, "Pool should be initialized");

    // Transition to state 2
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    assert_eq!(
        ticket_master_dispatcher.get_deployment_state(),
        2_u8,
        "Should be in state 2 after provide_initial_liquidity",
    );

    // Transition to state 3
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();
    assert_eq!(
        ticket_master_dispatcher.get_deployment_state(),
        3_u8,
        "Should be in state 3 after start_token_distribution",
    );
}

#[test]
#[should_panic(expected: 'Pool already initialized')]
fn init_distribution_pool_cannot_be_called_twice() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // First call succeeds
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    // Second call should panic
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
}

#[test]
#[should_panic(expected: 'Wrong state for liquidity')]
fn provide_initial_liquidity_requires_state_1() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to provide liquidity in state 0 (should fail)
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic(expected: 'Wrong state for liquidity')]
fn provide_initial_liquidity_cannot_be_called_twice() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    // First call succeeds
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    // Second call should panic (state is now 2)
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
}

#[test]
#[should_panic(expected: 'Must provide liquidity first')]
fn start_token_distribution_requires_state_2() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Only init pool (state 1), don't provide liquidity
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    // Try to start distribution without providing liquidity (should fail)
    ticket_master_dispatcher.start_token_distribution();
}

#[test]
#[should_panic(expected: 'Must provide liquidity first')]
fn start_token_distribution_cannot_be_called_twice() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    // First call succeeds
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Second call should panic (state is now 3)
    ticket_master_dispatcher.start_token_distribution();
}

#[test]
fn transfer_distribution_position_token_moves_nft() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let sale_result = (77_u64, 888_u128);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), sale_result, 1);

    ticket_master_dispatcher.start_token_distribution();

    let recipient: ContractAddress = 'position_guardian'.try_into().unwrap();
    mock_call(MOCK_POSITION_NFT_ADDRESS, selector!("transfer_from"), (), 1);

    ticket_master_dispatcher.withdraw_position_token(recipient);

    assert_eq!(ticket_master_dispatcher.get_position_token_id(), 0_u64);
}

#[test]
#[should_panic]
fn transfer_distribution_position_token_requires_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let sale_result = (77_u64, 888_u128);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), sale_result, 1);

    ticket_master_dispatcher.start_token_distribution();

    let intruder: ContractAddress = 'intruder'.try_into().unwrap();
    cheat_caller_address(
        ticket_master_dispatcher.contract_address, intruder, CheatSpan::TargetCalls(1),
    );

    ticket_master_dispatcher.withdraw_position_token(intruder);
}

#[test]
#[should_panic(expected: 'distribution not started')]
fn withdraw_position_token_rejects_when_position_token_id_zero() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // position_token_id is 0 because we haven't called start_token_distribution
    let recipient: ContractAddress = 'recipient'.try_into().unwrap();
    ticket_master_dispatcher.withdraw_position_token(recipient);
}

#[test]
#[should_panic(expected: 'invalid recipient')]
fn withdraw_position_token_rejects_zero_recipient() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let sale_result = (77_u64, 888_u128);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), sale_result, 1);

    ticket_master_dispatcher.start_token_distribution();

    ticket_master_dispatcher.withdraw_position_token(ZERO_ADDRESS);
}

#[test]
#[should_panic(expected: ('Distribution not started',))]
fn claim_proceeds_before_pool_initialized() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.claim_proceeds();
}

#[test]
#[should_panic(expected: ('Distribution not started',))]
fn claim_proceeds_before_distribution_started() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher.claim_proceeds();
}

#[test]
fn claim_proceeds_returns_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (90_u64, 555_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("withdraw_proceeds_from_sale_to_self"), 321_u128, 1,
    );

    let proceeds = ticket_master_dispatcher.claim_proceeds();
    assert_eq!(proceeds, 321_u128);
}

#[test]
fn low_issuance_mode_adjusts_distribution_rate() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let sale_result = (77_u64, 400_u128);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), sale_result, 1);
    ticket_master_dispatcher.start_token_distribution();

    let initial_rate = ticket_master_dispatcher.get_token_distribution_rate();
    let expected_delta = (initial_rate * ISSUANCE_REDUCTION_BIPS) / BIPS_BASIS;
    assert!(expected_delta > 0, "expected delta must be positive for test");

    let below_threshold = u256 {
        low: ISSUANCE_REDUCTION_PRICE_X128.low - 1, high: ISSUANCE_REDUCTION_PRICE_X128.high,
    };
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), below_threshold, 1);
    let returned_tokens: u128 = 5_000;
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), returned_tokens, 1);

    ticket_master_dispatcher.enable_low_issuance_mode();

    assert!(ticket_master_dispatcher.is_low_issuance_mode());
    assert_eq!(
        ticket_master_dispatcher.get_token_distribution_rate(), initial_rate - expected_delta,
    );

    // Seed the positions balance and transfer the tokens back to the contract so the subsequent
    // internal transfer succeeds.
    let returned_tokens_u256: u256 = returned_tokens.into();
    let positions_balance_entry = map_entry_address(
        selector!("erc20_balances"), array![MOCK_POSITIONS_ADDRESS.into()].span(),
    );
    store(
        ticket_master_dispatcher.contract_address,
        positions_balance_entry,
        array![returned_tokens_u256.low.into(), returned_tokens_u256.high.into()].span(),
    );

    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, MOCK_POSITIONS_ADDRESS);
    let dungeon_ticket_dispatcher = IERC20Dispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };
    dungeon_ticket_dispatcher
        .transfer(ticket_master_dispatcher.contract_address, returned_tokens_u256);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS);

    let contract_balance = dungeon_ticket_dispatcher
        .balance_of(ticket_master_dispatcher.contract_address);
    assert!(contract_balance == returned_tokens_u256, "contract balance should equal returned");

    let above_threshold = u256 {
        low: ISSUANCE_REDUCTION_PRICE_X128.low + 1, high: ISSUANCE_REDUCTION_PRICE_X128.high,
    };
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), above_threshold, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("withdraw_proceeds_from_sale_to_self"), 0_u128, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("increase_sell_amount"), expected_delta, 1);

    ticket_master_dispatcher.disable_low_issuance_mode();

    assert!(!ticket_master_dispatcher.is_low_issuance_mode());
    assert_eq!(ticket_master_dispatcher.get_token_distribution_rate(), initial_rate);
}

#[test]
#[should_panic(expected: 'Distribution not started')]
fn enable_low_issuance_mode_rejects_before_distribution_started() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through liquidity provision but don't start distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    // Try to enable low issuance mode before distribution starts (should fail)
    ticket_master_dispatcher.enable_low_issuance_mode();
}

#[test]
#[should_panic(expected: 'low issuance already active')]
fn enable_low_issuance_mode_rejects_when_already_active() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Enable low issuance mode once (mock price below threshold)
    let low_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 - 1;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), 100_u128, 1);
    ticket_master_dispatcher.enable_low_issuance_mode();

    // Try to enable again (should fail)
    ticket_master_dispatcher.enable_low_issuance_mode();
}

#[test]
#[should_panic(expected: 'price not below threshold')]
fn enable_low_issuance_mode_rejects_when_price_not_below_threshold() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Mock price at or above threshold
    let high_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 + 1;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), high_price, 1);

    // Try to enable (should fail)
    ticket_master_dispatcher.enable_low_issuance_mode();
}

#[test]
#[should_panic(expected: 'price not below threshold')]
fn enable_low_issuance_mode_rejects_when_price_equals_threshold() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Mock price exactly at threshold
    mock_call(
        EKUBO_ORACLE_MAINNET,
        selector!("get_price_x128_over_last"),
        ISSUANCE_REDUCTION_PRICE_X128,
        1,
    );

    // Try to enable (should fail)
    ticket_master_dispatcher.enable_low_issuance_mode();
}

#[test]
fn enable_low_issuance_mode_succeeds_when_price_below_threshold() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    let initial_rate = ticket_master_dispatcher.get_token_distribution_rate();

    // Mock price below threshold
    let low_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 - 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), 100_u128, 1);

    // Enable low issuance mode (should succeed)
    let returned_tokens = ticket_master_dispatcher.enable_low_issuance_mode();

    // Verify state changes
    assert!(ticket_master_dispatcher.is_low_issuance_mode());
    assert!(returned_tokens > 0);
    assert!(ticket_master_dispatcher.get_token_distribution_rate() < initial_rate);
}

#[test]
#[should_panic(expected: 'low issuance not active')]
fn disable_low_issuance_mode_rejects_when_not_active() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup but don't enable low issuance mode
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Try to disable when not active (should fail)
    ticket_master_dispatcher.disable_low_issuance_mode();
}

#[test]
#[should_panic(expected: 'price not above threshold')]
fn disable_low_issuance_mode_rejects_when_price_not_above_threshold() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup and enable low issuance mode
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Enable low issuance mode
    let low_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 - 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), 100_u128, 1);
    ticket_master_dispatcher.enable_low_issuance_mode();

    // Mock price still below threshold
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);

    // Try to disable (should fail)
    ticket_master_dispatcher.disable_low_issuance_mode();
}

#[test]
#[should_panic(expected: 'price not above threshold')]
fn disable_low_issuance_mode_rejects_when_price_equals_threshold() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup and enable low issuance mode
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Enable low issuance mode
    let low_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 - 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), 100_u128, 1);
    ticket_master_dispatcher.enable_low_issuance_mode();

    // Mock price exactly at threshold
    mock_call(
        EKUBO_ORACLE_MAINNET,
        selector!("get_price_x128_over_last"),
        ISSUANCE_REDUCTION_PRICE_X128,
        1,
    );

    // Try to disable (should fail)
    ticket_master_dispatcher.disable_low_issuance_mode();
}

#[test]
#[should_panic(expected: 'no tickets available')]
fn disable_low_issuance_mode_rejects_when_no_tickets_available() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup and enable low issuance mode
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Enable low issuance mode
    let low_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 - 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), 100_u128, 1);
    ticket_master_dispatcher.enable_low_issuance_mode();

    // Burn all tickets held by the contract
    let ticket_erc20_dispatcher = IERC20Dispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };
    let ticket_balance = ticket_erc20_dispatcher
        .balance_of(ticket_master_dispatcher.contract_address);
    if ticket_balance > 0 {
        start_cheat_caller_address(
            ticket_master_dispatcher.contract_address, ticket_master_dispatcher.contract_address,
        );
        ticket_master_dispatcher.burn(ticket_balance);
        stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
    }

    // Mock high price (above threshold)
    let high_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 + 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), high_price, 1);

    // Try to disable (should fail due to no tickets)
    ticket_master_dispatcher.disable_low_issuance_mode();
}

#[test]
fn disable_low_issuance_mode_succeeds_when_price_above_threshold() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Full setup
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    let initial_rate = ticket_master_dispatcher.get_token_distribution_rate();

    // Enable low issuance mode
    let low_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 - 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), low_price, 1);
    let returned_tokens = 100_u128;
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("decrease_sale_rate_to_self"), returned_tokens, 1);
    ticket_master_dispatcher.enable_low_issuance_mode();

    // Verify it's enabled
    assert!(ticket_master_dispatcher.is_low_issuance_mode());
    let reduced_rate = ticket_master_dispatcher.get_token_distribution_rate();
    assert!(reduced_rate < initial_rate);

    // Transfer returned tokens to contract (simulating what decrease_sale_rate_to_self does)
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, MOCK_POSITIONS_ADDRESS);
    let dungeon_ticket_dispatcher = IERC20Dispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };
    dungeon_ticket_dispatcher
        .transfer(ticket_master_dispatcher.contract_address, returned_tokens.into());
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS);

    // Mock high price (above threshold)
    let high_price: u256 = ISSUANCE_REDUCTION_PRICE_X128 + 1000;
    mock_call(EKUBO_ORACLE_MAINNET, selector!("get_price_x128_over_last"), high_price, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("withdraw_proceeds_from_sale_to_self"), 0_u128, 1);
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("increase_sell_amount"), returned_tokens, 1);

    // Disable low issuance mode (should succeed)
    ticket_master_dispatcher.disable_low_issuance_mode();

    // Verify it's disabled and rate restored
    assert!(!ticket_master_dispatcher.is_low_issuance_mode());
}

// Administrative Functions Tests

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn set_issuance_reduction_price_duration_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    let NON_OWNER_ADDRESS: ContractAddress = 'non_owner'.try_into().unwrap();

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set duration as non-owner
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, NON_OWNER_ADDRESS);
    ticket_master_dispatcher.set_issuance_reduction_price_duration(7 * 24 * 60 * 60);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
}

#[test]
#[should_panic(expected: ('reduction duration not set',))]
fn set_issuance_reduction_price_duration_rejects_zero() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set duration to zero (should fail)
    ticket_master_dispatcher.set_issuance_reduction_price_duration(0);
}

#[test]
fn set_issuance_reduction_price_duration_succeeds() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Verify initial duration
    assert_eq!(
        ticket_master_dispatcher.get_issuance_reduction_price_duration(),
        ISSUANCE_REDUCTION_PRICE_DURATION,
    );

    // Set new duration (7 days)
    let new_duration = 7 * 24 * 60 * 60;
    ticket_master_dispatcher.set_issuance_reduction_price_duration(new_duration);

    // Verify duration was updated
    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_price_duration(), new_duration);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn set_issuance_reduction_price_x128_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    let NON_OWNER_ADDRESS: ContractAddress = 'non_owner'.try_into().unwrap();

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set price as non-owner
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, NON_OWNER_ADDRESS);
    ticket_master_dispatcher.set_issuance_reduction_price_x128(5000);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
}

#[test]
#[should_panic(expected: ('reduction price not set',))]
fn set_issuance_reduction_price_x128_rejects_zero() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set price to zero (should fail)
    ticket_master_dispatcher.set_issuance_reduction_price_x128(0);
}

#[test]
fn set_issuance_reduction_price_x128_succeeds() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Verify initial price
    assert_eq!(
        ticket_master_dispatcher.get_issuance_reduction_price_x128(), ISSUANCE_REDUCTION_PRICE_X128,
    );

    // Set new price
    let new_price = ISSUANCE_REDUCTION_PRICE_X128 * 2;
    ticket_master_dispatcher.set_issuance_reduction_price_x128(new_price);

    // Verify price was updated
    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_price_x128(), new_price);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn set_issuance_reduction_bips_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    let NON_OWNER_ADDRESS: ContractAddress = 'non_owner'.try_into().unwrap();

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set bips as non-owner
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, NON_OWNER_ADDRESS);
    ticket_master_dispatcher.set_issuance_reduction_bips(5000);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
}

#[test]
#[should_panic(expected: ('reduction bips not set',))]
fn set_issuance_reduction_bips_rejects_zero() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set bips to zero (should fail)
    ticket_master_dispatcher.set_issuance_reduction_bips(0);
}

#[test]
#[should_panic(expected: ('reduction bips too large',))]
fn set_issuance_reduction_bips_rejects_exceeds_basis() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set bips >= BIPS_BASIS (should fail)
    ticket_master_dispatcher.set_issuance_reduction_bips(10001);
}

#[test]
fn set_issuance_reduction_bips_succeeds() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Verify initial bips
    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_bips(), ISSUANCE_REDUCTION_BIPS);

    // Set new bips (50%)
    let new_bips = 5000;
    ticket_master_dispatcher.set_issuance_reduction_bips(new_bips);

    // Verify bips was updated
    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_bips(), new_bips);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn set_velords_address_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    let NON_OWNER_ADDRESS: ContractAddress = 'non_owner'.try_into().unwrap();

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to set velords address as non-owner
    let new_velords_address: ContractAddress = 0x999.try_into().unwrap();
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, NON_OWNER_ADDRESS);
    ticket_master_dispatcher.set_velords_address(new_velords_address);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
}

#[test]
fn set_velords_address_succeeds() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Verify initial velords address
    assert_eq!(ticket_master_dispatcher.get_velords_address(), MOCK_VELORDS_ADDRESS);

    // Set new velords address
    let new_velords_address: ContractAddress = 0x999.try_into().unwrap();
    ticket_master_dispatcher.set_velords_address(new_velords_address);

    // Verify address was updated
    assert_eq!(ticket_master_dispatcher.get_velords_address(), new_velords_address);
}

#[test]
#[should_panic(expected: ('Caller is not the owner',))]
fn withdraw_funds_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    let NON_OWNER_ADDRESS: ContractAddress = 'non_owner'.try_into().unwrap();

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Try to withdraw funds as non-owner
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, NON_OWNER_ADDRESS);
    ticket_master_dispatcher.withdraw_funds(payment_token_dispatcher.contract_address, 1000_u256);
    stop_cheat_caller_address(ticket_master_dispatcher.contract_address);
}

#[test]
fn withdraw_funds_succeeds_for_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Transfer some tokens to the contract
    start_cheat_caller_address(payment_token_dispatcher.contract_address, DEPLOYER_ADDRESS);
    let amount_to_deposit = 5000_u256;
    payment_token_dispatcher.transfer(ticket_master_dispatcher.contract_address, amount_to_deposit);
    stop_cheat_caller_address(payment_token_dispatcher.contract_address);

    // Verify contract has the tokens
    let contract_balance = payment_token_dispatcher
        .balance_of(ticket_master_dispatcher.contract_address);
    assert_eq!(contract_balance, amount_to_deposit);

    // Verify owner's initial balance
    let owner_initial_balance = payment_token_dispatcher.balance_of(DEPLOYER_ADDRESS);

    // Withdraw funds as owner
    let amount_to_withdraw = 3000_u256;
    ticket_master_dispatcher
        .withdraw_funds(payment_token_dispatcher.contract_address, amount_to_withdraw);

    // Verify contract balance decreased
    let contract_balance_after = payment_token_dispatcher
        .balance_of(ticket_master_dispatcher.contract_address);
    assert_eq!(contract_balance_after, amount_to_deposit - amount_to_withdraw);

    // Verify owner balance increased
    let owner_balance_after = payment_token_dispatcher.balance_of(DEPLOYER_ADDRESS);
    assert_eq!(owner_balance_after, owner_initial_balance + amount_to_withdraw);
}

#[test]
fn withdraw_funds_can_withdraw_full_balance() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Transfer some tokens to the contract
    start_cheat_caller_address(payment_token_dispatcher.contract_address, DEPLOYER_ADDRESS);
    let amount_to_deposit = 10000_u256;
    payment_token_dispatcher.transfer(ticket_master_dispatcher.contract_address, amount_to_deposit);
    stop_cheat_caller_address(payment_token_dispatcher.contract_address);

    // Withdraw entire balance
    ticket_master_dispatcher
        .withdraw_funds(payment_token_dispatcher.contract_address, amount_to_deposit);

    // Verify contract balance is zero
    let contract_balance_after = payment_token_dispatcher
        .balance_of(ticket_master_dispatcher.contract_address);
    assert_eq!(contract_balance_after, 0_u256);
}

#[test]
#[should_panic(expected: ('Distribution not started',))]
fn distribute_proceeds_before_pool_initialized() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.distribute_proceeds(1, 5);
}

#[test]
#[should_panic(expected: ('Distribution not started',))]
fn distribute_proceeds_before_distribution_started() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let _ = ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    ticket_master_dispatcher.distribute_proceeds(1, 5);
}

// ================================
// distribute_proceeds Validation Tests
// ================================

#[test]
#[should_panic(expected: 'Invalid start or end time')]
fn distribute_proceeds_rejects_end_before_start() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Try to distribute with end_time <= start_time
    ticket_master_dispatcher.distribute_proceeds(100_u64, 100_u64);
}

#[test]
#[should_panic(expected: 'End time expired')]
fn distribute_proceeds_rejects_expired_end_time() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Set current time to a specific value
    let future_time = 1000000_u64;
    start_cheat_block_timestamp_global(future_time);

    // Try to distribute with end_time in the past (start_time in past, end_time also in past)
    ticket_master_dispatcher.distribute_proceeds(100_u64, 200_u64);
}

#[test]
#[should_panic(expected: 'Duration too short')]
fn distribute_proceeds_rejects_duration_too_short() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    let current_time = starknet::get_block_timestamp();
    let config = ticket_master_dispatcher.get_buyback_order_config();

    // Try to distribute with duration < min_duration
    let short_duration = config.min_duration - 1;
    ticket_master_dispatcher.distribute_proceeds(current_time, current_time + short_duration);
}

#[test]
#[should_panic(expected: 'Duration too long')]
fn distribute_proceeds_rejects_duration_too_long() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    let current_time = starknet::get_block_timestamp();
    let config = ticket_master_dispatcher.get_buyback_order_config();

    // Try to distribute with duration > max_duration
    let long_duration = config.max_duration + 1;
    ticket_master_dispatcher.distribute_proceeds(current_time, current_time + long_duration);
}

#[test]
#[should_panic(expected: 'Order must start < max delay')]
fn distribute_proceeds_rejects_delay_exceeds_max() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Give contract some payment token balance
    mock_call(payment_token_dispatcher.contract_address, selector!("balance_of"), 1000_u256, 1);

    let current_time = starknet::get_block_timestamp();
    let config = ticket_master_dispatcher.get_buyback_order_config();

    // Try to distribute with delay >= max_delay (should fail)
    let start_time = current_time + config.max_delay;
    let end_time = start_time + config.min_duration;
    ticket_master_dispatcher.distribute_proceeds(start_time, end_time);
}

#[test]
fn distribute_proceeds_accepts_delay_just_under_max() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Transfer payment tokens to the contract (as proceeds)
    start_cheat_caller_address(payment_token_dispatcher.contract_address, DEPLOYER_ADDRESS);
    payment_token_dispatcher.transfer(ticket_master_dispatcher.contract_address, 1000_u256);
    stop_cheat_caller_address(payment_token_dispatcher.contract_address);

    // Mock TWAMM position increase
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("increase_sell_amount"), 888_u128, 1);

    let current_time = starknet::get_block_timestamp();
    let config = ticket_master_dispatcher.get_buyback_order_config();

    // Distribute with delay just under max_delay (should succeed)
    let start_time = current_time + config.max_delay - 1;
    let end_time = start_time + config.min_duration;
    ticket_master_dispatcher.distribute_proceeds(start_time, end_time);
}

#[test]
fn distribute_proceeds_accepts_delay_in_valid_range() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Transfer payment tokens to the contract (as proceeds)
    start_cheat_caller_address(payment_token_dispatcher.contract_address, DEPLOYER_ADDRESS);
    payment_token_dispatcher.transfer(ticket_master_dispatcher.contract_address, 1000_u256);
    stop_cheat_caller_address(payment_token_dispatcher.contract_address);

    // Mock TWAMM position increase
    mock_call(MOCK_POSITIONS_ADDRESS, selector!("increase_sell_amount"), 888_u128, 1);

    let current_time = starknet::get_block_timestamp();
    let config = ticket_master_dispatcher.get_buyback_order_config();

    // Distribute with delay in middle of valid range (should succeed)
    let delay = config.max_delay / 2;
    let start_time = current_time + delay;
    let end_time = start_time + config.min_duration;
    ticket_master_dispatcher.distribute_proceeds(start_time, end_time);
}

#[test]
#[should_panic(expected: 'No proceeds available')]
fn distribute_proceeds_rejects_when_no_balance() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    // Setup through distribution
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (10_u64, 100_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (77_u64, 888_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    let current_time = starknet::get_block_timestamp();
    let config = ticket_master_dispatcher.get_buyback_order_config();

    // Try to distribute with no proceeds in contract (balance_of returns 0 by default)
    ticket_master_dispatcher.distribute_proceeds(current_time, current_time + config.min_duration);
}

#[test]
#[fuzzer]
fn fuzz_buyback_claim_limits(
    order_seed: u64, limit_seed: u16, proceeds_seed: u64, bookmark_seed: u64,
) {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (13_u64, 250_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (55_u64, 333_u128), 1,
    );
    ticket_master_dispatcher.start_token_distribution();

    let order_count = (order_seed % 4) + 1; // 1..=4
    let bookmark = bookmark_seed % order_count;
    let available = order_count - bookmark;
    let divisor = 256_u64;
    let random_slice = if available == 0 {
        0
    } else {
        (order_seed / divisor) % available
    };
    let matured_add = if available == 0 {
        1
    } else {
        random_slice + 1
    };
    let matured_total = bookmark + matured_add;

    let mut limit = limit_seed;
    let max_limit: u16 = available.try_into().unwrap();
    if limit > max_limit {
        limit = max_limit;
    }

    let limit_u64: u64 = if limit == 0 {
        0
    } else {
        limit.try_into().unwrap()
    };
    let processed = if limit == 0 {
        matured_add
    } else if limit_u64 < matured_add {
        limit_u64
    } else {
        matured_add
    };

    let proceeds_per_order: u128 = (proceeds_seed % 1_000_000_000_000_u64 + 1).into();
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("withdraw_proceeds_from_sale_to"),
        proceeds_per_order,
        processed.try_into().unwrap(),
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(
        contract_address, selector!("buyback_order_key_counter"), array![order_count.into()].span(),
    );
    store(
        contract_address, selector!("buyback_order_key_bookmark"), array![bookmark.into()].span(),
    );

    let base_timestamp: u64 = 900_000 + (order_seed % 10_000);
    let mut idx: u64 = 0;
    loop {
        if idx == order_count {
            break;
        }

        let map_address = map_entry_address(
            selector!("buyback_order_key_end_time"), array![idx.into()].span(),
        );

        let end_time = if idx < matured_total {
            base_timestamp - (idx + 1)
        } else {
            base_timestamp + (idx + 1) * 100
        };
        store(contract_address, map_address, array![end_time.into()].span());
        idx += 1;
    }

    start_cheat_block_timestamp_global(base_timestamp);
    let (claimed, new_bookmark) = ticket_master_dispatcher.claim_and_distribute_buybacks(limit);
    start_cheat_block_timestamp_global(0_u64);

    let expected_processed = processed;
    let processed_u128: u128 = expected_processed.into();
    let expected_claimed: u128 = proceeds_per_order * processed_u128;
    assert_eq!(claimed, expected_claimed);

    let expected_bookmark: u64 = bookmark + expected_processed;
    let expected_bookmark_u128: u128 = expected_bookmark.into();
    assert_eq!(new_bookmark, expected_bookmark_u128);

    let bookmark_snapshot = load(contract_address, selector!("buyback_order_key_bookmark"), 1);
    assert!(bookmark_snapshot == array![expected_bookmark_u128.into()]);

    let counter_snapshot = load(contract_address, selector!("buyback_order_key_counter"), 1);
    assert!(counter_snapshot == array![order_count.into()]);

    let mut verify_index: u64 = 0;
    loop {
        if verify_index == order_count {
            break;
        }

        let map_address = map_entry_address(
            selector!("buyback_order_key_end_time"), array![verify_index.into()].span(),
        );
        let snapshot = load(contract_address, map_address, 1);
        let mut span = snapshot.span();
        let value = span.pop_front().unwrap();
        let stored: u64 = (*value).try_into().unwrap();
        if verify_index < expected_bookmark {
            assert!(stored <= base_timestamp);
        }
        verify_index += 1;
    }
}

#[test]
fn claim_and_distribute_buybacks_claims_limited_matured_orders() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(contract_address, selector!("position_token_id"), array![123_u64.into()].span());
    store(contract_address, selector!("buyback_order_key_counter"), array![3_u128.into()].span());
    store(contract_address, selector!("buyback_order_key_bookmark"), array![0_u128.into()].span());

    let current_timestamp: u64 = 777_000;
    let map_address_0 = map_entry_address(
        selector!("buyback_order_key_end_time"), array![0.into()].span(),
    );
    store(contract_address, map_address_0, array![(current_timestamp - 10).into()].span());
    let map_address_1 = map_entry_address(
        selector!("buyback_order_key_end_time"), array![1.into()].span(),
    );
    store(contract_address, map_address_1, array![(current_timestamp - 5).into()].span());
    let map_address_2 = map_entry_address(
        selector!("buyback_order_key_end_time"), array![2.into()].span(),
    );
    store(contract_address, map_address_2, array![(current_timestamp + 100).into()].span());

    let proceeds_first: u128 = 111;
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("withdraw_proceeds_from_sale_to"), proceeds_first, 1,
    );

    start_cheat_block_timestamp_global(current_timestamp);
    let (claimed, bookmark) = ticket_master_dispatcher.claim_and_distribute_buybacks(1_u16);
    start_cheat_block_timestamp_global(0_u64);

    assert_eq!(claimed, proceeds_first);
    assert_eq!(bookmark, 1_u128);

    let stored_bookmark = load(contract_address, selector!("buyback_order_key_bookmark"), 1);
    assert!(stored_bookmark == array![1.into()]);
}

#[test]
fn claim_and_distribute_buybacks_limit_zero_claims_remaining() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(contract_address, selector!("position_token_id"), array![321_u64.into()].span());
    store(contract_address, selector!("buyback_order_key_counter"), array![3_u128.into()].span());
    store(contract_address, selector!("buyback_order_key_bookmark"), array![1_u128.into()].span());

    let current_timestamp: u64 = 888_000;
    let map_address_1 = map_entry_address(
        selector!("buyback_order_key_end_time"), array![1.into()].span(),
    );
    store(contract_address, map_address_1, array![(current_timestamp - 20).into()].span());
    let map_address_2 = map_entry_address(
        selector!("buyback_order_key_end_time"), array![2.into()].span(),
    );
    store(contract_address, map_address_2, array![(current_timestamp - 5).into()].span());

    let proceeds_each: u128 = 70;
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("withdraw_proceeds_from_sale_to"), proceeds_each, 2,
    );

    start_cheat_block_timestamp_global(current_timestamp);
    let (claimed, bookmark) = ticket_master_dispatcher.claim_and_distribute_buybacks(0_u16);
    start_cheat_block_timestamp_global(0_u64);

    assert_eq!(claimed, proceeds_each * 2_u128);
    assert_eq!(bookmark, 3_u128);

    let stored_bookmark = load(contract_address, selector!("buyback_order_key_bookmark"), 1);
    assert!(stored_bookmark == array![3.into()]);
}

#[test]
fn test_claim_and_distribute_buybacks_success_path() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(contract_address, selector!("position_token_id"), array![77_u64.into()].span());
    store(contract_address, selector!("buyback_order_key_counter"), array![1_u128.into()].span());
    store(contract_address, selector!("buyback_order_key_bookmark"), array![0_u128.into()].span());

    let current_timestamp: u64 = 2_000_000;
    let map_address = map_entry_address(
        selector!("buyback_order_key_end_time"), array![0.into()].span(),
    );
    store(contract_address, map_address, array![(current_timestamp - 60).into()].span());

    let proceeds_each: u128 = 777;
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("withdraw_proceeds_from_sale_to"), proceeds_each, 1,
    );

    start_cheat_block_timestamp_global(current_timestamp);
    let (claimed, bookmark) = ticket_master_dispatcher.claim_and_distribute_buybacks(1_u16);
    start_cheat_block_timestamp_global(0_u64);

    assert_eq!(claimed, proceeds_each);
    assert_eq!(bookmark, 1_u128);

    let stored_bookmark = load(contract_address, selector!("buyback_order_key_bookmark"), 1);
    assert!(stored_bookmark == array![1.into()]);
}

#[test]
#[should_panic(expected: ('All buyback orders claimed',))]
fn claim_and_distribute_buybacks_when_all_claimed() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(contract_address, selector!("position_token_id"), array![42_u64.into()].span());
    store(contract_address, selector!("buyback_order_key_counter"), array![2_u128.into()].span());
    store(contract_address, selector!("buyback_order_key_bookmark"), array![2_u128.into()].span());

    ticket_master_dispatcher.claim_and_distribute_buybacks(1_u16);
}

#[test]
#[should_panic(expected: "No proceeds available to claim")]
fn test_claim_and_distribute_buybacks_without_mature_proceeds() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(contract_address, selector!("position_token_id"), array![11_u64.into()].span());
    store(contract_address, selector!("buyback_order_key_counter"), array![1_u128.into()].span());
    store(contract_address, selector!("buyback_order_key_bookmark"), array![0_u128.into()].span());

    let current_timestamp: u64 = 1_000_000;
    let map_address = map_entry_address(
        selector!("buyback_order_key_end_time"), array![0.into()].span(),
    );
    store(contract_address, map_address, array![(current_timestamp + 120).into()].span());

    start_cheat_block_timestamp_global(current_timestamp);
    ticket_master_dispatcher.claim_and_distribute_buybacks(5_u16);
}

#[test]
fn set_treasury_address_updates_for_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let new_treasury: ContractAddress = 'new_treasury'.try_into().unwrap();

    cheat_caller_address(
        ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS, CheatSpan::TargetCalls(1),
    );
    ticket_master_dispatcher.set_treasury_address(new_treasury);

    assert_eq!(ticket_master_dispatcher.get_treasury_address(), new_treasury);
}

#[test]
#[should_panic]
fn set_treasury_address_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let intruder: ContractAddress = 'intruder'.try_into().unwrap();
    cheat_caller_address(
        ticket_master_dispatcher.contract_address, intruder, CheatSpan::TargetCalls(1),
    );
    ticket_master_dispatcher.set_treasury_address(MOCK_TREASURY);
}

#[test]
#[should_panic(expected: ('invalid recipient',))]
fn set_treasury_address_no_zero_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    cheat_caller_address(
        ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS, CheatSpan::TargetCalls(1),
    );
    ticket_master_dispatcher.set_treasury_address(ZERO_ADDRESS);

    assert_eq!(ticket_master_dispatcher.get_treasury_address(), ZERO_ADDRESS);
}

#[test]
fn set_issuance_reduction_price_x128_updates_for_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let new_price: u256 = 2_000_000_000_000_000_000;
    ticket_master_dispatcher.set_issuance_reduction_price_x128(new_price);

    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_price_x128(), new_price);
}

#[test]
#[should_panic(expected: 'reduction price not set')]
fn set_issuance_reduction_price_x128_rejects_zero_price() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.set_issuance_reduction_price_x128(0);
}

#[test]
fn set_issuance_reduction_bips_updates_for_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let new_bips: u128 = 5000;
    ticket_master_dispatcher.set_issuance_reduction_bips(new_bips);

    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_bips(), new_bips);
}

#[test]
#[should_panic(expected: 'reduction bips not set')]
fn set_issuance_reduction_bips_rejects_zero_bips() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.set_issuance_reduction_bips(0);
}

#[test]
#[should_panic(expected: 'reduction bips too large')]
fn set_issuance_reduction_bips_rejects_bips_above_limit() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.set_issuance_reduction_bips(BIPS_BASIS + 1);
}

// ================================
// View Function Tests
// ================================

#[test]
fn get_token_distribution_rate_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let rate = ticket_master_dispatcher.get_token_distribution_rate();
    assert_eq!(rate, 0, "Initial distribution rate should be zero");
}

#[test]
fn get_buyback_rate_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let rate = ticket_master_dispatcher.get_buyback_rate();
    assert_eq!(rate, 0, "Initial buyback rate should be zero");
}

#[test]
fn get_distribution_end_time_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let end_time = ticket_master_dispatcher.get_distribution_end_time();
    assert_eq!(end_time, DISTRIBUTION_END_TIME, "End time should match constructor value");
}

#[test]
fn get_pool_id_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let pool_id = ticket_master_dispatcher.get_pool_id();
    assert_eq!(pool_id, 0, "Pool ID should be zero before initialization");
}

#[test]
fn get_position_token_id_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let position_id = ticket_master_dispatcher.get_position_token_id();
    assert_eq!(position_id, 0, "Position token ID should be zero before distribution starts");
}

#[test]
fn get_payment_token_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let payment_token = ticket_master_dispatcher.get_payment_token();
    assert_eq!(
        payment_token,
        payment_token_dispatcher.contract_address,
        "Payment token address should match",
    );
}

#[test]
fn get_buyback_token_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, reward_token_dispatcher) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let buyback_token = ticket_master_dispatcher.get_buyback_token();
    assert_eq!(
        buyback_token,
        reward_token_dispatcher.contract_address,
        "Buyback token address should match",
    );
}

#[test]
fn get_extension_address_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let extension = ticket_master_dispatcher.get_extension_address();
    assert_eq!(extension, MOCK_TWAMM_EXTENSION_ADDRESS, "Extension address should match");
}

#[test]
fn get_issuance_reduction_price_x128_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let price = ticket_master_dispatcher.get_issuance_reduction_price_x128();
    assert_eq!(
        price, ISSUANCE_REDUCTION_PRICE_X128, "Reduction price should match constructor value",
    );
}

#[test]
fn is_low_issuance_mode_returns_false_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let is_low = ticket_master_dispatcher.is_low_issuance_mode();
    assert_eq!(is_low, false, "Low issuance mode should be inactive initially");
}

#[test]
fn get_treasury_address_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let treasury = ticket_master_dispatcher.get_treasury_address();
    assert_eq!(treasury, MOCK_TREASURY, "Treasury address should match constructor value");
}

#[test]
fn get_velords_address_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let velords = ticket_master_dispatcher.get_velords_address();
    assert_eq!(velords, MOCK_VELORDS_ADDRESS, "VeLords address should match constructor value");
}

#[test]
fn get_position_nft_address_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let nft_address = ticket_master_dispatcher.get_position_nft_address();
    assert_eq!(nft_address, MOCK_POSITION_NFT_ADDRESS, "Position NFT address should match");
}

#[test]
fn get_issuance_reduction_bips_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let bips = ticket_master_dispatcher.get_issuance_reduction_bips();
    assert_eq!(bips, ISSUANCE_REDUCTION_BIPS, "Reduction bips should match constructor value");
}

#[test]
fn get_deployment_state_returns_initial_state() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let state = ticket_master_dispatcher.get_deployment_state();
    assert_eq!(state, 0, "Deployment state should be 0 initially");
}

#[test]
fn is_pool_initialized_returns_false_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let is_initialized = ticket_master_dispatcher.is_pool_initialized();
    assert_eq!(is_initialized, false, "Pool should not be initialized initially");
}

#[test]
fn get_buyback_order_key_counter_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let counter = ticket_master_dispatcher.get_buyback_order_key_counter();
    assert_eq!(counter, 0, "Buyback order key counter should be zero initially");
}

#[test]
fn get_buyback_order_key_bookmark_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let bookmark = ticket_master_dispatcher.get_buyback_order_key_bookmark();
    assert_eq!(bookmark, 0, "Buyback order key bookmark should be zero initially");
}

#[test]
fn get_unclaimed_buyback_orders_count_returns_zero_initially() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let count = ticket_master_dispatcher.get_unclaimed_buyback_orders_count();
    assert_eq!(count, 0, "Unclaimed buyback orders count should be zero initially");
}

#[test]
fn get_distribution_pool_fee_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let fee = ticket_master_dispatcher.get_distribution_pool_fee();
    assert_eq!(
        fee, DISTRIBUTION_POOL_FEE_BPS, "Distribution pool fee should match constructor value",
    );
}

#[test]
fn get_buyback_order_config_returns_configured_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let config = ticket_master_dispatcher.get_buyback_order_config();
    assert_eq!(config.min_delay, BUYBACK_ORDER_CONFIG.min_delay, "Min delay should match");
    assert_eq!(config.max_delay, BUYBACK_ORDER_CONFIG.max_delay, "Max delay should match");
    assert_eq!(config.min_duration, BUYBACK_ORDER_CONFIG.min_duration, "Min duration should match");
    assert_eq!(config.max_duration, BUYBACK_ORDER_CONFIG.max_duration, "Max duration should match");
    assert_eq!(config.fee, BUYBACK_ORDER_CONFIG.fee, "Fee should match");
}

#[test]
fn get_core_dispatcher_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let core_dispatcher = ticket_master_dispatcher.get_core_dispatcher();
    assert_eq!(core_dispatcher.contract_address, MOCK_CORE_ADDRESS, "Core address should match");
}

#[test]
fn get_positions_dispatcher_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let positions_dispatcher = ticket_master_dispatcher.get_positions_dispatcher();
    assert_eq!(
        positions_dispatcher.contract_address,
        MOCK_POSITIONS_ADDRESS,
        "Positions address should match",
    );
}

#[test]
fn get_registry_dispatcher_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let registry_dispatcher = ticket_master_dispatcher.get_registry_dispatcher();
    assert_eq!(
        registry_dispatcher.contract_address,
        MOCK_REGISTRY_ADDRESS,
        "Registry address should match",
    );
}

#[test]
fn get_oracle_address_returns_configured_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let oracle_dispatcher = ticket_master_dispatcher.get_oracle_address();
    assert_eq!(
        oracle_dispatcher.contract_address, EKUBO_ORACLE_MAINNET, "Oracle address should match",
    );
}

#[test]
fn get_tokens_for_distribution_returns_initial_value() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let tokens = ticket_master_dispatcher.get_tokens_for_distribution();
    // Should be total supply minus 1 ERC20_UNIT (for registry)
    let expected = DUNGEON_TICKET_SUPPLY.into() - ERC20_UNIT.into();
    assert_eq!(tokens, expected, "Tokens for distribution should match");
}

// ================================
// ERC20 Burn Tests
// ================================

#[test]
fn burn_reduces_total_supply() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    // Create a deployment with initial distribution to deployer so they have tokens to burn
    let recipients: Array<ContractAddress> = array![DEPLOYER_ADDRESS];
    let amounts: Array<u256> = array![1000000_u256];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let erc20_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    start_cheat_caller_address(ticket_master_address, DEPLOYER_ADDRESS);

    let initial_supply = erc20_dispatcher.total_supply();
    let burn_amount = 500000_u256;

    ticket_master_dispatcher.burn(burn_amount);

    let final_supply = erc20_dispatcher.total_supply();
    assert_eq!(
        final_supply, initial_supply - burn_amount, "Total supply should decrease by burn amount",
    );
}

#[test]
#[should_panic]
fn burn_reverts_when_insufficient_balance() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let erc20_dispatcher = IERC20Dispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };
    let balance = erc20_dispatcher.balance_of(DEPLOYER_ADDRESS);

    // Try to burn more than balance
    ticket_master_dispatcher.burn(balance + 1);
}

#[test]
fn burn_from_reduces_target_balance() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let recipient: ContractAddress = 'recipient'.try_into().unwrap();
    let recipients: Array<ContractAddress> = array![recipient];
    let amounts: Array<u256> = array![1000000_u256];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };
    let erc20_dispatcher = IERC20Dispatcher { contract_address: ticket_master_address };

    // Recipient approves deployer to burn their tokens
    start_cheat_caller_address(ticket_master_address, recipient);
    let burn_amount = 300000_u256;
    erc20_dispatcher.approve(DEPLOYER_ADDRESS, burn_amount);

    // Deployer burns tokens from recipient
    start_cheat_caller_address(ticket_master_address, DEPLOYER_ADDRESS);
    let initial_balance = erc20_dispatcher.balance_of(recipient);

    ticket_master_dispatcher.burn_from(recipient, burn_amount);

    let final_balance = erc20_dispatcher.balance_of(recipient);
    assert_eq!(
        final_balance, initial_balance - burn_amount, "Balance should decrease by burn amount",
    );
}

#[test]
#[should_panic(expected: 'ERC20: insufficient allowance')]
fn burn_from_reverts_without_approval() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let erc20_class = declare_class("ERC20Mock");
    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );

    let ticket_master_class = declare_class("TicketMaster");

    let recipient: ContractAddress = 'recipient'.try_into().unwrap();
    let recipients: Array<ContractAddress> = array![recipient];
    let amounts: Array<u256> = array![1000000_u256];

    let calldata = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        DUNGEON_TICKET_SUPPLY,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        recipients,
        amounts,
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let ticket_master_address = deploy(ticket_master_class, calldata);
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };

    // Deployer tries to burn tokens from recipient without approval
    start_cheat_caller_address(ticket_master_address, DEPLOYER_ADDRESS);
    ticket_master_dispatcher.burn_from(recipient, 100000_u256);
}

#[test]
fn set_issuance_reduction_bips_accepts_bips_at_limit() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.set_issuance_reduction_bips(BIPS_BASIS);

    assert_eq!(ticket_master_dispatcher.get_issuance_reduction_bips(), BIPS_BASIS);
}

#[test]
fn set_velords_address_updates_for_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let new_velords: ContractAddress = 'new_velords'.try_into().unwrap();
    ticket_master_dispatcher.set_velords_address(new_velords);

    assert_eq!(ticket_master_dispatcher.get_velords_address(), new_velords);
}

#[test]
#[should_panic(expected: 'invalid recipient')]
fn set_velords_address_rejects_zero_address() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.set_velords_address(ZERO_ADDRESS);
}

#[test]
fn set_buyback_order_config_updates_for_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let new_config = BuybackOrderConfig {
        min_delay: 100,
        max_delay: 20000,
        min_duration: 500000,
        max_duration: 1000000,
        fee: 1701411834604692317316873037158841057,
    };
    ticket_master_dispatcher.set_buyback_order_config(new_config);

    let retrieved_config = ticket_master_dispatcher.get_buyback_order_config();
    assert_eq!(retrieved_config.min_delay, new_config.min_delay);
    assert_eq!(retrieved_config.max_delay, new_config.max_delay);
    assert_eq!(retrieved_config.min_duration, new_config.min_duration);
    assert_eq!(retrieved_config.max_duration, new_config.max_duration);
    assert_eq!(retrieved_config.fee, new_config.fee);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn set_buyback_order_config_rejects_non_owner() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let non_owner: ContractAddress = 'non_owner'.try_into().unwrap();
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, non_owner);

    let new_config = BuybackOrderConfig {
        min_delay: 100,
        max_delay: 20000,
        min_duration: 500000,
        max_duration: 1000000,
        fee: 1701411834604692317316873037158841057,
    };
    ticket_master_dispatcher.set_buyback_order_config(new_config);
}

#[test]
fn test_get_distribution_end_time_after_constructor() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    assert_eq!(ticket_master_dispatcher.get_distribution_end_time(), DISTRIBUTION_END_TIME);
}

#[test]
fn get_distribution_pool_key_respects_token_ordering() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, _, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let contract_address = ticket_master_dispatcher.contract_address;

    let contract_felt: felt252 = contract_address.into();
    let higher_address: ContractAddress = (contract_felt + 1).try_into().unwrap();
    store(contract_address, selector!("payment_token"), array![higher_address.into()].span());
    let pool_key_high = ticket_master_dispatcher.get_distribution_pool_key();
    assert_eq!(pool_key_high.token0, contract_address);
    assert_eq!(pool_key_high.token1, higher_address);

    let lower_address: ContractAddress = (contract_felt - 1).try_into().unwrap();
    store(contract_address, selector!("payment_token"), array![lower_address.into()].span());
    let pool_key_low = ticket_master_dispatcher.get_distribution_pool_key();
    assert_eq!(pool_key_low.token0, lower_address);
    assert_eq!(pool_key_low.token1, contract_address);
}

#[test]
fn pause_like_behavior_via_owner_change() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    let ownable_dispatcher = IOwnableDispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };

    let initial_owner = ownable_dispatcher.owner();
    assert_eq!(initial_owner, DEPLOYER_ADDRESS);

    let new_owner: ContractAddress = 'new_owner'.try_into().unwrap();

    cheat_caller_address(
        ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS, CheatSpan::TargetCalls(1),
    );
    ownable_dispatcher.transfer_ownership(new_owner);
    assert_eq!(ownable_dispatcher.owner(), new_owner);

    let _unauthorized_treasury: ContractAddress = 'unauthorized'.try_into().unwrap();
    assert!(ownable_dispatcher.owner() != DEPLOYER_ADDRESS);
    assert_eq!(ticket_master_dispatcher.get_treasury_address(), MOCK_TREASURY);

    mock_ekubo_core(1_u256);
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, new_owner);

    let distribution_pool_id = ticket_master_dispatcher
        .init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    assert_eq!(distribution_pool_id, 1_u256);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (7_u64, 33_u128, 0_u256, 0_u256),
        1,
    );

    start_cheat_caller_address(ticket_master_dispatcher.contract_address, new_owner);
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    assert_eq!(ownable_dispatcher.owner(), new_owner);
    assert_eq!(ticket_master_dispatcher.get_treasury_address(), MOCK_TREASURY);
}

#[test]
fn insufficient_payment_tokens_edge() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    mock_ekubo_core(1_u256);
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    let unauthorized_distribution = call_contract_syscall(
        ticket_master_dispatcher.contract_address,
        0x22b318b38f50b7f459b6d6d51ac571e9d83b95bddbc4614999eb49d9b62d9e2,
        array![].span(),
    );

    match unauthorized_distribution {
        Result::Ok(_) => panic!("expected start_token_distribution to revert before liquidity"),
        Result::Err(_) => (),
    }

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (3_u64, 5_u128, 0_u256, 0_u256),
        1,
    );

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 2_u8);

    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (9_u64, 7_u128), 1,
    );

    let tokens_for_distribution = ticket_master_dispatcher.get_tokens_for_distribution();
    let token_dispatcher = IERC20Dispatcher {
        contract_address: ticket_master_dispatcher.contract_address,
    };
    let balance_before = token_dispatcher.balance_of(MOCK_POSITIONS_ADDRESS);

    ticket_master_dispatcher.start_token_distribution();

    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 3_u8);

    let balance_after = token_dispatcher.balance_of(MOCK_POSITIONS_ADDRESS);
    assert_eq!(balance_after, balance_before + tokens_for_distribution);
}

#[test]
#[should_panic(expected: "No tokens available for distribution")]
fn test_start_token_distribution_without_tokens() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);
    mock_ekubo_core(1_u256);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (5_u64, 7_u128, 0_u256, 0_u256),
        1,
    );

    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    let contract_address = ticket_master_dispatcher.contract_address;
    store(
        contract_address, selector!("tokens_for_distribution"), array![0.into(), 0.into()].span(),
    );

    ticket_master_dispatcher.start_token_distribution();
}

#[test]
fn distribution_start_succeeds_with_minimal_tokens_for_distribution() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let ticket_master_class = declare_class("TicketMaster");
    let erc20_class = declare_class("ERC20Mock");

    let payment_token_address = deploy(
        erc20_class,
        token_calldata("Payment Token", "PT", PAYMENT_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let reward_token_address = deploy(
        erc20_class,
        token_calldata("Reward Token", "RT", REWARD_TOKEN_INITIAL_SUPPLY, DEPLOYER_ADDRESS),
    );
    let payment_token_dispatcher = IERC20Dispatcher { contract_address: payment_token_address };

    let registry_token: u128 = 1_000_000_000_000_000_000;
    let recipient: ContractAddress = 'tiny_recipient'.try_into().unwrap();
    let total_supply: u128 = DUNGEON_TICKET_SUPPLY;
    let minimal_distribution = 10_000_000_000_000_000_u128;
    let recipient_amount = total_supply
        - registry_token
        - INITIAL_LIQUIDITY_DUNGEON_TICKETS
        - minimal_distribution;

    let calldata_minimal = ticket_master_calldata_custom(
        DEPLOYER_ADDRESS,
        "Beasts Dungeon Ticket",
        "BDT",
        total_supply,
        DISTRIBUTION_POOL_FEE_BPS,
        payment_token_address,
        reward_token_address,
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
        array![recipient],
        array![recipient_amount.into()],
        DISTRIBUTION_END_TIME,
        BUYBACK_ORDER_CONFIG,
    );

    let deploy_result = ticket_master_class.deploy(@calldata_minimal);
    let (ticket_master_address, _) = match deploy_result {
        Result::Ok(ticket_master_address) => ticket_master_address,
        Result::Err(err) => panic!("{:?}", err),
    };
    let ticket_master_dispatcher = ITicketMasterDispatcher {
        contract_address: ticket_master_address,
    };

    let expected_tokens_before_liquidity = INITIAL_LIQUIDITY_DUNGEON_TICKETS.into()
        + minimal_distribution.into();
    assert_eq!(
        ticket_master_dispatcher.get_tokens_for_distribution(), expected_tokens_before_liquidity,
    );

    mock_ekubo_core(1_u256);
    start_cheat_caller_address(ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS);
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);

    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        (4_u64, 8_u128, 0_u256, 0_u256),
        1,
    );
    ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    assert_eq!(ticket_master_dispatcher.get_tokens_for_distribution(), minimal_distribution.into());

    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("mint_and_increase_sell_amount"), (11_u64, 2_u128), 1,
    );

    ticket_master_dispatcher.start_token_distribution();

    assert!(ticket_master_dispatcher.get_token_distribution_rate() > 0_u128);
}


fn assert_constructor_revert_with_message<T, +Drop<T>>(
    deploy_result: Result<T, Array<felt252>>, expected_message: felt252,
) {
    assert!(deploy_result.is_err(), "constructor should reject invalid input");

    let panic_data = deploy_result.unwrap_err();
    let mut panic_span = panic_data.span();

    match panic_span.pop_front() {
        Option::Some(message_snapshot) => {
            let message = *message_snapshot;
            assert!(message == expected_message, "unexpected revert message: {}", message);
        },
        Option::None => panic!("missing panic message"),
    }

    match panic_span.pop_front() {
        Option::None => (),
        Option::Some(_) => panic!("unexpected extra panic data"),
    }
}

#[test]
#[fork("mainnet")]
fn simple_mainnet() {
    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MAINNET_CORE_ADDRESS,
        MAINNET_POSITIONS_ADDRESS,
        MAINNET_POSITION_NFT_ADDRESS,
        MAINNET_TWAMM_EXTENSION_ADDRESS,
        MAINNET_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MAINNET_TREASURY,
    );

    assert!(
        ticket_master_dispatcher.get_pool_id() == 0,
        "Pool should not be initialized. Expected: 0, Actual: {}",
        ticket_master_dispatcher.get_pool_id(),
    );
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    assert!(
        ticket_master_dispatcher.get_pool_id() > 0,
        "Pool not initialized. Expected: > 0, Actual: {}",
        ticket_master_dispatcher.get_pool_id(),
    );

    // provide ekubo position contract with approval for the payment token
    start_cheat_caller_address(payment_token_dispatcher.contract_address, DEPLOYER_ADDRESS);
    payment_token_dispatcher
        .approve(
            ticket_master_dispatcher.contract_address,
            INITIAL_LIQUIDITY_PAYMENT_TOKEN.into() * 1000,
        );
    payment_token_dispatcher
        .approve(MAINNET_POSITIONS_ADDRESS, INITIAL_LIQUIDITY_PAYMENT_TOKEN.into() * 1000);
    stop_cheat_caller_address(payment_token_dispatcher.contract_address);

    cheat_caller_address(
        ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS, CheatSpan::TargetCalls(1),
    );
    let (
        initial_liquidity_position_id, liquidity, cleared_payment_tokens, cleared_dungeon_tickets,
    ) =
        ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );
    assert!(
        initial_liquidity_position_id > 0, "initial_liquidity_position_id should be greater than 0",
    );
    assert!(
        liquidity > INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        "initial liquidty to low. Expected: > {}, Actual: {}",
        INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        liquidity,
    );
    assert!(
        cleared_payment_tokens == 0,
        "cleared_payment_tokens should be 0. Actual: {}",
        cleared_payment_tokens,
    );
    assert!(
        cleared_dungeon_tickets == 0,
        "cleared_dungeon_tickets should be 0. Actual: {}",
        cleared_dungeon_tickets,
    );

    let actual_distribution_end_time = ticket_master_dispatcher.get_distribution_end_time();
    let end_time_delta = if actual_distribution_end_time > DISTRIBUTION_END_TIME {
        actual_distribution_end_time - DISTRIBUTION_END_TIME
    } else {
        DISTRIBUTION_END_TIME - actual_distribution_end_time
    };

    assert!(
        end_time_delta * 200 <= DISTRIBUTION_END_TIME + actual_distribution_end_time,
        "End time delta more than 1% of end time provided to constructor. Provided: {}, Actual: {}",
        DISTRIBUTION_END_TIME,
        actual_distribution_end_time,
    );

    assert!(
        ticket_master_dispatcher.get_token_distribution_rate() == 0,
        "Rate should be 0. Expected: 0, Actual: {}",
        ticket_master_dispatcher.get_token_distribution_rate(),
    );
    assert!(
        ticket_master_dispatcher.get_deployment_state() == 2,
        "Deployment state should be 2. Expected: 2, Actual: {}",
        ticket_master_dispatcher.get_deployment_state(),
    );

    // Step 4: Start distribution
    ticket_master_dispatcher.start_token_distribution();

    // Verify distribution started
    assert!(
        ticket_master_dispatcher.get_token_distribution_rate() > 0,
        "Rate should be set. Expected: > 0, Actual: {}",
        ticket_master_dispatcher.get_token_distribution_rate(),
    );
}

#[test]
#[fork("mainnet")]
fn mainnet_full() {
    // This test validates the full lifecycle of the TicketMaster contract on mainnet fork
    // extending simple_mainnet with additional verification and future low issuance mode testing

    let (ticket_master_dispatcher, payment_token_dispatcher, reward_token_dispatcher) = setup(
        MAINNET_CORE_ADDRESS,
        MAINNET_POSITIONS_ADDRESS,
        MAINNET_POSITION_NFT_ADDRESS,
        MAINNET_TWAMM_EXTENSION_ADDRESS,
        MAINNET_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MAINNET_TREASURY,
    );

    // Verify initial state
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 0, "Should start in state 0");
    assert!(ticket_master_dispatcher.get_pool_id() == 0, "Pool should not be initialized");

    // Step 2: Initialize pool
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    assert!(ticket_master_dispatcher.get_pool_id() > 0, "Pool should be initialized");
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 1, "Should be in state 1");

    // Step 3: Provide initial liquidity
    start_cheat_caller_address(payment_token_dispatcher.contract_address, DEPLOYER_ADDRESS);
    payment_token_dispatcher
        .approve(
            ticket_master_dispatcher.contract_address,
            INITIAL_LIQUIDITY_PAYMENT_TOKEN.into() * 1000,
        );
    payment_token_dispatcher
        .approve(MAINNET_POSITIONS_ADDRESS, INITIAL_LIQUIDITY_PAYMENT_TOKEN.into() * 1000);
    stop_cheat_caller_address(payment_token_dispatcher.contract_address);

    cheat_caller_address(
        ticket_master_dispatcher.contract_address, DEPLOYER_ADDRESS, CheatSpan::TargetCalls(1),
    );
    let (initial_liquidity_position_id, liquidity, _, cleared_dungeon_tickets) =
        ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    assert!(
        initial_liquidity_position_id > 0, "initial_liquidity_position_id should be greater than 0",
    );
    assert!(liquidity > INITIAL_LIQUIDITY_MIN_LIQUIDITY, "initial liquidity too low");
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 2, "Should be in state 2");

    // Step 4: Start distribution
    ticket_master_dispatcher.start_token_distribution();

    assert!(ticket_master_dispatcher.get_token_distribution_rate() > 0, "Rate should be set");
    assert_eq!(ticket_master_dispatcher.get_deployment_state(), 3, "Should be in state 3");
    assert!(
        ticket_master_dispatcher.get_position_token_id() > 0, "Position token ID should be set",
    );

    // Step 5: Future - Low issuance mode testing
    // TODO: Add low issuance mode enable/disable testing
    // Currently challenging due to inability to mock oracle in fork mode
    // Would require actual market conditions where price < threshold

    // Final verification - extended view function checks
    assert!(ticket_master_dispatcher.is_pool_initialized(), "Pool should be initialized");
    assert_eq!(
        ticket_master_dispatcher.get_payment_token(),
        payment_token_dispatcher.contract_address,
        "Payment token should match",
    );
    assert_eq!(
        ticket_master_dispatcher.get_buyback_token(),
        reward_token_dispatcher.contract_address,
        "Buyback token should match",
    );
    assert!(!ticket_master_dispatcher.is_low_issuance_mode(), "Low issuance should be inactive");
}

#[test]
fn mock_simple_flow() {
    start_mock_call(MOCK_REGISTRY_ADDRESS, selector!("register_token"), 0);

    let (ticket_master_dispatcher, payment_token_dispatcher, _) = setup(
        MOCK_CORE_ADDRESS,
        MOCK_POSITIONS_ADDRESS,
        MOCK_POSITION_NFT_ADDRESS,
        MOCK_TWAMM_EXTENSION_ADDRESS,
        MOCK_REGISTRY_ADDRESS,
        EKUBO_ORACLE_MAINNET,
        MOCK_VELORDS_ADDRESS,
        ISSUANCE_REDUCTION_PRICE_X128,
        ISSUANCE_REDUCTION_PRICE_DURATION,
        ISSUANCE_REDUCTION_BIPS,
        MOCK_TREASURY,
    );

    assert(ticket_master_dispatcher.get_pool_id() == 0, 'Pool should not be initialized');

    // Step 2: Initialize pool using helper
    mock_ekubo_core(1_u256);
    ticket_master_dispatcher.init_distribution_pool(DISTRIBUTION_INITIAL_TICK);
    assert(ticket_master_dispatcher.get_pool_id() == 1, 'Pool not initialized');

    // Step 3: Provide initial liquidity (new required step)
    // Mock the transfer_from call for payment token
    mock_call(payment_token_dispatcher.contract_address, selector!("transfer_from"), true, 1);

    // Mock the mint_and_deposit_and_clear_both call on the actual positions address
    // This function returns (position_id, liquidity, cleared_payment, cleared_our)
    // but provide_initial_liquidity only returns (position_id, cleared_payment, cleared_our)
    let mint_and_deposit_and_clear_both_mock_return = (1_u64, 100_u128, 0_u256, 0_u256);

    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("mint_and_deposit_and_clear_both"),
        mint_and_deposit_and_clear_both_mock_return,
        1,
    );

    let (
        _initial_liquidity_position_id,
        _liquidity,
        _cleared_payment_tokens,
        _cleared_dungeon_tickets,
    ) =
        ticket_master_dispatcher
        .provide_initial_liquidity(
            INITIAL_LIQUIDITY_PAYMENT_TOKEN,
            INITIAL_LIQUIDITY_DUNGEON_TICKETS,
            INITIAL_LIQUIDITY_MIN_LIQUIDITY,
        );

    // Step 4: Start distribution
    let position_id = 2_u64;
    let mint_and_increase_sell_amount_mock_return = (position_id, 100_u128);
    mock_call(
        MOCK_POSITIONS_ADDRESS, // Use the actual deployed positions address
        selector!("mint_and_increase_sell_amount"),
        mint_and_increase_sell_amount_mock_return,
        1,
    );
    ticket_master_dispatcher.start_token_distribution();

    // Verify distribution started
    assert(ticket_master_dispatcher.get_position_token_id() == position_id, 'Position not created');

    let actual_distribution_end_time = ticket_master_dispatcher.get_distribution_end_time();
    let end_time_delta = if actual_distribution_end_time > DISTRIBUTION_END_TIME {
        actual_distribution_end_time - DISTRIBUTION_END_TIME
    } else {
        DISTRIBUTION_END_TIME - actual_distribution_end_time
    };

    assert!(
        end_time_delta * 200 <= DISTRIBUTION_END_TIME + actual_distribution_end_time,
        "End time delta more than 1% of end time provided to constructor. Provided: {}, Actual: {}",
        DISTRIBUTION_END_TIME,
        actual_distribution_end_time,
    );
    assert(ticket_master_dispatcher.get_token_distribution_rate() > 0, 'Rate should be set');

    // Step 5: Claim proceeds
    // Note: In a real scenario, this would update the reward rate
    // but our mock setup may not fully simulate the reward token purchase
    mock_call(
        MOCK_POSITIONS_ADDRESS,
        selector!("withdraw_proceeds_from_sale_to_self"),
        0_u128, // No proceeds yet
        1,
    );
    mock_call(
        MOCK_POSITIONS_ADDRESS, selector!("increase_sell_amount"), 0_u128, // No rate increase
        1,
    );
}
