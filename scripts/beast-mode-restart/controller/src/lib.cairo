//! Fork-only controller prototype. Not approved for mainnet deployment.
use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Tick {
    pub mag: u128,
    pub sign: bool,
}
#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Bounds {
    pub lower: Tick,
    pub upper: Tick,
}
#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct PoolKey {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub fee: u128,
    pub tick_spacing: u128,
    pub extension: ContractAddress,
}
#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct OrderKey {
    pub sell_token: ContractAddress,
    pub buy_token: ContractAddress,
    pub fee: u128,
    pub start_time: u64,
    pub end_time: u64,
}
#[derive(Copy, Drop, Serde)]
pub struct OrderInfo {
    pub sale_rate: u128,
    pub remaining_sell_amount: u128,
    pub purchased_amount: u128,
}
#[derive(Copy, Drop, Serde)]
pub struct PositionInfo {
    pub sqrt_price: u256,
    pub tick: Tick,
    pub liquidity: u128,
    pub amount0: u128,
    pub amount1: u128,
    pub fees0: u128,
    pub fees1: u128,
}

#[starknet::interface]
pub trait IPositions<T> {
    fn get_order_info(self: @T, id: u64, order_key: OrderKey) -> OrderInfo;
    fn get_token_info(self: @T, id: u64, pool_key: PoolKey, bounds: Bounds) -> PositionInfo;
    fn withdraw_proceeds_from_sale_to(
        ref self: T, id: u64, order_key: OrderKey, recipient: ContractAddress,
    ) -> u128;
    fn decrease_sale_rate_to(
        ref self: T,
        id: u64,
        order_key: OrderKey,
        sale_rate_delta: u128,
        recipient: ContractAddress,
    ) -> u128;
    fn increase_sell_amount(ref self: T, id: u64, order_key: OrderKey, amount: u128) -> u128;
    fn clear(ref self: T, token: ContractAddress) -> u256;
    fn withdraw(
        ref self: T,
        id: u64,
        pool_key: PoolKey,
        bounds: Bounds,
        liquidity: u128,
        min_token0: u128,
        min_token1: u128,
        collect_fees: bool,
    ) -> (u128, u128);
}

/// Return (direct transfer, conversion principal). The remainder always goes
/// into the direct leg, so every raw unit is assigned exactly once.
pub fn split_proceeds(amount: u128, survivor_sale: bool) -> (u128, u128) {
    let fifth = amount / 5;
    if survivor_sale {
        (amount - fifth, fifth)
    } else {
        (fifth, amount - fifth)
    }
}

#[starknet::interface]
pub trait IController<T> {
    fn status(self: @T) -> (bool, u128, u128, u64);
    fn import_proceeds(ref self: T, amount: u128);
    fn claim(ref self: T) -> u128;
    fn distribute(ref self: T, conversion_end: u64) -> (u128, u128);
    fn claim_conversion(ref self: T, conversion_end: u64) -> u128;
    fn pause_sale(ref self: T) -> u128;
    fn refill_sale(ref self: T, amount: u128) -> u128;
    fn withdraw_lp(ref self: T, minimum0: u128, minimum1: u128) -> (u128, u128);
    fn recover_surplus(ref self: T, token: ContractAddress) -> u256;
    fn release_positions(ref self: T);
}

