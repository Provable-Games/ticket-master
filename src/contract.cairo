#[starknet::contract]
pub mod TicketMaster {
    use core::array::ArrayTrait;
    use core::cmp::max;
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::num::traits::Zero;
    use core::poseidon::PoseidonTrait;
    use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use ekubo::interfaces::erc20::IERC20Dispatcher as IERC20DispatcherEkubo;
    use ekubo::interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use ekubo::interfaces::extensions::twamm::OrderKey;
    use ekubo::interfaces::positions::{IPositionsDispatcher, IPositionsDispatcherTrait};
    use ekubo::interfaces::token_registry::{
        ITokenRegistryDispatcher, ITokenRegistryDispatcherTrait,
    };
    use ekubo::types::i129::i129;
    use ekubo::types::keys::PoolKey;
    use ekubo_oracle_extension::oracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_token::erc20::ERC20Component;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_contract_address};
    use ticket_master::constants::{
        BIPS_BASIS, ERC20_UNIT, Errors, TWAMM_BOUNDS, TWAMM_TICK_SPACING, USDC_TOKEN_CONTRACT,
    };
    use ticket_master::interfaces::{BuybackOrderConfig, ITicketMaster};
    use ticket_master::utils::get_max_twamm_duration;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        pub erc20: ERC20Component::Storage,
        #[substorage(v0)]
        pub ownable: OwnableComponent::Storage,
        pub core_dispatcher: ICoreDispatcher,
        pub buyback_token: ContractAddress,
        pub buyback_rate: u128,
        pub buyback_order_key_counter: u128,
        pub buyback_order_key_bookmark: u128,
        pub buyback_order_key_end_time: Map<u128, u64>,
        pub distribution_end_time: u64,
        pub distribution_pool_fee: u128,
        pub distribution_initial_tick: i129,
        pub low_issuance_mode_active: bool,
        pub extension_address: ContractAddress,
        pub payment_token: ContractAddress,
        pub pool_id: u256,
        pub positions_dispatcher: IPositionsDispatcher,
        pub position_nft_address: ContractAddress,
        pub position_token_id: u64,
        pub registry_dispatcher: ITokenRegistryDispatcher,
        pub oracle_address: IOracleDispatcher,
        pub issuance_reduction_price_x128: u256,
        pub issuance_reduction_price_duration: u64,
        pub issuance_reduction_bips: u128,
        pub token_distribution_rate: u128,
        pub deployment_state: u8, // State machine: 0=initial, 1=pool_initialized, 2=liquidity_provided, 3=distribution_started
        pub tokens_for_distribution: u256, // Tokens to mint for TWAMM distribution
        pub treasury_address: ContractAddress,
        pub velords_address: ContractAddress,
        pub buyback_order_config: BuybackOrderConfig,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    /// @notice Initializes the TicketMaster contract
    /// @param owner The owner of the contract
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param total_supply The total supply of tokens to mint
    /// @param distribution_pool_fee The fee for the distribution pool
    /// @param payment_token The address of the token used for payments
    /// @param buyback_token The address of the token to be purchased with proceeds
    /// @param core_address The address of the Ekubo core contract
    /// @param positions_address The address of the Ekubo positions contract
    /// @param extension_address The address of the Ekubo extension contract
    /// @param registry_address The address of the Ekubo registry contract
    /// @param oracle_address The address of the Ekubo oracle contract
    /// @param velords_address The address that receives the veLords proceeds share
    /// @param position_nft_address The address of the ERC721 contract that minted the distribution
    /// position token
    /// @param issuance_reduction_price_x128 The 3-day average price threshold (Q128) that triggers
    /// a lower issuance rate
    /// @param issuance_reduction_price_duration The duration of the issuance reduction price
    /// @param issuance_reduction_bips The issuance reduction expressed in basis points (out of
    /// 10,000)
    /// @param treasury_address The address of the treasury
    /// @param recipients The addresses of the recipients of the tokens
    /// @param amounts The amounts of tokens to mint to the recipients
    /// @param distribution_end_time The end time of the token distribution
    /// @param buyback_order_config The configuration for the buyback orders
    #[constructor]
    fn constructor(
        ref self: ContractState,
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
    ) {
        // Validate constructor parameters
        let zero_address = 0.try_into().unwrap();
        assert(payment_token != zero_address, 'Invalid payment token');
        assert(buyback_token != zero_address, 'Invalid reward token');
        assert(core_address != zero_address, 'Invalid core address');
        assert(positions_address != zero_address, 'Invalid positions address');
        assert(position_nft_address != zero_address, 'Invalid positions NFT address');
        assert(extension_address != zero_address, 'Invalid extension address');
        assert(registry_address != zero_address, 'Invalid registry address');
        assert(oracle_address != zero_address, 'Invalid oracle address');
        assert(velords_address != zero_address, 'Invalid veLords address');
        assert(treasury_address != zero_address, 'Invalid treasury address');
        assert(total_supply > 0, 'Invalid total supply');

        // Validate recipients and amounts arrays
        let recipients_len = recipients.len();
        let amounts_len = amounts.len();
        assert(recipients_len == amounts_len, 'Arrays length mismatch');

        let current_time = starknet::get_block_timestamp();
        assert!(distribution_end_time > current_time, "End time must be greater than now");

        // verify end time is not greater than max duration supported by ekubo twamm
        let max_duration = get_max_twamm_duration();
        let max_end_time = current_time + max_duration;
        assert(distribution_end_time <= max_end_time, Errors::END_TIME_EXCEEDS_MAX);

        // init erc20
        self.erc20.initializer(name, symbol);
        self.ownable.initializer(owner);

        // store constructor params for getters
        self.payment_token.write(payment_token);
        self.buyback_token.write(buyback_token);
        self.core_dispatcher.write(ICoreDispatcher { contract_address: core_address });
        self
            .positions_dispatcher
            .write(IPositionsDispatcher { contract_address: positions_address });
        self.position_nft_address.write(position_nft_address);
        self.extension_address.write(extension_address);
        self.distribution_pool_fee.write(distribution_pool_fee);
        self
            .registry_dispatcher
            .write(ITokenRegistryDispatcher { contract_address: registry_address });
        self.treasury_address.write(treasury_address);
        self.velords_address.write(velords_address);
        self.oracle_address.write(IOracleDispatcher { contract_address: oracle_address });
        assert(issuance_reduction_bips < BIPS_BASIS, Errors::INVALID_REDUCTION_BIPS);
        self.issuance_reduction_price_x128.write(issuance_reduction_price_x128);
        self.issuance_reduction_price_duration.write(issuance_reduction_price_duration);
        self.issuance_reduction_bips.write(issuance_reduction_bips);
        self.low_issuance_mode_active.write(false);
        self.distribution_end_time.write(distribution_end_time);
        self.buyback_order_config.write(buyback_order_config);

        // Distribute tokens to initial recipients
        let total_distributed = _distribute_initial_tokens(
            ref self, recipients, amounts, total_supply, zero_address,
        );

        let remaining_supply = total_supply.into() - total_distributed;

        // register token with Ekubo registry
        _register_token(ref self);

        // Store tokens remaining for distribution
        self.tokens_for_distribution.write(remaining_supply - ERC20_UNIT.into());
    }

    #[abi(embed_v0)]
    impl TicketMasterImpl of ITicketMaster<ContractState> {
        /// @notice Initializes the TWAMM pools for the distribution and buyback tokens
        /// @dev This function should be called as step 1 after deployment
        /// @param distribution_initial_tick The initial tick for the distribution pool
        /// @return u256 The ID of the distribution pool
        fn init_distribution_pool(
            ref self: ContractState, distribution_initial_tick: i129,
        ) -> u256 {
            self.ownable.assert_only_owner();
            assert(self.deployment_state.read() == 0, 'Pool already initialized');

            let distribution_pool_id = _init_distribution_pool(ref self, distribution_initial_tick);

            self.distribution_initial_tick.write(distribution_initial_tick);
            self.pool_id.write(distribution_pool_id);
            self.deployment_state.write(1); // pool initialized

            distribution_pool_id
        }

        /// @notice Provides initial liquidity to the pool
        /// @dev This function should be called as step 2 after initializing the pool
        /// @dev Can only be called once when deployment_state is 1
        /// @dev The caller must have payment tokens and this contract will mint our tokens
        /// @param payment_token_amount The amount of payment tokens to provide
        /// @param dungeon_ticket_amount The amount of our tokens to provide
        /// @param minimum_liquidity The minimum liquidity to provide
        /// @return u64 The ID of the position token
        /// @return u128 The amount of liquidity provided
        /// @return u256 The amount of payment tokens cleared
        /// @return u256 The amount of dungeon tickets cleared
        fn provide_initial_liquidity(
            ref self: ContractState,
            payment_token_amount: u128,
            dungeon_ticket_amount: u128,
            minimum_liquidity: u128,
        ) -> (u64, u128, u256, u256) {
            self.ownable.assert_only_owner();
            // Check current state
            let current_state = self.deployment_state.read();
            assert(current_state == 1, 'Wrong state for liquidity');

            // Ensure pool is initialized
            assert(self.pool_id.read() != 0, Errors::DISTRIBUTION_POOL_NOT_INITIALIZED);

            // Sanity check token amounts
            assert(payment_token_amount > 0, 'init pay amt zero');
            assert(dungeon_ticket_amount > 0, 'init our amt zero');

            // Ensure we have enough tokens for distribution
            let tokens_for_distribution = self.tokens_for_distribution.read();
            let dungeon_ticket_amount_u256: u256 = dungeon_ticket_amount.into();
            assert!(tokens_for_distribution >= dungeon_ticket_amount_u256, "init liq too large");

            // Step 1: Transfer payment tokens from caller to Ekubo's Positions contract
            let payment_token = self.payment_token.read();
            let positions_address = self.positions_dispatcher.read().contract_address;
            let caller = starknet::get_caller_address();
            let payment_token_dispatcher = IERC20Dispatcher { contract_address: payment_token };
            let payment_amount_u256: u256 = payment_token_amount.into();
            payment_token_dispatcher.transfer_from(caller, positions_address, payment_amount_u256);

            // Step 2: Mint new tokens directly to Ekubo's Positions contract
            self.erc20.mint(positions_address, dungeon_ticket_amount_u256);

            // Step 3: Create new position using distribution pool key
            let pool_key = _get_distribution_pool_key(@self);
            let (position_id, liquidity, cleared_payment, cleared_our) = self
                .positions_dispatcher
                .read()
                .mint_and_deposit_and_clear_both(pool_key, TWAMM_BOUNDS, minimum_liquidity);

            // Transition to state 2 == liquidity provided
            self.deployment_state.write(2);

            // update the amount of tokens for distribution
            let tokens_for_distribution = self.tokens_for_distribution.read();
            let remaining_supply = tokens_for_distribution - dungeon_ticket_amount_u256;
            self.tokens_for_distribution.write(remaining_supply);

            // Return the position ID and cleared amounts
            (position_id, liquidity, cleared_payment, cleared_our)
        }

        /// @notice Distributes the entire token supply using a TWAP order
        /// @dev This function should be called as step 3 after providing liquidity
        /// @dev Can only be called once when deployment_state is 2
        /// @return u64 The ID of the position token
        /// @return u128 The amount of sale rate
        fn start_token_distribution(ref self: ContractState) -> (u64, u128) {
            // Check current state
            let current_state = self.deployment_state.read();
            assert(current_state == 2, 'Must provide liquidity first');

            let (position_token_id, sale_rate) = _start_token_distribution(ref self);

            // store position token id and sale rate
            self.position_token_id.write(position_token_id);
            self.token_distribution_rate.write(sale_rate);

            // Transition to state 3 == distribution started
            self.deployment_state.write(3);

            (position_token_id, sale_rate)
        }

        /// @notice Claims proceeds from selling tokens and uses them to buy the game token
        /// @dev This function can be called periodically to reinvest proceeds from all positions
        /// @return u128 The amount of proceeds claimed
        fn claim_proceeds(ref self: ContractState) -> u128 {
            assert(self.deployment_state.read() == 3, Errors::DISTRIBUTION_NOT_STARTED);
            assert(self.pool_id.read() != 0, Errors::DISTRIBUTION_POOL_NOT_INITIALIZED);
            assert(self.position_token_id.read() != 0, Errors::TOKEN_DISTRIBUTION_NOT_STARTED);

            let positions_dispatcher = self.positions_dispatcher.read();
            let position_token_id = self.position_token_id.read();
            let order_key = _get_distribution_order_key(@self);

            let proceeds = positions_dispatcher
                .withdraw_proceeds_from_sale_to_self(position_token_id, order_key);
            assert(proceeds > 0, 'No proceeds available to claim');
            proceeds
        }

        /// @notice Distributes the proceeds from selling tokens to the veLords and buybacks
        /// @dev This function should be called periodically to distribute proceeds
        /// @param start_time The start time of the order
        /// @param end_time The end time of the order
        fn distribute_proceeds(ref self: ContractState, start_time: u64, end_time: u64) {
            assert(self.deployment_state.read() == 3, Errors::DISTRIBUTION_NOT_STARTED);
            assert(self.pool_id.read() != 0, Errors::DISTRIBUTION_POOL_NOT_INITIALIZED);
            assert(self.position_token_id.read() != 0, Errors::TOKEN_DISTRIBUTION_NOT_STARTED);

            let buyback_order_config = _get_buyback_order_config(@self);

            let current_time = starknet::get_block_timestamp();
            assert(end_time > start_time, 'Invalid start or end time');
            let actual_start = max(current_time, start_time);
            assert(end_time > actual_start, 'End time expired');
            let duration = end_time - actual_start;
            assert(duration >= buyback_order_config.min_duration, 'Duration too short');
            assert(duration <= buyback_order_config.max_duration, 'Duration too long');
            // Enforce the order starts within the min/max delay
            if (buyback_order_config.min_delay.is_non_zero()) {
                assert(
                    start_time > current_time
                        && (start_time - current_time) >= buyback_order_config.min_delay,
                    'Order must start > min delay',
                );
            }
            // if it starts in the future, make sure it's not too far in the future
            if (start_time > current_time) {
                assert(
                    (start_time - current_time) < buyback_order_config.max_delay,
                    'Order must start < max delay',
                );
            }

            // get the amount of payment tokens in the contract
            let payment_token = self.payment_token.read();
            let payment_token_dispatcher = IERC20Dispatcher { contract_address: payment_token };
            let proceeds = payment_token_dispatcher.balance_of(get_contract_address());

            assert(proceeds > 0, 'No proceeds available');

            let amount_to_velords = proceeds / 5;
            let amount_to_buybacks = proceeds - amount_to_velords;

            let velords_address = self.velords_address.read();
            // send 20% to veLords
            payment_token_dispatcher.transfer(velords_address, amount_to_velords);

            // use the remainder to buy back the reward token via DCA
            // start by moving the remaining proceeds to positions contract
            let positions_dispatcher = self.positions_dispatcher.read();
            payment_token_dispatcher
                .transfer(positions_dispatcher.contract_address, amount_to_buybacks);

            let position_token_id = self.position_token_id.read();
            let order_key = _get_buyback_order_key(@self, start_time, end_time);
            let sale_rate_increase = positions_dispatcher
                .increase_sell_amount(
                    position_token_id, order_key, amount_to_buybacks.try_into().unwrap(),
                );

            // Update the rewards distribution rate
            let previous_sale_rate = self.buyback_rate.read();
            let new_sale_rate = previous_sale_rate + sale_rate_increase;
            self.buyback_rate.write(new_sale_rate);

            // get current number of buyback order keys
            let order_index = self.buyback_order_key_counter.read();

            // store order end time for later retrieval
            self.buyback_order_key_end_time.write(order_index, order_key.end_time);

            // increment counter and save counter
            self.buyback_order_key_counter.write(order_index + 1);
        }

        /// @notice Claims the proceeds from selling tokens and distributes them to the veLords and
        /// @param limit The maximum number of buyback orders to claim
        /// @dev If limit is 0, all buyback orders will be claimed
        /// @return u128 The amount of proceeds claimed
        /// @return u128 The new bookmark
        fn claim_and_distribute_buybacks(ref self: ContractState, limit: u16) -> (u128, u128) {
            let position_token_id = self.position_token_id.read();
            assert(position_token_id != 0, Errors::TOKEN_DISTRIBUTION_NOT_STARTED);

            // get number of buyback orders
            let buyback_order_count = self.buyback_order_key_counter.read();

            // get buyback order bookmark
            let starting_bookmark = self.buyback_order_key_bookmark.read();

            // assert the number of buyback orders is greater than the bookmark
            assert(starting_bookmark < buyback_order_count, 'All buyback orders claimed');

            // get the max number of orders to claim
            // if limit is 0, claim all orders
            let max_index = if limit == 0_u16 {
                buyback_order_count
            } else {
                // otherwise, limit the number of orders
                let candidate = starting_bookmark + limit.into();
                if candidate < buyback_order_count {
                    candidate
                } else {
                    buyback_order_count
                }
            };

            // get treasury address
            let treasury_address = _get_treasury_address(@self);

            // iterate from bookmark to the capped buyback order index
            let mut order_number = starting_bookmark;
            let mut total_proceeds = 0;
            let positions_dispatcher = self.positions_dispatcher.read();
            let current_time = starknet::get_block_timestamp();

            while order_number < max_index {
                // get the end time of the order
                let order_key_end_time = self.buyback_order_key_end_time.read(order_number);

                // if the order is still active, break
                if order_key_end_time > current_time {
                    // orders are sorted by end time so no need to check further
                    break;
                }

                let order_key = _retrieve_buyback_order_key(@self, order_key_end_time);

                // otherwise, withdraw proceeds from the order
                total_proceeds += positions_dispatcher
                    .withdraw_proceeds_from_sale_to(position_token_id, order_key, treasury_address);
                order_number += 1;
            }

            // assert we claimed non-zero proceeds
            assert!(total_proceeds > 0, "No proceeds available to claim");

            // save new bookmark
            self.buyback_order_key_bookmark.write(order_number);

            // return total proceeds claimed and new bookmark
            (total_proceeds, order_number)
        }

        /// @notice Reduces ticket issuance rate when pricing falls below set threshold
        fn enable_low_issuance_mode(ref self: ContractState) -> u128 {
            assert(self.deployment_state.read() == 3, Errors::DISTRIBUTION_NOT_STARTED);
            assert(self.position_token_id.read() != 0, Errors::TOKEN_DISTRIBUTION_NOT_STARTED);
            assert(!self.low_issuance_mode_active.read(), Errors::LOW_ISSUANCE_ALREADY_ACTIVE);

            let reduction_price = self.issuance_reduction_price_x128.read();
            assert(reduction_price > 0, Errors::REDUCTION_PRICE_NOT_SET);

            let reduction_bips = self.issuance_reduction_bips.read();
            assert(reduction_bips > 0, Errors::REDUCTION_BIPS_NOT_SET);

            let reduction_duration = self.issuance_reduction_price_duration.read();
            assert(reduction_duration > 0, Errors::REDUCTION_DURATION_NOT_SET);

            let average_price = _get_dungeon_ticket_price_x128(@self, reduction_duration);
            assert(average_price < reduction_price, Errors::PRICE_NOT_BELOW_REDUCTION_THRESHOLD);

            let current_rate = self.token_distribution_rate.read();
            assert(current_rate > 0, Errors::TOKEN_DISTRIBUTION_NOT_STARTED);

            let rate_delta = (current_rate * reduction_bips) / BIPS_BASIS;
            assert(rate_delta > 0, Errors::REDUCTION_RATE_TOO_SMALL);
            assert(rate_delta <= current_rate, Errors::REDUCTION_RATE_TOO_LARGE);

            let positions_dispatcher = self.positions_dispatcher.read();
            let position_token_id = self.position_token_id.read();
            let order_key = _get_distribution_order_key(@self);

            let returned_tokens = positions_dispatcher
                .decrease_sale_rate_to_self(position_token_id, order_key, rate_delta);
            assert(returned_tokens > 0, Errors::LOW_ISSUANCE_TOKENS_MISSING);

            self.token_distribution_rate.write(current_rate - rate_delta);
            self.low_issuance_mode_active.write(true);

            returned_tokens
        }

        /// @notice Restores the ticket issuance rate when pricing conditions recover
        fn disable_low_issuance_mode(ref self: ContractState) {
            assert(self.low_issuance_mode_active.read(), Errors::LOW_ISSUANCE_NOT_ACTIVE);

            let reduction_price = self.issuance_reduction_price_x128.read();
            assert(reduction_price > 0, Errors::REDUCTION_PRICE_NOT_SET);

            let reduction_duration = self.issuance_reduction_price_duration.read();
            assert(reduction_duration > 0, Errors::REDUCTION_DURATION_NOT_SET);

            let average_price = _get_dungeon_ticket_price_x128(@self, reduction_duration);
            assert(average_price > reduction_price, Errors::PRICE_NOT_ABOVE_REDUCTION_THRESHOLD);

            // get all dungeon tickets in the contract
            let tickets_in_contract = self.erc20.balance_of(get_contract_address());
            assert(tickets_in_contract > 0, Errors::NO_TICKETS_AVAILABLE);

            // transfer available tickets to positions contract
            let positions_dispatcher = self.positions_dispatcher.read();
            self
                .erc20
                ._transfer(
                    get_contract_address(),
                    positions_dispatcher.contract_address,
                    tickets_in_contract,
                );

            // increase the sale rate of the position token
            let previous_order_key = _get_distribution_order_key(@self);
            let position_token_id = self.position_token_id.read();
            let sale_rate_increase = positions_dispatcher
                .increase_sell_amount(
                    position_token_id, previous_order_key, tickets_in_contract.try_into().unwrap(),
                );

            // update the token distribution rate
            let current_rate = self.token_distribution_rate.read();
            self.token_distribution_rate.write(current_rate + sale_rate_increase);

            // disable low issuance mode
            self.low_issuance_mode_active.write(false);
        }

        /// @notice Sets the reduction duration for the low issuance mode
        /// @param duration The reduction duration for the low issuance mode
        fn set_issuance_reduction_price_duration(ref self: ContractState, duration: u64) {
            self.ownable.assert_only_owner();
            assert(duration > 0, Errors::REDUCTION_DURATION_NOT_SET);
            self.issuance_reduction_price_duration.write(duration);
        }

        /// @notice Sets the reduction price for the low issuance mode
        /// @param price The reduction price for the low issuance mode
        fn set_issuance_reduction_price_x128(ref self: ContractState, price: u256) {
            self.ownable.assert_only_owner();
            assert(price > 0, Errors::REDUCTION_PRICE_NOT_SET);
            self.issuance_reduction_price_x128.write(price);
        }

        /// @notice Sets the reduction bips for the low issuance mode
        /// @param bips The reduction bips for the low issuance mode
        fn set_issuance_reduction_bips(ref self: ContractState, bips: u128) {
            self.ownable.assert_only_owner();
            assert(bips > 0, Errors::REDUCTION_BIPS_NOT_SET);
            assert(bips <= BIPS_BASIS, Errors::REDUCTION_BIPS_TOO_LARGE);
            self.issuance_reduction_bips.write(bips);
        }

        /// @notice Sets the configuration for the buyback orders
        /// @param config The configuration for the buyback orders
        fn set_buyback_order_config(ref self: ContractState, config: BuybackOrderConfig) {
            self.ownable.assert_only_owner();
            self.buyback_order_config.write(config);
        }

        /// @notice Sets the address of the treasury
        /// @param treasury_address The address of the treasury
        fn set_treasury_address(ref self: ContractState, treasury_address: ContractAddress) {
            self.ownable.assert_only_owner();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(treasury_address != zero_address, Errors::INVALID_RECIPIENT);

            self.treasury_address.write(treasury_address);
        }

        /// @notice Updates the veLords distribution recipient address
        /// @param velords_address The new veLords recipient address
        fn set_velords_address(ref self: ContractState, velords_address: ContractAddress) {
            self.ownable.assert_only_owner();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(velords_address != zero_address, Errors::INVALID_RECIPIENT);

            self.velords_address.write(velords_address);
        }

        /// @notice Transfers custody of the distribution position NFT to a new address
        /// @param recipient The address that will receive the NFT
        fn withdraw_position_token(ref self: ContractState, recipient: ContractAddress) {
            self.ownable.assert_only_owner();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(recipient != zero_address, Errors::INVALID_RECIPIENT);

            let position_token_id = self.position_token_id.read();
            assert(position_token_id != 0, Errors::TOKEN_DISTRIBUTION_NOT_STARTED);

            let nft_dispatcher = IERC721Dispatcher {
                contract_address: self.position_nft_address.read(),
            };

            nft_dispatcher
                .transfer_from(get_contract_address(), recipient, position_token_id.into());

            self.position_token_id.write(0);
        }

        fn withdraw_funds(ref self: ContractState, token_address: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();
            let token = IERC20Dispatcher { contract_address: token_address };
            token.transfer(self.ownable.Ownable_owner.read(), amount);
        }

        /// @notice Burns tokens from the caller's balance
        /// @param amount The number of tokens to burn
        fn burn(ref self: ContractState, amount: u256) {
            let caller = starknet::get_caller_address();
            self.erc20.burn(caller, amount);
        }

        /// @notice Burns tokens from the specified address
        /// @param from The address to burn tokens from
        /// @param amount The number of tokens to burn
        fn burn_from(ref self: ContractState, from: ContractAddress, amount: u256) {
            let caller = starknet::get_caller_address();
            self.erc20._spend_allowance(from, caller, amount);
            self.erc20.burn(from, amount);
        }

        /// @notice Returns the rate of the token distribution
        /// @return u128 The rate of the token distribution
        fn get_token_distribution_rate(self: @ContractState) -> u128 {
            _get_token_distribution_rate(self)
        }

        /// @notice Returns the rate of the buyback
        /// @return u128 The rate of the buyback
        fn get_buyback_rate(self: @ContractState) -> u128 {
            _get_buyback_rate(self)
        }

        /// @notice Returns the end time of the distribution
        /// @return u64 The end time of the distribution
        fn get_distribution_end_time(self: @ContractState) -> u64 {
            _get_distribution_end_time(self)
        }

        /// @notice Returns the key of the distribution order
        /// @return OrderKey The key of the distribution order
        fn get_distribution_order_key(self: @ContractState) -> OrderKey {
            _get_distribution_order_key(self)
        }

        /// @notice Returns the key of the distribution pool
        /// @return PoolKey The key of the distribution pool
        fn get_distribution_pool_key(self: @ContractState) -> PoolKey {
            _get_distribution_pool_key(self)
        }

        /// @notice Returns the reduction duration for the low issuance mode
        /// @return u64 The reduction duration for the low issuance mode
        fn get_issuance_reduction_price_duration(self: @ContractState) -> u64 {
            _get_issuance_reduction_price_duration(self)
        }

        /// @notice Returns the configured reduction price expressed in Q128
        fn get_issuance_reduction_price_x128(self: @ContractState) -> u256 {
            _get_issuance_reduction_price_x128(self)
        }

        /// @notice Returns whether the contract currently operates in low issuance mode
        fn is_low_issuance_mode(self: @ContractState) -> bool {
            _is_low_issuance_mode_active(self)
        }


        /// @notice Returns the configuration for the buyback orders
        /// @return BuybackOrderConfig The configuration for the buyback orders
        fn get_buyback_order_config(self: @ContractState) -> BuybackOrderConfig {
            _get_buyback_order_config(self)
        }

        /// @notice Returns the ID of the pool
        /// @return u256 The ID of the pool
        fn get_pool_id(self: @ContractState) -> u256 {
            _get_pool_id(self)
        }

        /// @notice Returns the ID of the position token
        /// @return u64 The ID of the position token
        fn get_position_token_id(self: @ContractState) -> u64 {
            _get_position_token_id(self)
        }

        /// @notice Returns the address of the payment token
        /// @return ContractAddress The address of the payment token
        fn get_payment_token(self: @ContractState) -> ContractAddress {
            _get_payment_token(self)
        }

        /// @notice Returns the address of the extension
        /// @return ContractAddress The address of the extension
        fn get_extension_address(self: @ContractState) -> ContractAddress {
            _get_extension_address(self)
        }

        /// @notice Returns the address of the buyback token
        /// @return ContractAddress The address of the buyback token
        fn get_buyback_token(self: @ContractState) -> ContractAddress {
            _get_buyback_token(self)
        }

        /// @notice Returns the address of the core dispatcher
        /// @return ICoreDispatcher The address of the core dispatcher
        fn get_core_dispatcher(self: @ContractState) -> ICoreDispatcher {
            _get_core_dispatcher(self)
        }

        /// @notice Returns the address of the positions dispatcher
        /// @return IPositionsDispatcher The address of the positions dispatcher
        fn get_positions_dispatcher(self: @ContractState) -> IPositionsDispatcher {
            _get_positions_dispatcher(self)
        }

        /// @notice Returns the address of the registry dispatcher
        /// @return ITokenRegistryDispatcher The address of the registry dispatcher
        fn get_registry_dispatcher(self: @ContractState) -> ITokenRegistryDispatcher {
            _get_registry_dispatcher(self)
        }

        /// @notice Returns the address of the oracle dispatcher
        /// @return IOracleDispatcher The address of the oracle dispatcher
        fn get_oracle_address(self: @ContractState) -> IOracleDispatcher {
            _get_oracle_address(self)
        }

        /// @notice Returns the initial tick of the distribution pool
        /// @return i129 The initial tick of the distribution pool
        fn get_distribution_initial_tick(self: @ContractState) -> i129 {
            _get_distribution_initial_tick(self)
        }

        /// @notice Returns the distribution pool fee
        /// @return u128 The distribution pool fee
        fn get_distribution_pool_fee(self: @ContractState) -> u128 {
            _get_distribution_pool_fee(self)
        }

        /// @notice Returns the number of tokens for distribution
        /// @return u256 The number of tokens for distribution
        fn get_tokens_for_distribution(self: @ContractState) -> u256 {
            _get_tokens_for_distribution(self)
        }

        /// @notice Returns the hash of the distribution pool key
        /// @return felt252 The hash of the distribution pool key
        fn get_distribution_pool_key_hash(self: @ContractState) -> felt252 {
            _get_distribution_pool_key_hash(self)
        }

        /// @notice Returns whether the pool has been initialized
        /// @return bool True if pool is initialized, false otherwise
        fn is_pool_initialized(self: @ContractState) -> bool {
            self.pool_id.read() != 0
        }

        /// @notice Returns the current deployment state
        /// @return u8 The deployment state (0=initial, 1=pool_initialized, 2=liquidity_provided,
        /// 3=distribution_started)
        fn get_deployment_state(self: @ContractState) -> u8 {
            self.deployment_state.read()
        }

        /// @notice Returns the price of the dungeon ticket token over the last duration
        /// @param duration The duration to get the price over
        /// @return u256 The price of the dungeon ticket token over the last duration
        fn get_dungeon_ticket_price_x128(self: @ContractState, duration: u64) -> u256 {
            _get_dungeon_ticket_price_x128(self, duration)
        }
        /// @notice Returns the address of the treasury
        /// @return ContractAddress The address of the treasury
        fn get_treasury_address(self: @ContractState) -> ContractAddress {
            _get_treasury_address(self)
        }

        /// @notice Returns the address that receives the veLords share
        /// @return ContractAddress The veLords recipient address
        fn get_velords_address(self: @ContractState) -> ContractAddress {
            _get_velords_address(self)
        }

        fn get_buyback_order_key_counter(self: @ContractState) -> u128 {
            _get_buyback_order_key_counter(self)
        }

        fn get_buyback_order_key_bookmark(self: @ContractState) -> u128 {
            _get_buyback_order_key_bookmark(self)
        }

        fn get_buyback_order_key_end_time(self: @ContractState, index: u128) -> u64 {
            _get_buyback_order_key_end_time(self, index)
        }

        /// @notice Returns the address of the position NFT contract
        /// @return ContractAddress The address of the position NFT contract
        fn get_position_nft_address(self: @ContractState) -> ContractAddress {
            _get_position_nft_address(self)
        }

        /// @notice Returns the issuance reduction basis points
        /// @return u128 The issuance reduction basis points
        fn get_issuance_reduction_bips(self: @ContractState) -> u128 {
            _get_issuance_reduction_bips(self)
        }

        /// @notice Returns the key of the buyback pool
        /// @return PoolKey The key of the buyback pool
        fn get_buyback_pool_key(self: @ContractState) -> PoolKey {
            _get_buyback_pool_key(self)
        }

        /// @notice Returns the hash of the buyback pool key
        /// @return felt252 The hash of the buyback pool key
        fn get_buyback_pool_key_hash(self: @ContractState) -> felt252 {
            _get_buyback_pool_key_hash(self)
        }

        /// @notice Returns the number of unclaimed buyback orders
        /// @return u128 The number of buyback orders that have not been claimed yet
        fn get_unclaimed_buyback_orders_count(self: @ContractState) -> u128 {
            let counter = self.buyback_order_key_counter.read();
            let bookmark = self.buyback_order_key_bookmark.read();
            counter - bookmark
        }

        /// @notice Returns whether this token is token0 in the distribution pool
        /// @return bool True if this token is token0, false if payment token is token0
        fn is_token0(self: @ContractState) -> bool {
            _is_token0(self)
        }

        /// @notice Constructs a buyback order key for the given time parameters
        /// @param start_time The start time of the buyback order
        /// @param end_time The end time of the buyback order
        /// @return OrderKey The constructed buyback order key
        fn get_buyback_order_key(self: @ContractState, start_time: u64, end_time: u64) -> OrderKey {
            _get_buyback_order_key(self, start_time, end_time)
        }
    }

    #[inline(always)]
    fn _get_token_distribution_rate(self: @ContractState) -> u128 {
        self.token_distribution_rate.read()
    }

    #[inline(always)]
    fn _get_buyback_rate(self: @ContractState) -> u128 {
        self.buyback_rate.read()
    }

    #[inline(always)]
    fn _get_distribution_end_time(self: @ContractState) -> u64 {
        self.distribution_end_time.read()
    }

    #[inline(always)]
    fn _get_buyback_order_config(self: @ContractState) -> BuybackOrderConfig {
        self.buyback_order_config.read()
    }

    #[inline(always)]
    fn _get_buyback_order_fee(self: @ContractState) -> u128 {
        self.buyback_order_config.read().fee
    }

    #[inline(always)]
    fn _get_pool_id(self: @ContractState) -> u256 {
        self.pool_id.read()
    }

    #[inline(always)]
    fn _get_position_token_id(self: @ContractState) -> u64 {
        self.position_token_id.read()
    }

    #[inline(always)]
    fn _get_payment_token(self: @ContractState) -> ContractAddress {
        self.payment_token.read()
    }

    #[inline(always)]
    fn _get_extension_address(self: @ContractState) -> ContractAddress {
        self.extension_address.read()
    }

    #[inline(always)]
    fn _get_buyback_token(self: @ContractState) -> ContractAddress {
        self.buyback_token.read()
    }

    #[inline(always)]
    fn _get_core_dispatcher(self: @ContractState) -> ICoreDispatcher {
        self.core_dispatcher.read()
    }

    #[inline(always)]
    fn _get_positions_dispatcher(self: @ContractState) -> IPositionsDispatcher {
        self.positions_dispatcher.read()
    }

    #[inline(always)]
    fn _get_registry_dispatcher(self: @ContractState) -> ITokenRegistryDispatcher {
        self.registry_dispatcher.read()
    }

    #[inline(always)]
    fn _get_oracle_address(self: @ContractState) -> IOracleDispatcher {
        self.oracle_address.read()
    }

    #[inline(always)]
    fn _get_issuance_reduction_price_x128(self: @ContractState) -> u256 {
        self.issuance_reduction_price_x128.read()
    }

    #[inline(always)]
    fn _get_distribution_initial_tick(self: @ContractState) -> i129 {
        self.distribution_initial_tick.read()
    }

    #[inline(always)]
    fn _get_distribution_pool_fee(self: @ContractState) -> u128 {
        self.distribution_pool_fee.read()
    }

    #[inline(always)]
    fn _get_tokens_for_distribution(self: @ContractState) -> u256 {
        self.tokens_for_distribution.read()
    }

    #[inline(always)]
    fn _is_low_issuance_mode_active(self: @ContractState) -> bool {
        self.low_issuance_mode_active.read()
    }

    fn _get_dungeon_ticket_price_x128(self: @ContractState, duration: u64) -> u256 {
        let oracle_dispatcher = self.oracle_address.read();
        oracle_dispatcher
            .get_price_x128_over_last(
                starknet::get_contract_address(), USDC_TOKEN_CONTRACT, duration,
            )
    }

    #[inline(always)]
    fn _get_treasury_address(self: @ContractState) -> ContractAddress {
        self.treasury_address.read()
    }

    #[inline(always)]
    fn _get_velords_address(self: @ContractState) -> ContractAddress {
        self.velords_address.read()
    }

    #[inline(always)]
    fn _get_buyback_order_key_counter(self: @ContractState) -> u128 {
        self.buyback_order_key_counter.read()
    }

    #[inline(always)]
    fn _get_buyback_order_key_bookmark(self: @ContractState) -> u128 {
        self.buyback_order_key_bookmark.read()
    }

    #[inline(always)]
    fn _get_buyback_order_key_end_time(self: @ContractState, index: u128) -> u64 {
        self.buyback_order_key_end_time.read(index)
    }

    #[inline(always)]
    fn _get_position_nft_address(self: @ContractState) -> ContractAddress {
        self.position_nft_address.read()
    }

    #[inline(always)]
    fn _get_issuance_reduction_bips(self: @ContractState) -> u128 {
        self.issuance_reduction_bips.read()
    }

    #[inline(always)]
    fn _get_issuance_reduction_price_duration(self: @ContractState) -> u64 {
        self.issuance_reduction_price_duration.read()
    }

    /// @notice Computes the hash of the buyback pool key
    /// @return felt252 The hash of the buyback pool key
    fn _get_buyback_pool_key_hash(self: @ContractState) -> felt252 {
        let pool_key = _get_buyback_pool_key(self);
        _compute_pool_key_hash(pool_key)
    }

    /// @notice Checks if this token is token0 in the pool (has lower address than payment token)
    /// @return bool True if this token is token0, false if payment token is token0
    fn _is_token0(self: @ContractState) -> bool {
        let this_token = get_contract_address();
        let payment_token = _get_payment_token(self);
        this_token < payment_token
    }

    /// @notice Creates a PoolKey for the distribution token pool
    /// @return PoolKey The key for the distribution token pool
    fn _get_distribution_pool_key(self: @ContractState) -> PoolKey {
        if _is_token0(self) {
            PoolKey {
                token0: get_contract_address(),
                token1: _get_payment_token(self),
                fee: _get_distribution_pool_fee(self),
                tick_spacing: TWAMM_TICK_SPACING,
                extension: _get_extension_address(self),
            }
        } else {
            PoolKey {
                token0: _get_payment_token(self),
                token1: get_contract_address(),
                fee: _get_distribution_pool_fee(self),
                tick_spacing: TWAMM_TICK_SPACING,
                extension: _get_extension_address(self),
            }
        }
    }

    fn _get_buyback_pool_key(self: @ContractState) -> PoolKey {
        let payment_token = _get_payment_token(self);
        let buyback_token = _get_buyback_token(self);
        if buyback_token < payment_token {
            PoolKey {
                token0: buyback_token,
                token1: payment_token,
                fee: _get_buyback_order_fee(self),
                tick_spacing: TWAMM_TICK_SPACING,
                extension: _get_extension_address(self),
            }
        } else {
            PoolKey {
                token0: payment_token,
                token1: buyback_token,
                fee: _get_buyback_order_fee(self),
                tick_spacing: TWAMM_TICK_SPACING,
                extension: _get_extension_address(self),
            }
        }
    }

    /// @notice Computes the hash of the distribution pool key
    /// @return felt252 The hash of the distribution pool key
    fn _get_distribution_pool_key_hash(self: @ContractState) -> felt252 {
        let pool_key = _get_distribution_pool_key(self);
        _compute_pool_key_hash(pool_key)
    }

    /// @notice Creates an OrderKey for the distribution token order
    /// @return OrderKey The key for the distribution token order
    fn _get_distribution_order_key(self: @ContractState) -> OrderKey {
        OrderKey {
            sell_token: get_contract_address(),
            buy_token: _get_payment_token(self),
            fee: _get_distribution_pool_fee(self),
            start_time: 0, // start immediately
            end_time: _get_distribution_end_time(self),
        }
    }

    /// @notice Creates an OrderKey for purchasing tokens with proceeds
    /// @return OrderKey The key for the purchase token order
    /// @param start_time The start time of the order
    /// @param end_time The end time of the order
    fn _get_buyback_order_key(self: @ContractState, start_time: u64, end_time: u64) -> OrderKey {
        OrderKey {
            sell_token: _get_payment_token(self),
            buy_token: _get_buyback_token(self),
            fee: _get_buyback_order_fee(self),
            start_time,
            end_time,
        }
    }

    /// @notice Retrieves a buyback order key
    /// @param end_time The end time of the order
    /// @return OrderKey The key for the buyback order
    fn _retrieve_buyback_order_key(self: @ContractState, end_time: u64) -> OrderKey {
        OrderKey {
            sell_token: _get_payment_token(self),
            buy_token: _get_buyback_token(self),
            fee: _get_buyback_order_fee(self),
            start_time: 0,
            end_time,
        }
    }

    /// @notice Initializes an Ekubo pool for distributing the token supply via a TWAMM order
    /// @dev This function is called internally by provide_initial_liquidity
    /// @param initial_tick The initial tick for the pool
    /// @return u256 The ID of the pool
    fn _init_distribution_pool(ref self: ContractState, initial_tick: i129) -> u256 {
        let core_dispatcher = self.core_dispatcher.read();
        let pool_key = _get_distribution_pool_key(@self);
        core_dispatcher.initialize_pool(pool_key, initial_tick)
    }

    /// @notice Converts a pool key to a u256
    /// @param pool_key The pool key to convert
    /// @return u256 The u256 representation of the pool key
    fn _pool_key_to_u256(pool_key: PoolKey) -> u256 {
        let hash = _compute_pool_key_hash(pool_key);
        hash.into()
    }

    /// @notice Computes the hash of a pool key
    /// @param pool_key The pool key to hash
    /// @return felt252 The hash of the pool key
    fn _compute_pool_key_hash(pool_key: PoolKey) -> felt252 {
        let mut state = PoseidonTrait::new();
        state = state.update_with(pool_key.token0);
        state = state.update_with(pool_key.token1);
        state = state.update_with(pool_key.fee);
        state = state.update_with(pool_key.tick_spacing);
        state = state.update_with(pool_key.extension);
        state.finalize()
    }

    /// @notice Distributes the entire token supply using a TWAP order
    /// @dev This function is called internally by start_token_distribution
    fn _start_token_distribution(ref self: ContractState) -> (u64, u128) {
        // State checks are now done in the public function
        assert(self.pool_id.read() != 0, Errors::DISTRIBUTION_POOL_NOT_INITIALIZED);

        // Mint the tokens to positions contract now, in the same transaction
        let positions_dispatcher = self.positions_dispatcher.read();
        let tokens_to_mint = self.tokens_for_distribution.read();

        // assert tokens for distribution is greater than 0
        assert!(tokens_to_mint > 0, "No tokens available for distribution");

        // mint tokens to ekubo positions contract
        self.erc20.mint(positions_dispatcher.contract_address, tokens_to_mint);

        // create order key for distribution
        let order_key = _get_distribution_order_key(@self);
        positions_dispatcher
            .mint_and_increase_sell_amount(order_key, tokens_to_mint.try_into().unwrap())
    }

    /// @notice Registers the token on the registry contract
    /// @dev This function is called internally by the constructor
    fn _register_token(ref self: ContractState) {
        let registry_dispatcher = self.registry_dispatcher.read();
        let erc20_dispatcher = IERC20DispatcherEkubo { contract_address: get_contract_address() };

        // mint one token to theregistry contract
        self.erc20.mint(registry_dispatcher.contract_address, ERC20_UNIT.into());

        // call register_token on the registry contract
        registry_dispatcher.register_token(erc20_dispatcher);
    }

    /// @notice Distributes initial tokens to recipients
    /// @param recipients Array of recipient addresses
    /// @param amounts Array of token amounts to distribute
    /// @param total_supply Total supply of tokens
    /// @param zero_address The zero address for validation
    /// @return Total amount of tokens distributed
    fn _distribute_initial_tokens(
        ref self: ContractState,
        recipients: Array<ContractAddress>,
        amounts: Array<u256>,
        total_supply: u128,
        zero_address: ContractAddress,
    ) -> u256 {
        let recipients_len = recipients.len();
        let mut total_distributed: u256 = 0;

        if recipients_len > 0 {
            let mut i = 0;
            while i < recipients_len {
                let recipient = *recipients.at(i);
                let amount = *amounts.at(i);

                // Ensure recipient is not zero address
                assert(recipient != zero_address, 'Invalid recipient address');

                // Update total and check it doesn't exceed supply
                total_distributed += amount;
                assert(total_distributed <= total_supply.into(), 'Distribution exceeds supply');

                // Mint tokens directly to recipient
                self.erc20.mint(recipient, amount);

                i += 1;
            };
        }

        total_distributed
    }

    // ERC20 Hooks Implementation
    impl ERC20HooksImpl of ERC20Component::ERC20HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) { // No-op for before_update
        }

        fn after_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) { // let mut contract_state = self.get_contract_mut();
        }
    }


    pub impl DefaultConfig of ERC20Component::ImmutableConfig {
        const DECIMALS: u8 = ERC20Component::DEFAULT_DECIMALS;
    }
}
