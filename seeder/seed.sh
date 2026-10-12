#!/usr/bin/env sh
set -eu

# ──────────────────────────────────────────────────────────────
# Drives transaction traffic into anvil so the generator has something with
# substance to index. Left alone, anvil mines empty headers and the transaction,
# log and receipt paths through the whole stack never get exercised.
#
# The contract is raw bytecode because the foundry image ships no solc and
# fetching one at runtime would make startup depend on the network. It is a
# minimal log emitter: any call to it emits a Transfer-topic LOG1 and stops.
#
#   runtime:  PUSH32 <topic0>  PUSH1 0  PUSH1 0  LOG1  STOP
#   init:     standard CODECOPY-and-RETURN preamble
#
# topic0 is keccak("Transfer(address,address,uint256)").
# ──────────────────────────────────────────────────────────────

RPC="${ANVIL_RPC_URL:-http://anvil:8545}"
INTERVAL="${SEED_INTERVAL:-3}"
# anvil's first prefunded dev account. Deterministic, well-known, local only.
PK="${SEED_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SINK="${SEED_SINK_ADDR:-0x000000000000000000000000000000000000dEaD}"

INIT=6027600c60003960276000f3
RUNTIME=7fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef60006000a100
BYTECODE="0x${INIT}${RUNTIME}"

echo "==> Waiting for anvil at $RPC..."
until cast block-number --rpc-url "$RPC" >/dev/null 2>&1; do
  sleep 1
done
echo "    anvil is up."

DEPLOYER=$(cast wallet address --private-key "$PK")

# Compute the address before deploying rather than parsing it back out of the
# receipt, which keeps this free of any JSON tooling.
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$RPC")
EMITTER=$(cast compute-address "$DEPLOYER" --nonce "$NONCE" --rpc-url "$RPC" \
  | grep -o '0x[0-9a-fA-F]\{40\}' | head -1)

echo "==> Deploying log emitter from $DEPLOYER (nonce $NONCE) -> $EMITTER"
cast send --private-key "$PK" --rpc-url "$RPC" --create "$BYTECODE" >/dev/null
echo "    deployed."

echo "==> Seeding traffic every ${INTERVAL}s (Ctrl-C to stop)"
i=0
while true; do
  i=$((i + 1))
  # A call that emits a log, and a plain value transfer, so blocks carry both
  # contract interactions and ordinary transfers.
  cast send "$EMITTER" --private-key "$PK" --rpc-url "$RPC" >/dev/null 2>&1 || \
    echo "    warn: emitter call failed (round $i)"
  cast send "$SINK" --value 1000000000000 --private-key "$PK" --rpc-url "$RPC" >/dev/null 2>&1 || \
    echo "    warn: transfer failed (round $i)"
  # An `if`, not `[ ... ] && echo`: under `set -e` the latter makes a false test
  # the failing top-level command and kills the loop.
  if [ $((i % 20)) -eq 0 ]; then
    echo "    $i rounds seeded (height $(cast block-number --rpc-url "$RPC"))"
  fi
  sleep "$INTERVAL"
done