#[starknet::contract]
pub mod TrialController {
    use core::num::traits::Zero;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_contract_address};
    use super::{
        Bounds, IPositionsDispatcher, IPositionsDispatcherTrait, OrderKey, PoolKey, split_proceeds,
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: ReentrancyGuardComponent, storage: guard, event: GuardEvent);
    #[abi(embed_v0)]
    impl Ownership = OwnableComponent::OwnableTwoStepMixinImpl<ContractState>;
    impl OwnableInternal = OwnableComponent::InternalImpl<ContractState>;
    impl GuardInternal = ReentrancyGuardComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        guard: ReentrancyGuardComponent::Storage,
        positions: ContractAddress,
        nft: ContractAddress,
        lords: ContractAddress,
        survivor: ContractAddress,
        dao: ContractAddress,
        velords: ContractAddress,
        pool: PoolKey,
        order: OrderKey,
        bounds: Bounds,
        order_id: u64,
        lp_id: u64,
        paused: bool,
        pending: u128,
        conversion_dust: u128,
        conversion_count: u64,
        conversions: Map<u64, bool>,
    }
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        GuardEvent: ReentrancyGuardComponent::Event,
        Claimed: Claimed,
        Distributed: Distributed,
        Converted: Converted,
        Paused: Paused,
        Refilled: Refilled,
        Recovered: Recovered,
        Imported: Imported,
    }
    #[derive(Drop, starknet::Event)]
    struct Imported {
        amount: u128,
    }
    #[derive(Drop, starknet::Event)]
    struct Claimed {
        amount: u128,
    }
    #[derive(Drop, starknet::Event)]
    struct Distributed {
        direct: u128,
        conversion: u128,
        refund: u128,
        conversion_end: u64,
    }
    #[derive(Drop, starknet::Event)]
    struct Converted {
        conversion_end: u64,
        amount: u128,
    }
    #[derive(Drop, starknet::Event)]
    struct Paused {
        returned_tickets: u128,
    }
    #[derive(Drop, starknet::Event)]
    struct Refilled {
        amount: u128,
        rate: u128,
    }
    #[derive(Drop, starknet::Event)]
    struct Recovered {
        token0: u128,
        token1: u128,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        positions: ContractAddress,
        nft: ContractAddress,
        lords: ContractAddress,
        survivor: ContractAddress,
        dao: ContractAddress,
        velords: ContractAddress,
        pool: PoolKey,
        order: OrderKey,
        bounds: Bounds,
        order_id: u64,
        lp_id: u64,
    ) {
        assert(positions.is_non_zero() && nft.is_non_zero(), 'ZERO_PROTOCOL');
        assert(lords.is_non_zero() && survivor.is_non_zero() && lords != survivor, 'TOKENS');
        assert(dao.is_non_zero() && velords.is_non_zero(), 'ZERO_RECIPIENT');
        assert(pool.token0 == lords || pool.token0 == survivor, 'PAYMENT');
        assert(pool.token0 < pool.token1 && pool.token1.is_non_zero(), 'SORTED_POOL');
        assert(order.sell_token == pool.token1 && order.buy_token == pool.token0, 'SALE_PAIR');
        assert(order.fee == pool.fee && order.start_time == 0, 'SALE_KEY');
        assert(order.end_time > get_block_timestamp(), 'ENDED');
        assert(order_id != lp_id, 'DISTINCT_POSITIONS');
        self.ownable.initializer(owner);
        self.positions.write(positions);
        self.nft.write(nft);
        self.lords.write(lords);
        self.survivor.write(survivor);
        self.dao.write(dao);
        self.velords.write(velords);
        self.pool.write(pool);
        self.order.write(order);
        self.bounds.write(bounds);
        self.order_id.write(order_id);
        self.lp_id.write(lp_id);
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn positions(self: @ContractState) -> IPositionsDispatcher {
            IPositionsDispatcher { contract_address: self.positions.read() }
        }
        fn claim_internal(ref self: ContractState) -> u128 {
            let amount = self
                .positions()
                .withdraw_proceeds_from_sale_to(
                    self.order_id.read(), self.order.read(), get_contract_address(),
                );
            self.pending.write(self.pending.read() + amount);
            self.emit(Claimed { amount });
            amount
        }
        fn conversion_key(self: @ContractState, end: u64) -> OrderKey {
            OrderKey {
                sell_token: self.pool.read().token0,
                buy_token: if self.pool.read().token0 == self.survivor.read() {
                    self.lords.read()
                } else {
                    self.survivor.read()
                },
                fee: 3402823669209384634633746074317682114,
                start_time: 0,
                end_time: end,
            }
        }
        fn send(
            self: @ContractState, token: ContractAddress, recipient: ContractAddress, amount: u128,
        ) {
            assert(
                IERC20Dispatcher { contract_address: token }.transfer(recipient, amount.into()),
                'TRANSFER_FAILED',
            );
        }
    }

    #[abi(embed_v0)]
    impl Controller of super::IController<ContractState> {
        fn status(self: @ContractState) -> (bool, u128, u128, u64) {
            (
                self.paused.read(),
                self.pending.read(),
                self.conversion_dust.read(),
                self.conversion_count.read(),
            )
        }
        // Explicit owner funding is tracked separately from unsolicited token
        // transfers. The handover uses this for already-earned legacy LORDS.
        fn import_proceeds(ref self: ContractState, amount: u128) {
            self.ownable.assert_only_owner();
            self.guard.start();
            assert(amount > 0, 'ZERO_IMPORT');
            let token = IERC20Dispatcher { contract_address: self.pool.read().token0 };
            let before = token.balance_of(get_contract_address());
            assert(
                token.transfer_from(self.ownable.owner(), get_contract_address(), amount.into()),
                'IMPORT_TRANSFER',
            );
            assert(
                token.balance_of(get_contract_address()) == before + amount.into(), 'IMPORT_AMOUNT',
            );
            self.pending.write(self.pending.read() + amount);
            self.emit(Imported { amount });
            self.guard.end();
        }
        fn claim(ref self: ContractState) -> u128 {
            self.ownable.assert_only_owner();
            self.guard.start();
            let amount = self.claim_internal();
            self.guard.end();
            amount
        }
        fn distribute(ref self: ContractState, conversion_end: u64) -> (u128, u128) {
            self.ownable.assert_only_owner();
            self.guard.start();
            self.claim_internal();
            let amount = self.pending.read();
            assert(amount > 0 || self.conversion_dust.read() > 0, 'NO_PROCEEDS');
            let survivor_sale = self.pool.read().token0 == self.survivor.read();
            let (direct, new_conversion) = split_proceeds(amount, survivor_sale);
            let conversion = new_conversion + self.conversion_dust.read();
            self.conversion_dust.write(0);
            let recipient = if survivor_sale {
                self.dao.read()
            } else {
                self.velords.read()
            };
            self.pending.write(0);
            self.send(self.pool.read().token0, recipient, direct);
            let mut refund = 0;
            if conversion > 0 {
                let now = get_block_timestamp();
                assert(
                    conversion_end >= now + 259200 && conversion_end <= now + 604800,
                    'CONVERSION_DURATION',
                );
                assert(!self.conversions.read(conversion_end), 'DUPLICATE_END');
                self.conversions.write(conversion_end, true);
                self.conversion_count.write(self.conversion_count.read() + 1);
                self.send(self.pool.read().token0, self.positions.read(), conversion);
                self
                    .positions()
                    .increase_sell_amount(
                        self.order_id.read(), self.conversion_key(conversion_end), conversion,
                    );
                refund = self
                    .positions()
                    .clear(self.pool.read().token0)
                    .try_into()
                    .expect('REFUND_OVERFLOW');
                self.conversion_dust.write(refund);
            }
            self.emit(Distributed { direct, conversion, refund, conversion_end });
            self.guard.end();
            (direct, conversion)
        }
        fn claim_conversion(ref self: ContractState, conversion_end: u64) -> u128 {
            self.ownable.assert_only_owner();
            self.guard.start();
            assert(self.conversions.read(conversion_end), 'UNKNOWN_CONVERSION');
            assert(get_block_timestamp() >= conversion_end, 'NOT_MATURE');
            self.conversions.write(conversion_end, false);
            self.conversion_count.write(self.conversion_count.read() - 1);
            let recipient = if self.pool.read().token0 == self.survivor.read() {
                self.velords.read()
            } else {
                self.dao.read()
            };
            let amount = self
                .positions()
                .withdraw_proceeds_from_sale_to(
                    self.order_id.read(), self.conversion_key(conversion_end), recipient,
                );
            self.emit(Converted { conversion_end, amount });
            self.guard.end();
            amount
        }
        fn pause_sale(ref self: ContractState) -> u128 {
            self.ownable.assert_only_owner();
            self.guard.start();
            self.claim_internal();
            let info = self.positions().get_order_info(self.order_id.read(), self.order.read());
            let returned = self
                .positions()
                .decrease_sale_rate_to(
                    self.order_id.read(),
                    self.order.read(),
                    info.sale_rate,
                    self.pool.read().token1,
                );
            self.paused.write(true);
            self.emit(Paused { returned_tickets: returned });
            self.guard.end();
            returned
        }
        fn refill_sale(ref self: ContractState, amount: u128) -> u128 {
            self.ownable.assert_only_owner();
            self.guard.start();
            assert(self.paused.read() && amount > 0, 'PAUSED_AND_FUNDED');
            self.send(self.pool.read().token1, self.positions.read(), amount);
            let rate = self
                .positions()
                .increase_sell_amount(self.order_id.read(), self.order.read(), amount);
            self.positions().clear(self.pool.read().token1);
            self.paused.write(false);
            self.emit(Refilled { amount, rate });
            self.guard.end();
            rate
        }
        fn withdraw_lp(ref self: ContractState, minimum0: u128, minimum1: u128) -> (u128, u128) {
            self.ownable.assert_only_owner();
            self.guard.start();
            assert(self.paused.read(), 'PAUSE_FIRST');
            let info = self
                .positions()
                .get_token_info(self.lp_id.read(), self.pool.read(), self.bounds.read());
            let (amount0, amount1) = self
                .positions()
                .withdraw(
                    self.lp_id.read(),
                    self.pool.read(),
                    self.bounds.read(),
                    info.liquidity,
                    minimum0,
                    minimum1,
                    true,
                );
            self.send(self.pool.read().token0, self.ownable.owner(), amount0);
            self.send(self.pool.read().token1, self.ownable.owner(), amount1);
            self.emit(Recovered { token0: amount0, token1: amount1 });
            self.guard.end();
            (amount0, amount1)
        }
        fn release_positions(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.guard.start();
            assert(self.paused.read() && self.conversion_count.read() == 0, 'PAUSE_AND_SETTLE');
            assert(
                self.pending.read() == 0 && self.conversion_dust.read() == 0, 'DISTRIBUTE_FIRST',
            );
            let order = self.positions().get_order_info(self.order_id.read(), self.order.read());
            assert(
                order.sale_rate == 0
                    && order.remaining_sell_amount == 0
                    && order.purchased_amount == 0,
                'ACTIVE_ORDER',
            );
            let lp = self
                .positions()
                .get_token_info(self.lp_id.read(), self.pool.read(), self.bounds.read());
            assert(lp.liquidity == 0 && lp.fees0 == 0 && lp.fees1 == 0, 'ACTIVE_LP');
            let nft = IERC721Dispatcher { contract_address: self.nft.read() };
            nft
                .transfer_from(
                    get_contract_address(), self.ownable.owner(), self.order_id.read().into(),
                );
            nft
                .transfer_from(
                    get_contract_address(), self.ownable.owner(), self.lp_id.read().into(),
                );
            self.guard.end();
        }
        fn recover_surplus(ref self: ContractState, token: ContractAddress) -> u256 {
            self.ownable.assert_only_owner();
            self.guard.start();
            assert(self.paused.read(), 'PAUSE_FIRST');
            let pool = self.pool.read();
            assert(token == pool.token0 || token == pool.token1, 'SALE_TOKENS_ONLY');
            let erc20 = IERC20Dispatcher { contract_address: token };
            let reserved: u256 = if token == pool.token0 {
                (self.pending.read() + self.conversion_dust.read()).into()
            } else {
                0
            };
            let surplus = erc20.balance_of(get_contract_address()) - reserved;
            assert(erc20.transfer(self.ownable.owner(), surplus), 'TRANSFER_FAILED');
            self.guard.end();
            surplus
        }
    }
}
