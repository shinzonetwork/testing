#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# ShinzoHub demo node, containerized.
#
# Adapted from shinzohub scripts/ica/start_shinzohub_node.sh. The upstream image
# entrypoint's STANDALONE=1 path builds a *generic* genesis and cannot drive this
# demo: it has no acc0/hermes keys, no admin param, and no ICA controller.
#
# Dropped relative to the upstream script:
#   - `make install` (the binary is baked into the image)
#   - the RPC/REST/gRPC port remapping, which only existed to dodge clashes with
#     other processes on the developer's host
#
# Added relative to the upstream script:
#   - the JSON-RPC listener binds 0.0.0.0 (upstream leaves it on 127.0.0.1,
#     which is unreachable from outside a container)
# ──────────────────────────────────────────────────────────────

KEY="${KEY:-acc0}"
KEY2="${KEY2:-hermes}"
CHAIN_ID="${CHAIN_ID:-91273001}"
MONIKER="${MONIKER:-localvalidator}"
KEYALGO="${KEYALGO:-eth_secp256k1}"
KEYRING="${KEYRING:-test}"
HOME_DIR="${HOME_DIR:-/shinzohub}"
DENOM="${DENOM:-ushinzo}"
BLOCK_TIME="${BLOCK_TIME:-1s}"

RPC=26657
REST=1317
P2P=26656
GRPC=9090
GRPC_WEB=9091
PROFF=6060
ROSETTA=8080
JSONRPC=8545
JSONRPC_WS=8546

BINARY=shinzohubd

# Fixed demo mnemonics. acc0 is the admin account the ICA/policy txs are signed
# with; hermes is the relayer's ShinzoHub account.
ACC0_MNEMONIC="divert tenant reveal hire thing jar carry lonely magic oak audit fiber earth catalog cheap merry print clown portion speak daring giant weird slight"
HERMES_MNEMONIC="decorate bright ozone fork gallery riot bus exhaust worth way bone indoor calm squirrel merry zero scheme cotton until shop any excess stage laundry"
# Derived from ACC0_MNEMONIC. Only this account may register-ica / register-policy.
ADMIN_ADDR="shinzo1g4zla6r5erlf364x5lcgvff6rmek4uwxwlfzs8"

update_genesis () {
  jq "$1" "$HOME_DIR/config/genesis.json" > "$HOME_DIR/config/tmp_genesis.json" \
    && mv "$HOME_DIR/config/tmp_genesis.json" "$HOME_DIR/config/genesis.json"
}

add_key () {
  echo "$2" | $BINARY keys add "$1" \
    --keyring-backend "$KEYRING" \
    --algo "$KEYALGO" \
    --home "$HOME_DIR" \
    --recover
}

