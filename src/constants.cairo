use core::num::traits::Pow;
use ekubo::types::bounds::Bounds;
use ekubo::types::i129::i129;
use starknet::ContractAddress;

pub mod Errors {
    pub const TOKEN_DISTRIBUTION_NOT_STARTED: felt252 = 'distribution not started';
    pub const DISTRIBUTION_POOL_NOT_INITIALIZED: felt252 = 'dist pool not initialized';
    pub const END_TIME_EXCEEDS_MAX: felt252 = 'End time exceeds max limit';
    pub const DISTRIBUTION_NOT_STARTED: felt252 = 'Distribution not started';
    pub const REDUCTION_PRICE_NOT_SET: felt252 = 'reduction price not set';
    pub const LOW_ISSUANCE_ALREADY_ACTIVE: felt252 = 'low issuance already active';
    pub const LOW_ISSUANCE_NOT_ACTIVE: felt252 = 'low issuance not active';
    pub const PRICE_NOT_BELOW_REDUCTION_THRESHOLD: felt252 = 'price not below threshold';
    pub const PRICE_NOT_ABOVE_REDUCTION_THRESHOLD: felt252 = 'price not above threshold';
    pub const LOW_ISSUANCE_TOKENS_MISSING: felt252 = 'no tokens held for low issuance';
    pub const REDUCTION_BIPS_NOT_SET: felt252 = 'reduction bips not set';
    pub const REDUCTION_RATE_TOO_SMALL: felt252 = 'reduction rate too small';
    pub const REDUCTION_RATE_TOO_LARGE: felt252 = 'reduction rate too large';
    pub const INVALID_REDUCTION_BIPS: felt252 = 'Invalid reduction bips';
    pub const INVALID_RECIPIENT: felt252 = 'invalid recipient';
    pub const NO_TICKETS_AVAILABLE: felt252 = 'no tickets available';
    pub const REDUCTION_BIPS_TOO_LARGE: felt252 = 'reduction bips too large';
    pub const REDUCTION_DURATION_NOT_SET: felt252 = 'reduction duration not set';
}

// Mathematical constants
pub const ERC20_DECIMALS: u32 = 18;
pub const ERC20_UNIT: u128 = 10_u128.pow(ERC20_DECIMALS);

// Protocol constants
pub const TWAMM_TICK_SPACING: u128 = 354892; // Maximum allowed tick spacing
pub const BIPS_BASIS: u128 = 10000;

// Ekubo TWAMM time alignment
pub const EKUBO_TIME_GRANULARITY: u64 = 268435456; // 16^7 seconds alignment requirement

pub const TWAMM_BOUNDS: Bounds = Bounds {
    lower: i129 { mag: 88368108, sign: true }, upper: i129 { mag: 88368108, sign: false },
};

pub const USDC_TOKEN_CONTRACT: ContractAddress =
    0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
    .try_into()
    .unwrap();
