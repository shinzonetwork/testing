#!/bin/sh
# Steady transaction load against anvil, using its unlocked dev accounts.
# Deploys two contracts:
#   - a log emitter: every call emits LOG1(topic=caller, data=calldata)
#   - (installed, not deployed) an ERC20 Transfer emitter at the real USDC and
#     USDT addresses, so the production lens views have logs to select
# Each of LOAD_ACCOUNTS accounts then rotates value transfers, log calls and
# ERC20 transfer events every LOAD_INTERVAL seconds.
set -eu

RPC="--rpc-url ${RPC_URL}"
ACCOUNTS=$(cast rpc $RPC eth_accounts | tr -d '[]" ' | tr ',' '\n')
DEPLOYER=$(echo "$ACCOUNTS" | sed -n 1p)

# init: CODECOPY 12-byte runtime and RETURN it
# runtime: CALLDATACOPY(0,0,size) LOG1(0,size,CALLER) STOP
CODE=0x600c80600b6000396000f336600060003733366000a100
CONTRACT=$(cast compute-address $RPC "$DEPLOYER" | awk '{print $NF}')
cast send $RPC --unlocked --from "$DEPLOYER" --create "$CODE" >/dev/null
echo "[loadgen] log emitter deployed at $CONTRACT"

# The production lens views select logs by contract address — Erc20Event takes 15
# mainnet stablecoins, the decoded-log views take exactly USDC or USDT. A contract
# deployed here would get an anvil address and match none of them, so a Transfer
# emitter is installed AT the real USDC and USDT addresses with anvil_setCode.
#
# runtime: CALLDATACOPY(0,0,size)
#          LOG3(0, size, Transfer topic, from=CALLER, to=CALLER)
#          STOP
TRANSFER_TOPIC=ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
TRANSFER_RUNTIME=0x36600060003733337f${TRANSFER_TOPIC}366000a300
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
USDT=0xdAC17F958D2ee523a2206206994597C13D831ec7
for TOKEN in "$USDC" "$USDT"; do
    cast rpc $RPC anvil_setCode "$TOKEN" "$TRANSFER_RUNTIME" >/dev/null
done
echo "[loadgen] Transfer emitter installed at USDC $USDC and USDT $USDT"

i=2
while [ "$i" -le $((LOAD_ACCOUNTS + 1)) ]; do
    FROM=$(echo "$ACCOUNTS" | sed -n "${i}p")
    TO=$(echo "$ACCOUNTS" | sed -n "$((i % 10 + 1))p")
    (
        n=0
        while true; do
            n=$((n + 1))
            case $((n % 3)) in
                0)  DATA=0x$(printf '%064x%064x' "$n" "$i")
                    cast send $RPC --unlocked --from "$FROM" --async "$CONTRACT" "$DATA" >/dev/null 2>&1 || true ;;
                1)  cast send $RPC --unlocked --from "$FROM" --async --value 1 "$TO" >/dev/null 2>&1 || true ;;
                2)  AMOUNT=0x$(printf '%064x' "$((n * 1000))")   # uint256 value, the event's data
                    TOKEN=$USDC; [ $((n % 2)) -eq 0 ] && TOKEN=$USDT
                    cast send $RPC --unlocked --from "$FROM" --async "$TOKEN" "$AMOUNT" >/dev/null 2>&1 || true ;;
            esac
            sleep "$LOAD_INTERVAL"
        done
    ) &
    i=$((i + 1))
done
echo "[loadgen] sending from ${LOAD_ACCOUNTS} accounts every ${LOAD_INTERVAL}s each"
wait