if [ ! -f "$HOME_DIR/config/genesis.json" ]; then
  echo "==> Initializing ShinzoHub demo chain ($CHAIN_ID)"

  add_key "$KEY"  "$ACC0_MNEMONIC"
  add_key "$KEY2" "$HERMES_MNEMONIC"

  $BINARY init "$MONIKER" --chain-id "$CHAIN_ID" --default-denom "$DENOM" --home "$HOME_DIR"

  $BINARY config set client chain-id "$CHAIN_ID" --home "$HOME_DIR"
  $BINARY config set client keyring-backend "$KEYRING" --home "$HOME_DIR"

  # ── Core modules ──
  update_genesis '.consensus_params["block"]["max_gas"]="10000000000"'
  update_genesis '.consensus["params"]["block"]["max_bytes"]="104857600"'

  update_genesis "$(printf '.app_state["gov"]["params"]["min_deposit"]=[{"denom":"%s","amount":"1000000"}]' "$DENOM")"
  update_genesis '.app_state["gov"]["params"]["voting_period"]="30s"'
  update_genesis '.app_state["gov"]["params"]["expedited_voting_period"]="15s"'

  update_genesis "$(printf '.app_state["evm"]["params"]["evm_denom"]="%s"' "$DENOM")"
  # 0x...216 is present only from "Feat/change chain (#95)" onward; it matches the pinned SHA.
  update_genesis '.app_state["evm"]["params"]["active_static_precompiles"]=["0x0000000000000000000000000000000000000100","0x0000000000000000000000000000000000000210","0x0000000000000000000000000000000000000211","0x0000000000000000000000000000000000000212","0x0000000000000000000000000000000000000213","0x0000000000000000000000000000000000000214","0x0000000000000000000000000000000000000216","0x0000000000000000000000000000000000000400","0x0000000000000000000000000000000000000800","0x0000000000000000000000000000000000000801","0x0000000000000000000000000000000000000802","0x0000000000000000000000000000000000000803","0x0000000000000000000000000000000000000804","0x0000000000000000000000000000000000000805"]'
  update_genesis '.app_state["erc20"]["native_precompiles"]=["0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"]'
  update_genesis "$(printf '.app_state["erc20"]["token_pairs"]=[{contract_owner:1,erc20_address:"0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",denom:"%s",enabled:true}]' "$DENOM")"
  update_genesis '.app_state["feemarket"]["params"]["no_base_fee"]=true'
  update_genesis '.app_state["feemarket"]["params"]["base_fee"]="0.000000000000000000"'

  update_genesis "$(printf '.app_state["staking"]["params"]["bond_denom"]="%s"' "$DENOM")"
  update_genesis '.app_state["staking"]["params"]["min_commission_rate"]="0.050000000000000000"'
  update_genesis "$(printf '.app_state["mint"]["params"]["mint_denom"]="%s"' "$DENOM")"
  update_genesis "$(printf '.app_state["crisis"]["constant_fee"]={"denom":"%s","amount":"1000"}' "$DENOM")"

  update_genesis '.consensus["params"]["abci"]["vote_extensions_enable_height"]="1"'

  # ── Demo-specific ──
  update_genesis "$(printf '.app_state["admin"]["params"]["admin"]="%s"' "$ADMIN_ADDR")"
  update_genesis '.app_state["interchainaccounts"]["controller_genesis_state"]["params"]["controller_enabled"]=true'

  # ── Accounts and gentx ──
  ALLOC="100000000000000000000000000$DENOM,100000000test"
  $BINARY genesis add-genesis-account "$KEY"  "$ALLOC" --keyring-backend "$KEYRING" --home "$HOME_DIR" --append
  $BINARY genesis add-genesis-account "$KEY2" "$ALLOC" --keyring-backend "$KEYRING" --home "$HOME_DIR" --append

  $BINARY genesis gentx "$KEY" "1000000000000000000000$DENOM" \
    --gas-prices "0$DENOM" \
    --keyring-backend "$KEYRING" \
    --chain-id "$CHAIN_ID" \
    --home "$HOME_DIR"
  $BINARY genesis collect-gentxs --home "$HOME_DIR"
  $BINARY genesis validate-genesis --home "$HOME_DIR"

  # ── Listeners ──
  CFG="$HOME_DIR/config/config.toml"
  APP="$HOME_DIR/config/app.toml"

  sed -i -e 's|laddr = "tcp://127.0.0.1:26657"|laddr = "tcp://0.0.0.0:'"$RPC"'"|g' "$CFG"
  sed -i -e 's|cors_allowed_origins = \[\]|cors_allowed_origins = ["*"]|g' "$CFG"
  sed -i -e 's|laddr = "tcp://0.0.0.0:26656"|laddr = "tcp://0.0.0.0:'"$P2P"'"|g' "$CFG"
  sed -i -e 's|pprof_laddr = "localhost:6060"|pprof_laddr = "localhost:'"$PROFF"'"|g' "$CFG"
  sed -i -e 's|timeout_commit = "5s"|timeout_commit = "'"$BLOCK_TIME"'"|g' "$CFG"

  sed -i -e 's|address = "tcp://localhost:1317"|address = "tcp://0.0.0.0:'"$REST"'"|g' "$APP"
  # Blunt, but it is what upstream does: flips the api and json-rpc enable flags.
  sed -i -e 's|enable = false|enable = true|g' "$APP"
  sed -i -e 's|enabled-unsafe-cors = false|enabled-unsafe-cors = true|g' "$APP"
  sed -i -e 's|address = "localhost:9090"|address = "0.0.0.0:'"$GRPC"'"|g' "$APP"
  sed -i -e 's|address = "localhost:9091"|address = "0.0.0.0:'"$GRPC_WEB"'"|g' "$APP"
  sed -i -e 's|address = ":8080"|address = "0.0.0.0:'"$ROSETTA"'"|g' "$APP"
  sed -i -e 's|evm-chain-id = 262144|evm-chain-id = '"$CHAIN_ID"'|g' "$APP"
  # Not in the upstream script: on the host 127.0.0.1 was fine, in a container it
  # makes the EVM endpoint unreachable from anywhere else.
  sed -i -e 's|address = "127.0.0.1:8545"|address = "0.0.0.0:'"$JSONRPC"'"|g' "$APP"
  sed -i -e 's|ws-address = "127.0.0.1:8546"|ws-address = "0.0.0.0:'"$JSONRPC_WS"'"|g' "$APP"

  echo "==> Genesis ready."
else
  echo "==> Existing genesis found, skipping initialization."
fi

echo "==> Starting ShinzoHub..."
exec $BINARY start \
  --pruning=nothing \
  --minimum-gas-prices="0$DENOM" \
  --rpc.laddr="tcp://0.0.0.0:$RPC" \
  --home "$HOME_DIR" \
  --json-rpc.api=eth,txpool,personal,net,debug,web3 \
  --chain-id="$CHAIN_ID"
