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

MNEMONIC="divert tenant reveal hire thing jar carry lonely magic oak audit fiber earth catalog cheap merry print clown portion speak daring giant weird slight"

rm -f "$MARKER"
mkdir -p /home/hermes/.hermes
sed "s/__SHINZOHUB_CHAIN_ID__/$CHAIN_ID/g" /tmp/hermes-config.toml > "$CONFIG"

echo "==> Adding hermes keys..."
echo "$MNEMONIC" > /tmp/mnemonic.txt
hermes --config "$CONFIG" keys add --chain sourcehub --mnemonic-file /tmp/mnemonic.txt
hermes --config "$CONFIG" keys add --chain "$CHAIN_ID" --mnemonic-file /tmp/mnemonic.txt --hd-path "m/44'/60'/0'/0/0"
rm /tmp/mnemonic.txt

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
