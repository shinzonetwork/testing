#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Hermes relayer. Creates the IBC connection, then relays.
#
# Changed from the upstream demo entrypoint:
#   - chain 91273002 pointed at host.docker.internal; ShinzoHub is a container
#     now, so it is plain compose DNS and extra_hosts is gone
#   - the chain id is templated from SHINZOHUB_CHAIN_ID rather than hardcoded
#   - the 60-attempt retry loop is gone: depends_on/service_healthy already
#     guarantees both chains are up. A few attempts remain because the light
#     client still needs a couple of blocks on each side.
#   - writes a readiness marker so compose can gate register-ica on the
#     connection existing, instead of the old `sleep 20`
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
