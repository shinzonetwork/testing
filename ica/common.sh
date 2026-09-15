#!/usr/bin/env bash
# Shared setup for the ICA bootstrap one-shots.
#
# These containers do not share the node's volume. Each recovers acc0 into a
# throwaway home of its own, so nothing here can touch the validator's keyring.

set -euo pipefail

export KEY="${KEY:-acc0}"
export CHAIN_ID="${CHAIN_ID:-91273001}"
export KEYRING="${KEYRING:-test}"
export HOME_DIR="${HOME_DIR:-/tmp/ica-home}"
export BINARY="${BINARY:-shinzohubd}"
export NODE="${NODE:-tcp://shinzohub:26657}"
export FEES="${FEES:-9000ushinzo}"
export TX_ATTEMPTS="${TX_ATTEMPTS:-60}"

ACC0_MNEMONIC="divert tenant reveal hire thing jar carry lonely magic oak audit fiber earth catalog cheap merry print clown portion speak daring giant weird slight"

ensure_key () {
  mkdir -p "$HOME_DIR"
  if ! $BINARY keys show "$KEY" --keyring-backend "$KEYRING" --home "$HOME_DIR" >/dev/null 2>&1; then
    echo "==> Recovering $KEY into $HOME_DIR"
    echo "$ACC0_MNEMONIC" | $BINARY keys add "$KEY" \
      --keyring-backend "$KEYRING" \
      --algo eth_secp256k1 \
      --home "$HOME_DIR" \
      --recover >/dev/null
  fi
}

# Broadcast a tx and wait for it to be committed, failing if it reverts.
#
# The wait matters: the CLI returns as soon as CheckTx passes, long before the
# message has actually run, so a broadcast that "succeeds" can still revert on
# chain. Waiting makes a one-shot's exit code mean what compose assumes it means.
#
# Fields come out with grep rather than jq because the CLI writes
# "gas estimate: N" to stderr, so the captured stream is JSON mixed with noise.
#
# Set TOLERATE to a regex to treat a matching failure as success — for
# operations that are not repeatable but are safe to find already done.
TX_ERR_LOG="${TX_ERR_LOG:-/tmp/tx-err.log}"

tx () {
  local out hash res code
  if ! out=$($BINARY tx "$@" \
      --from "$KEY" \
      --keyring-backend "$KEYRING" \
      --chain-id "$CHAIN_ID" \
      --home "$HOME_DIR" \
      --node "$NODE" \
      --gas auto \
      --gas-adjustment 1.5 \
      --fees "$FEES" \
      --output json \
      --yes 2>&1); then
    printf '%s\n' "$out" > "$TX_ERR_LOG"
    if [ -n "${TOLERATE:-}" ] && printf '%s' "$out" | grep -qE "${TOLERATE}"; then
      echo "    already done (matched TOLERATE), continuing."
      return 0
    fi
    printf '%s\n' "$out" >&2
    return 1
  fi

  hash=$(printf '%s\n' "$out" | grep -o '"txhash":"[A-Fa-f0-9]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$hash" ]; then
    echo "could not read txhash from broadcast response:" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi

  if ! res=$($BINARY q wait-tx "$hash" --node "$NODE" --output json 2>&1); then
    printf '%s\n' "$res" > "$TX_ERR_LOG"
    printf '%s\n' "$res" >&2
    return 1
  fi

  code=$(printf '%s\n' "$res" | grep -o '"code":[0-9]*' | head -1 | cut -d: -f2)
  if [ -n "$code" ] && [ "$code" != "0" ]; then
    printf '%s\n' "$res" > "$TX_ERR_LOG"
    if [ -n "${TOLERATE:-}" ] && printf '%s' "$res" | grep -qE "${TOLERATE}"; then
      echo "    already done (matched TOLERATE), continuing."
      return 0
    fi
    echo "tx $hash committed with error code $code:" >&2
    printf '%s\n' "$res" >&2
    return 1
  fi

  echo "    tx $hash committed."
}

# Retry a tx until its preconditions are met.
#
# Registering objects needs the policy id, which only lands after an ICA
# round-trip to SourceHub and back. ShinzoHub exposes no query for that state --
# there is no `q sourcehub policy-id` -- so the tx itself is the readiness probe.
# Under --gas auto a missing precondition fails in simulation, before anything is
# broadcast, so retrying cannot double-submit.
#
# Only for repeatable operations. Registering the ICA is not one: it succeeds
# once and then permanently reports "active channel already set".
tx_retry () {
  local n
  for n in $(seq 1 "$TX_ATTEMPTS"); do
    if tx "$@"; then
      return 0
    fi
    if [ "$n" -eq "$TX_ATTEMPTS" ]; then
      echo "ERROR: tx never succeeded after $TX_ATTEMPTS attempts: $*" >&2
      return 1
    fi
    echo "    precondition not met yet (attempt $n/$TX_ATTEMPTS), retrying in 3s..."
    sleep 3
  done
}
