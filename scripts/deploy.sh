#!/bin/bash

set -euo pipefail

ENV_FILE="${1:-.env}"

if [ $# -gt 1 ]; then
    echo "Usage: $0 [env_file]" >&2
    exit 1
fi

if [ "${ENV_FILE}" != ".env" ] && [ ! -f "${ENV_FILE}" ]; then
    echo "Environment file not found: ${ENV_FILE}" >&2
    exit 1
fi

if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${ENV_FILE}"
    set +a
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

export STARKNET_DISABLE_WARNINGS=1

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_tx() {
    local tx_hash=$1
    local explorer="https://sepolia.voyager.online/tx/$tx_hash"
    if [ "${STARKNET_NETWORK}" == "mainnet" ]; then
        explorer="https://voyager.online/tx/$tx_hash"
    fi
    echo -e "${BLUE}[TX]${NC} $explorer"
}

require_env() {
    local missing=()
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required environment variables: ${missing[*]}"
        exit 1
    fi
}

scale_to_wei() {
    local value="$1"
    if [[ -z "$value" ]]; then
        echo "0"
        return 0
    fi
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        if [ ${#value} -gt 18 ]; then
            echo "$value"
        else
            printf '%s%018d' "$value" 0
        fi
        return 0
    fi
    if [[ "$value" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        local int_part="${BASH_REMATCH[1]}"
        local frac_part="${BASH_REMATCH[2]}"
        while [[ "$frac_part" =~ 0$ && ${#frac_part} -gt 0 ]]; do
            frac_part="${frac_part::-1}"
        done
        if [ ${#frac_part} -gt 18 ]; then
            frac_part="${frac_part:0:18}"
        fi
        local zeros=$((18 - ${#frac_part}))
        local padding=""
        if [ $zeros -gt 0 ]; then
            padding=$(printf '%0.s0' $(seq 1 $zeros))
        fi
        echo "${int_part}${frac_part}${padding}"
        return 0
    fi
    echo "$value"
}

to_u256_parts() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if value == "":
    print("0 0")
    sys.exit(0)
if value.startswith("0x") or value.startswith("0X"):
    number = int(value, 16)
else:
    number = int(value)
if number < 0:
    raise SystemExit("u256 must be non-negative")
low = number & ((1 << 128) - 1)
high = number >> 128
print(f"{low} {high}")
PY
}

compare_hex() {
    python3 - <<'PY' "$1" "$2"
import sys

def normalize(value: str) -> int:
    v = value.strip().lower()
    if v.startswith("0x"):
        v = v[2:]
    if v == "":
        return 0
    return int(v, 16)

a = normalize(sys.argv[1])
b = normalize(sys.argv[2])
if a < b:
    print("lt")
elif a > b:
    print("gt")
else:
    print("eq")
PY
}

compute_tick_components() {
    local orientation="$1" # token0 or token1
    python3 - <<'PY' "$orientation" "$INITIAL_PAYMENT_TOKEN_LIQUIDITY" "$INITIAL_DUNGEON_TICKET_LIQUIDITY"
import sys
from decimal import Decimal, getcontext, ROUND_FLOOR

orientation = sys.argv[1]
payment = Decimal(sys.argv[2])
dungeon = Decimal(sys.argv[3])

if payment <= 0 or dungeon <= 0:
    raise SystemExit("liquidity must be positive")

getcontext().prec = 80
base = Decimal('1.000001')
ratio = payment / dungeon
price = ratio if orientation == 'token0' else dungeon / payment

if price == 1:
    tick = Decimal(0)
else:
    tick = price.ln() / base.ln()
    if tick.copy_abs() < Decimal('1e-18'):
        tick = Decimal(0)

tick_int = tick.to_integral_value(rounding=ROUND_FLOOR)
tick_int = int(tick_int)

if tick_int >= 0:
    sign = 0
    magnitude = tick_int
else:
    sign = 1
    magnitude = -tick_int

print(f"{magnitude} {sign}")
PY
}

resolve_owner_address() {
    if command -v jq >/dev/null 2>&1 && [ -f "$STARKNET_ACCOUNT" ]; then
        local candidate
        candidate=$(jq -r '.deployment.address // .address // empty' "$STARKNET_ACCOUNT" 2>/dev/null || true)
        if [ -n "$candidate" ] && [ "$candidate" != "null" ]; then
            echo "$candidate"
            return 0
        fi
    fi
    print_error "Unable to determine deployer address from $STARKNET_ACCOUNT"
    exit 1
}

require_env STARKNET_NETWORK STARKNET_RPC STARKNET_ACCOUNT STARKNET_PK TOKEN_NAME TOKEN_SYMBOL TOKEN_SUPPLY PAYMENT_TOKEN BUYBACK_TOKEN TREASURY_ADDRESS

DEPLOYER=$(resolve_owner_address)
FINAL_OWNER=${OWNER_ADDRESS:-$DEPLOYER}
print_info "Resolved deployer address: $DEPLOYER"
if [ "$FINAL_OWNER" != "$DEPLOYER" ]; then
    print_info "Will transfer ownership to: $FINAL_OWNER"
fi
TOKEN_NAME_ENC="bytearray:str:${TOKEN_NAME}"
TOKEN_SYMBOL_ENC="bytearray:str:${TOKEN_SYMBOL}"
TOTAL_SUPPLY=${TOKEN_SUPPLY}
DISTRIBUTION_POOL_FEE=${DISTRIBUTION_POOL_FEE_BPS:-3402823669209384634633746074317682114}
BUYBACK_POOL_FEE=${BUYBACK_POOL_FEE_BPS:-3402823669209384634633746074317682114}

case "$STARKNET_NETWORK" in
    sepolia)
        CORE_ADDRESS_DEFAULT="0x0444a09d96389aa7148f1aada508e30b71299ffe650d9c97fdaae38cb9a23384"
        POSITIONS_ADDRESS_DEFAULT="0x06a2aee84bb0ed5dded4384ddd0e40e9c1372b818668375ab8e3ec08807417e5"
        EXTENSION_ADDRESS_DEFAULT="0x073ec792c33b52d5f96940c2860d512b3884f2127d25e023eb9d44a678e4b971"
        REGISTRY_ADDRESS_DEFAULT="0x04484f91f0d2482bad844471ca8dc8e846d3a0211792322e72f21f0f44be63e5"
        ORACLE_ADDRESS_DEFAULT="0x003ccf3ee24638dd5f1a51ceb783e120695f53893f6fd947cc2dcabb3f86dc65"
        ;;
    mainnet)
        CORE_ADDRESS_DEFAULT="0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b"
        POSITIONS_ADDRESS_DEFAULT="0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067"
        EXTENSION_ADDRESS_DEFAULT="0x043e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc"
        REGISTRY_ADDRESS_DEFAULT="0x064bdb4094881140bc39340146c5fcc5a187a98aec5a53f448ac702e5de5067e"
        ORACLE_ADDRESS_DEFAULT="0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f"
        ;;
    *)
        print_warn "Unknown network ${STARKNET_NETWORK}. Provide EKUBO_* environment overrides."
        CORE_ADDRESS_DEFAULT=""
        POSITIONS_ADDRESS_DEFAULT=""
        EXTENSION_ADDRESS_DEFAULT=""
        REGISTRY_ADDRESS_DEFAULT=""
        ORACLE_ADDRESS_DEFAULT=""
        ;;
esac

CORE_ADDRESS="${EKUBO_CORE_ADDRESS:-$CORE_ADDRESS_DEFAULT}"
POSITIONS_ADDRESS="${EKUBO_POSITIONS_ADDRESS:-$POSITIONS_ADDRESS_DEFAULT}"
EXTENSION_ADDRESS="${EKUBO_TWAMM_EXTENSION_ADDRESS:-$EXTENSION_ADDRESS_DEFAULT}"
REGISTRY_ADDRESS="${EKUBO_REGISTRY_ADDRESS:-$REGISTRY_ADDRESS_DEFAULT}"
ORACLE_ADDRESS="${EKUBO_ORACLE_ADDRESS:-$ORACLE_ADDRESS_DEFAULT}"
if [ -z "${POSITION_NFT_ADDRESS:-}" ]; then
    POSITION_NFT_ADDRESS="$POSITIONS_ADDRESS"
fi

require_env CORE_ADDRESS POSITIONS_ADDRESS EXTENSION_ADDRESS REGISTRY_ADDRESS ORACLE_ADDRESS

ISSUANCE_PRICE_LOW=${ISSUANCE_REDUCTION_PRICE_X128_LOW:-}
ISSUANCE_PRICE_HIGH=${ISSUANCE_REDUCTION_PRICE_X128_HIGH:-}
if [ -z "$ISSUANCE_PRICE_LOW" ] || [ -z "$ISSUANCE_PRICE_HIGH" ]; then
    read -r ISSUANCE_PRICE_LOW ISSUANCE_PRICE_HIGH < <(to_u256_parts "${ISSUANCE_REDUCTION_PRICE_X128:-1000000000000000000}")
fi
ISSUANCE_REDUCTION_PRICE_DURATION=${ISSUANCE_REDUCTION_PRICE_DURATION:-259200}
ISSUANCE_REDUCTION_BIPS=${ISSUANCE_REDUCTION_BIPS:-2500}

# Parse premint recipients and amounts if provided
PREMINT_RECIPIENTS=()
PREMINT_AMOUNTS=()
if [ -n "${RECIPIENTS:-}" ] && [ -n "${AMOUNTS:-}" ]; then
    IFS=',' read -ra RECIPIENT_ARRAY <<< "${RECIPIENTS}"
    IFS=',' read -ra AMOUNT_ARRAY <<< "${AMOUNTS}"
    if [ ${#RECIPIENT_ARRAY[@]} -ne ${#AMOUNT_ARRAY[@]} ]; then
        print_error "RECIPIENTS and AMOUNTS must have matching lengths"
        exit 1
    fi
    for recipient in "${RECIPIENT_ARRAY[@]}"; do
        recipient_trimmed="${recipient//[[:space:]]/}"
        if [ -z "$recipient_trimmed" ]; then
            print_error "Recipient address cannot be empty"
            exit 1
        fi
        PREMINT_RECIPIENTS+=("$recipient_trimmed")
    done
    for amt in "${AMOUNT_ARRAY[@]}"; do
        amt_trimmed="${amt//[[:space:]]/}"
        if [ -z "$amt_trimmed" ]; then
            print_error "Amount cannot be empty"
            exit 1
        fi
        PREMINT_AMOUNTS+=("$amt_trimmed")
    done
    print_info "Premint configuration: ${#PREMINT_RECIPIENTS[@]} recipient(s)"
elif [ -n "${RECIPIENTS:-}" ] || [ -n "${AMOUNTS:-}" ]; then
    print_error "Both RECIPIENTS and AMOUNTS must be provided together, or neither"
    exit 1
fi

DISTRIBUTION_END_TIME=${DISTRIBUTION_END_TIMESTAMP}
PAYMENT_LIQUIDITY_INPUT=${INITIAL_PAYMENT_TOKEN_LIQUIDITY:-${INITIAL_LIQUIDITY_PAYMENT_TOKEN:-0}} 
DUNGEON_LIQUIDITY_INPUT=${INITIAL_DUNGEON_TICKET_LIQUIDITY:-${INITIAL_LIQUIDITY_NEW_TOKEN:-0}}

INITIAL_PAYMENT_TOKEN_LIQUIDITY=$(scale_to_wei "$PAYMENT_LIQUIDITY_INPUT")
INITIAL_DUNGEON_TICKET_LIQUIDITY=$(scale_to_wei "$DUNGEON_LIQUIDITY_INPUT")
INITIAL_MIN_LIQUIDITY=${INITIAL_MIN_LIQUIDITY:-${MINIMUM_LIQUIDITY:-1}}

BUYBACK_MIN_DURATION=${BUYBACK_MIN_DURATION:-259200}
BUYBACK_MAX_DURATION=${BUYBACK_MAX_DURATION:-604800}
BUYBACK_MIN_DELAY=${BUYBACK_MIN_DELAY:-0}
BUYBACK_MAX_DELAY=${BUYBACK_MAX_DELAY:-10800}

if [[ "$INITIAL_PAYMENT_TOKEN_LIQUIDITY" =~ ^0+$ ]] || [[ "$INITIAL_DUNGEON_TICKET_LIQUIDITY" =~ ^0+$ ]]; then
    print_error "Initial liquidity amounts must be greater than zero"
    exit 1
fi

TARGET_CLASS="/workspace/ticket-master/target/release/ticket_master_TicketMaster.contract_class.json"
print_info "Building package"
scarb --release build
if [ ! -f "$TARGET_CLASS" ]; then
    print_error "Contract artifact not found at $TARGET_CLASS"
    exit 1
fi

print_info "Declaring contract"
DECLARE_OUTPUT=$(starkli declare --watch  --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$TARGET_CLASS" 2>&1 || true)
DECLARE_EXIT=$?
if [ $DECLARE_EXIT -ne 0 ] && ! echo "$DECLARE_OUTPUT" | grep -q "already declared"; then
    print_error "Declaration failed"
    echo "$DECLARE_OUTPUT"
    exit 1
fi
CLASS_HASH=$(echo "$DECLARE_OUTPUT" | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
if [ -z "$CLASS_HASH" ]; then
    print_error "Unable to extract class hash"
    echo "$DECLARE_OUTPUT"
    exit 1
fi
print_info "Class hash: $CLASS_HASH"

CONSTRUCTOR_ARGS=(
    "$DEPLOYER"
    "$TOKEN_NAME_ENC"
    "$TOKEN_SYMBOL_ENC"
    "$TOTAL_SUPPLY"
    "$DISTRIBUTION_POOL_FEE"
    "$PAYMENT_TOKEN"
    "$BUYBACK_TOKEN"
    "$CORE_ADDRESS"
    "$POSITIONS_ADDRESS"
    "$POSITION_NFT_ADDRESS"
    "$EXTENSION_ADDRESS"
    "$REGISTRY_ADDRESS"
    "$ORACLE_ADDRESS"
    "$ISSUANCE_PRICE_LOW"
    "$ISSUANCE_PRICE_HIGH"
    "$ISSUANCE_REDUCTION_PRICE_DURATION"
    "$ISSUANCE_REDUCTION_BIPS"
    "$TREASURY_ADDRESS"
    "$DISTRIBUTION_END_TIME"
    "$BUYBACK_MIN_DELAY"
    "$BUYBACK_MAX_DELAY"
    "$BUYBACK_MIN_DURATION"
    "$BUYBACK_MAX_DURATION"
    "$BUYBACK_POOL_FEE"
)

print_info "Deployment parameters"
echo "  Network:            $STARKNET_NETWORK"
echo "  RPC:                $STARKNET_RPC"
echo "  Deployer:           $DEPLOYER"
echo "  Final owner:        $FINAL_OWNER"
echo "  Token:              $TOKEN_NAME ($TOKEN_SYMBOL)"
echo "  Total supply:       $TOTAL_SUPPLY"
echo "  Distribution fee:   $DISTRIBUTION_POOL_FEE"
echo "  Payment token:      $PAYMENT_TOKEN"
echo "  Buyback token:      $BUYBACK_TOKEN"
echo "  Treasury:           $TREASURY_ADDRESS"
echo "  Core:               $CORE_ADDRESS"
echo "  Positions:          $POSITIONS_ADDRESS"
echo "  Position NFT:       $POSITION_NFT_ADDRESS"
echo "  Extension:          $EXTENSION_ADDRESS"
echo "  Registry:           $REGISTRY_ADDRESS"
echo "  Oracle:             $ORACLE_ADDRESS"
echo "  End time:           $DISTRIBUTION_END_TIME"
echo "  Initial pay liq:    $INITIAL_PAYMENT_TOKEN_LIQUIDITY"
echo "  Initial ticket liq: $INITIAL_DUNGEON_TICKET_LIQUIDITY"
echo "  Minimum liquidity:  $INITIAL_MIN_LIQUIDITY"
echo "  Buyback min duration: $BUYBACK_MIN_DURATION"
echo "  Buyback max duration: $BUYBACK_MAX_DURATION"
echo "  Buyback min delay: $BUYBACK_MIN_DELAY"
echo "  Buyback max delay: $BUYBACK_MAX_DELAY"
echo "  Buyback fee:        $BUYBACK_POOL_FEE"
echo "  Issuance price low: $ISSUANCE_PRICE_LOW"
echo "  Issuance price high: $ISSUANCE_PRICE_HIGH"
echo "  Issuance reduction price duration: $ISSUANCE_REDUCTION_PRICE_DURATION"
echo "  Issuance reduction bips: $ISSUANCE_REDUCTION_BIPS"

print_info "Deploying contract"
DEPLOY_OUTPUT=$(starkli deploy --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CLASS_HASH" "${CONSTRUCTOR_ARGS[@]}" 2>&1 || true)
DEPLOY_EXIT=$?
if [ $DEPLOY_EXIT -ne 0 ] || echo "$DEPLOY_OUTPUT" | grep -qi "error"; then
    print_error "Deployment failed"
    echo "$DEPLOY_OUTPUT"
    exit 1
fi

CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
DEPLOY_TX=$(echo "$DEPLOY_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
if [ -z "$CONTRACT_ADDRESS" ]; then
    print_error "Unable to parse contract address from deployment output"
    echo "$DEPLOY_OUTPUT"
    exit 1
fi

print_info "Contract deployed at $CONTRACT_ADDRESS"
if [ -n "$DEPLOY_TX" ]; then print_tx "$DEPLOY_TX"; fi

ORIENTATION_CHECK=$(compare_hex "$CONTRACT_ADDRESS" "$PAYMENT_TOKEN")
case "$ORIENTATION_CHECK" in
    lt)
        read -r DIST_TICK_MAG DIST_TICK_SIGN <<< "$(compute_tick_components token0)"
        ORIENTATION_LABEL="token0"
        ;;
    gt)
        read -r DIST_TICK_MAG DIST_TICK_SIGN <<< "$(compute_tick_components token1)"
        ORIENTATION_LABEL="token1"
        ;;
    *)
        print_error "Unable to determine token ordering between contract and payment token"
        exit 1
        ;;
esac

if [ -z "${DIST_TICK_MAG:-}" ] || [ -z "${DIST_TICK_SIGN:-}" ]; then
    print_error "Failed to compute distribution tick from liquidity inputs"
    exit 1
fi

print_info "Computed distribution tick: magnitude=$DIST_TICK_MAG sign=$DIST_TICK_SIGN (orientation $ORIENTATION_LABEL)"

check_contract_ready() {
    local address=$1
    for attempt in $(seq 1 30); do
        CALL_OUTPUT=$(starkli call --rpc "$STARKNET_RPC" "$address" symbol 2>&1 || true)
        if echo "$CALL_OUTPUT" | grep -q "0x"; then
            return 0
        fi
        sleep 5
    done
    return 1
}

print_info "Waiting for contract to be callable"
if ! check_contract_ready "$CONTRACT_ADDRESS"; then
    print_error "Contract did not become ready in time"
    exit 1
fi

mkdir -p deployments
DEPLOY_FILE="deployments/ticketmaster_$(date +%Y%m%d_%H%M%S).json"
cat > "$DEPLOY_FILE" <<EOF
{
  "network": "$STARKNET_NETWORK",
  "rpc": "$STARKNET_RPC",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contract_address": "$CONTRACT_ADDRESS",
  "class_hash": "$CLASS_HASH",
  "parameters": {
    "token_name": "$TOKEN_NAME",
    "token_symbol": "$TOKEN_SYMBOL",
    "total_supply": "$TOTAL_SUPPLY",
    "distribution_pool_fee_bps": "$DISTRIBUTION_POOL_FEE",
    "payment_token": "$PAYMENT_TOKEN",
    "buyback_token": "$BUYBACK_TOKEN",
    "treasury": "$TREASURY_ADDRESS",
    "core": "$CORE_ADDRESS",
    "positions": "$POSITIONS_ADDRESS",
    "extension": "$EXTENSION_ADDRESS",
    "registry": "$REGISTRY_ADDRESS",
    "oracle": "$ORACLE_ADDRESS",
    "distribution_end_time": "$DISTRIBUTION_END_TIME",
    "distribution_tick_mag": "$DIST_TICK_MAG",
    "distribution_tick_sign": "$DIST_TICK_SIGN",
    "initial_payment_liquidity": "$INITIAL_PAYMENT_TOKEN_LIQUIDITY",
    "initial_dungeon_liquidity": "$INITIAL_DUNGEON_TICKET_LIQUIDITY",
    "initial_min_liquidity": "$INITIAL_MIN_LIQUIDITY",
    "buyback_min_duration": "$BUYBACK_MIN_DURATION",
    "buyback_max_duration": "$BUYBACK_MAX_DURATION",
    "buyback_min_delay": "$BUYBACK_MIN_DELAY",
    "buyback_max_delay": "$BUYBACK_MAX_DELAY",
    "buyback_pool_fee": "$BUYBACK_POOL_FEE",
    "issuance_price_low": "$ISSUANCE_PRICE_LOW",
    "issuance_price_high": "$ISSUANCE_PRICE_HIGH",
    "issuance_reduction_price_duration": "$ISSUANCE_REDUCTION_PRICE_DURATION",
    "issuance_reduction_bips": "$ISSUANCE_REDUCTION_BIPS"
  }
}
EOF

# Call premint_tokens if recipients and amounts were provided
if [ ${#PREMINT_RECIPIENTS[@]} -gt 0 ]; then
    print_info "Preminting tokens to ${#PREMINT_RECIPIENTS[@]} recipient(s)"

    # Build the recipients array argument
    RECIPIENTS_ARRAY_ARG="${#PREMINT_RECIPIENTS[@]}"
    for recipient in "${PREMINT_RECIPIENTS[@]}"; do
        RECIPIENTS_ARRAY_ARG="$RECIPIENTS_ARRAY_ARG $recipient"
    done

    # Build the amounts array argument (convert each amount to u256)
    AMOUNTS_ARRAY_ARG="${#PREMINT_AMOUNTS[@]}"
    for amt in "${PREMINT_AMOUNTS[@]}"; do
        read -r low high < <(to_u256_parts "$amt")
        AMOUNTS_ARRAY_ARG="$AMOUNTS_ARRAY_ARG $low $high"
    done

    # Call premint_tokens
    PREMINT_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" premint_tokens $RECIPIENTS_ARRAY_ARG $AMOUNTS_ARRAY_ARG)
    #PREMINT_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" premint_tokens $RECIPIENTS_ARRAY_ARG $AMOUNTS_ARRAY_ARG 2>&1 || true)
    PREMINT_EXIT=$?
    if [ $PREMINT_EXIT -ne 0 ]; then
        print_error "premint_tokens failed"
        echo "$PREMINT_OUTPUT"
        exit 1
    fi
    PREMINT_TX=$(echo "$PREMINT_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
    if [ -n "$PREMINT_TX" ]; then print_tx "$PREMINT_TX"; fi
    print_info "Tokens preminted successfully"
fi

# Transfer ownership to final owner if different from deployer
if [ "$FINAL_OWNER" != "$DEPLOYER" ]; then
    print_info "Transferring ownership to $FINAL_OWNER"
    TRANSFER_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" transfer_ownership "$FINAL_OWNER" 2>&1 || true)
    TRANSFER_EXIT=$?
    if [ $TRANSFER_EXIT -ne 0 ]; then
        print_error "transfer_ownership failed"
        echo "$TRANSFER_OUTPUT"
        exit 1
    fi
    TRANSFER_TX=$(echo "$TRANSFER_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
    if [ -n "$TRANSFER_TX" ]; then print_tx "$TRANSFER_TX"; fi
    print_info "Ownership transferred successfully"
fi

# print_info "Approving payment token"
# APPROVE_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$PAYMENT_TOKEN" approve "$CONTRACT_ADDRESS" u256:$INITIAL_PAYMENT_TOKEN_LIQUIDITY 2>&1 || true)
# APPROVE_EXIT=$?
# if [ $APPROVE_EXIT -ne 0 ]; then
#     print_error "Payment token approval failed"
#     echo "$APPROVE_OUTPUT"
#     exit 1
# fi
# APPROVE_TX=$(echo "$APPROVE_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
# if [ -n "$APPROVE_TX" ]; then print_tx "$APPROVE_TX"; fi

# print_info "Initializing distribution pool"
# INIT_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" init_distribution_pool "$DIST_TICK_MAG" "$DIST_TICK_SIGN" 2>&1 || true)
# INIT_EXIT=$?
# if [ $INIT_EXIT -ne 0 ]; then
#     print_error "init_distribution_pool failed"
#     echo "$INIT_OUTPUT"
#     exit 1
# fi
# INIT_TX=$(echo "$INIT_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
# if [ -n "$INIT_TX" ]; then print_tx "$INIT_TX"; fi

# print_info "Providing initial liquidity"
# echo "  Payment token (wei): $INITIAL_PAYMENT_TOKEN_LIQUIDITY"
# echo "  Dungeon token (wei): $INITIAL_DUNGEON_TICKET_LIQUIDITY"
# echo "  Min liquidity:       $INITIAL_MIN_LIQUIDITY"
# #starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" provide_initial_liquidity "$INITIAL_PAYMENT_TOKEN_LIQUIDITY" "$INITIAL_DUNGEON_TICKET_LIQUIDITY" "$INITIAL_MIN_LIQUIDITY"
# LIQ_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" provide_initial_liquidity "$INITIAL_PAYMENT_TOKEN_LIQUIDITY" "$INITIAL_DUNGEON_TICKET_LIQUIDITY" "$INITIAL_MIN_LIQUIDITY" 2>&1 || true)
# LIQ_EXIT=$?
# if [ $LIQ_EXIT -ne 0 ]; then
#     print_error "provide_initial_liquidity failed"
#     echo "$LIQ_OUTPUT"
#     exit 1
# fi
# LIQ_TX=$(echo "$LIQ_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
# if [ -n "$LIQ_TX" ]; then print_tx "$LIQ_TX"; fi

# print_info "Starting token distribution"
# DIST_OUTPUT=$(starkli invoke --watch --account "$STARKNET_ACCOUNT" --private-key "$STARKNET_PK" --rpc "$STARKNET_RPC" "$CONTRACT_ADDRESS" start_token_distribution 2>&1 || true)
# DIST_EXIT=$?
# if [ $DIST_EXIT -ne 0 ]; then
#     print_error "start_token_distribution failed"
#     echo "$DIST_OUTPUT"
#     exit 1
# fi
# DIST_TX=$(echo "$DIST_OUTPUT" | grep -oE 'transaction: 0x[0-9a-fA-F]+' | head -1 | awk '{print $2}')
# if [ -n "$DIST_TX" ]; then print_tx "$DIST_TX"; fi

print_info "Deployment workflow complete"
print_info "Deployment details saved to $DEPLOY_FILE"
