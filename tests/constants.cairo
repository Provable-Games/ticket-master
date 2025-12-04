use ekubo::types::i129::i129;
use starknet::ContractAddress;
use ticket_master::interfaces::BuybackOrderConfig;

pub const DEPLOYER_ADDRESS: ContractAddress = 'deployer'.try_into().unwrap();

pub const PAYMENT_TOKEN_INITIAL_SUPPLY: u256 = 100_000_000_000_000_000_000_000;
pub const REWARD_TOKEN_INITIAL_SUPPLY: u256 = 100_000_000_000_000_000_000_000;

pub const DISTRIBUTION_POOL_FEE_BPS: u128 = 3402823669209384634633746074317682114;
pub const DISTRIBUTION_INITIAL_TICK: i129 = i129 { mag: 0, sign: false };
pub const DISTRIBUTION_END_TIME: u64 = 5905580032;
pub const BUYBACK_INITIAL_TICK: i129 = i129 { mag: 0, sign: false };
pub const ZERO_ADDRESS: ContractAddress = 0.try_into().unwrap();
pub const BUYBACK_ORDER_CONFIG: BuybackOrderConfig = BuybackOrderConfig {
    min_delay: 0,
    max_delay: 10800,
    min_duration: 259200,
    max_duration: 604800,
    fee: 3402823669209384634633746074317682114,
};

pub const MOCK_REGISTRY_ADDRESS: ContractAddress = 'registry'.try_into().unwrap();
pub const SEPOLIA_REGISTRY_ADDRESS: ContractAddress =
    0x04484f91f0d2482bad844471ca8dc8e846d3a0211792322e72f21f0f44be63e5
    .try_into()
    .unwrap();
pub const MAINNET_REGISTRY_ADDRESS: ContractAddress =
    0x064bdb4094881140bc39340146c5fcc5a187a98aec5a53f448ac702e5de5067e
    .try_into()
    .unwrap();

pub const MOCK_TWAMM_EXTENSION_ADDRESS: ContractAddress = 'extension'.try_into().unwrap();
pub const SEPOLIA_TWAMM_EXTENSION_ADDRESS: ContractAddress =
    0x073ec792c33b52d5f96940c2860d512b3884f2127d25e023eb9d44a678e4b971
    .try_into()
    .unwrap();
pub const MAINNET_TWAMM_EXTENSION_ADDRESS: ContractAddress =
    0x043e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc
    .try_into()
    .unwrap();

pub const MOCK_CORE_ADDRESS: ContractAddress = 'core'.try_into().unwrap();
pub const SEPOLIA_CORE_ADDRESS: ContractAddress =
    0x0444a09d96389aa7148f1aada508e30b71299ffe650d9c97fdaae38cb9a23384
    .try_into()
    .unwrap();
pub const MAINNET_CORE_ADDRESS: ContractAddress =
    0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
    .try_into()
    .unwrap();

pub const MOCK_POSITIONS_ADDRESS: ContractAddress = 'positions'.try_into().unwrap();
pub const MOCK_POSITION_NFT_ADDRESS: ContractAddress = 'positions_nft'.try_into().unwrap();
pub const SEPOLIA_POSITIONS_ADDRESS: ContractAddress =
    0x06a2aee84bb0ed5dded4384ddd0e40e9c1372b818668375ab8e3ec08807417e5
    .try_into()
    .unwrap();
pub const SEPOLIA_POSITION_NFT_ADDRESS: ContractAddress =
    0x04afc78d6fec3b122fc1f60276f074e557749df1a77a93416451be72c435120f
    .try_into()
    .unwrap();
pub const MAINNET_POSITIONS_ADDRESS: ContractAddress =
    0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067
    .try_into()
    .unwrap();
pub const MAINNET_POSITION_NFT_ADDRESS: ContractAddress =
    0x07b696af58c967c1b14c9dde0ace001720635a660a8e90c565ea459345318b30
    .try_into()
    .unwrap();

pub const EKUBO_ORACLE_MAINNET: ContractAddress =
    0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f
    .try_into()
    .unwrap();

pub const EKUBO_ORACLE_SEPOLIA: ContractAddress =
    0x003ccf3ee24638dd5f1a51ceb783e120695f53893f6fd947cc2dcabb3f86dc65
    .try_into()
    .unwrap();

pub const MOCK_TREASURY: ContractAddress = 'treasury'.try_into().unwrap();

pub const MAINNET_TREASURY: ContractAddress =
    0x041bb7729efa185f2cab327de0a668886302f1d4969e3edf504c4741648f858b
    .try_into()
    .unwrap();

pub const DUNGEON_TICKET_SUPPLY: u128 = 100_000_000_000_000_000_000_000;

pub const INITIAL_LIQUIDITY_PAYMENT_TOKEN: u128 = 100_000_000_000_000_000_000;
pub const INITIAL_LIQUIDITY_DUNGEON_TICKETS: u128 = 100_000_000_000_000_000_000;
pub const INITIAL_LIQUIDITY_MIN_LIQUIDITY: u128 = 1;
pub const ISSUANCE_REDUCTION_PRICE_X128: u256 = 1_000_000_000_000_000_000;
pub const ISSUANCE_REDUCTION_PRICE_DURATION: u64 = 259200;
pub const ISSUANCE_REDUCTION_BIPS: u128 = 2500;
