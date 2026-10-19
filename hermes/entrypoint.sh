#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Hermes relayer: adds its keys, creates the IBC connection, then relays.
#
# Compose starts this only once both chains are healthy, so the retries below
# cover just the light client needing a couple of blocks on each side.
#
# On success it touches a marker file, which is what the container's healthcheck
# tests — that is how the bootstrap one-shots know the connection exists.
# ──────────────────────────────────────────────────────────────

CONFIG=/home/hermes/.hermes/config.toml
MARKER=/home/hermes/.hermes/connection-ready
CHAIN_ID="${SHINZOHUB_CHAIN_ID:-91273001}"
ATTEMPTS="${CONNECTION_ATTEMPTS:-10}"

# One key per chain. On ShinzoHub the relayer must not sign as acc0: the
# register-* one-shots broadcast from acc0 while Hermes is relaying their
# packets, and sharing an account sequence makes one of them fail with
# "account sequence mismatch".
SOURCEHUB_MNEMONIC="${SOURCEHUB_RELAYER_MNEMONIC:?SOURCEHUB_RELAYER_MNEMONIC must be set}"
SHINZOHUB_MNEMONIC="${SHINZOHUB_RELAYER_MNEMONIC:?SHINZOHUB_RELAYER_MNEMONIC must be set}"

rm -f "$MARKER"
mkdir -p /home/hermes/.hermes
sed "s/__SHINZOHUB_CHAIN_ID__/$CHAIN_ID/g" /tmp/hermes-config.toml > "$CONFIG"

echo "==> Adding hermes keys..."
echo "$SOURCEHUB_MNEMONIC" > /tmp/sourcehub-mnemonic.txt
echo "$SHINZOHUB_MNEMONIC" > /tmp/shinzohub-mnemonic.txt
hermes --config "$CONFIG" keys add --chain sourcehub --mnemonic-file /tmp/sourcehub-mnemonic.txt
hermes --config "$CONFIG" keys add --chain "$CHAIN_ID" --mnemonic-file /tmp/shinzohub-mnemonic.txt --hd-path "m/44'/60'/0'/0/0"
rm /tmp/sourcehub-mnemonic.txt /tmp/shinzohub-mnemonic.txt

echo "==> Creating IBC connection (sourcehub <-> $CHAIN_ID)..."
for i in $(seq 1 "$ATTEMPTS"); do
  if hermes --config "$CONFIG" create connection --a-chain sourcehub --b-chain "$CHAIN_ID"; then
    echo "==> Connection created."
    touch "$MARKER"
    break
  fi
  if [ "$i" -eq "$ATTEMPTS" ]; then
    echo "ERROR: hermes create connection failed after $ATTEMPTS attempts"
    exit 1
  fi
  echo "    attempt $i failed, retrying in 3s..."
  sleep 3
done

echo "==> Starting hermes..."
exec hermes --config "$CONFIG" start
