#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$(dirname "$0")/common.sh"

SHINZOHUB_CONNECTION_ID="${SHINZOHUB_CONNECTION_ID:-connection-0}"
SOURCEHUB_CONNECTION_ID="${SOURCEHUB_CONNECTION_ID:-connection-0}"
CHANNEL_ATTEMPTS="${CHANNEL_ATTEMPTS:-60}"

ensure_key

# Registering the ICA is not retryable: once it lands, every further attempt
# fails with "active channel already set for this owner". So it is issued once
# and tolerated if already done, which keeps re-running this container safe.
# Readiness is the channel state below, not the tx result.
echo "==> Registering ICA ($SHINZOHUB_CONNECTION_ID -> $SOURCEHUB_CONNECTION_ID)..."
TOLERATE='active channel already set' \
  tx sourcehub register-ica "$SHINZOHUB_CONNECTION_ID" "$SOURCEHUB_CONNECTION_ID"

# Polling here, rather than in the caller, means this container exits only once
# the channel is open — so register-policy can simply depend on it completing.
echo "==> Waiting for the ICA channel handshake..."
for i in $(seq 1 "$CHANNEL_ATTEMPTS"); do
  if $BINARY q ibc channel channels --node "$NODE" -o json 2>/dev/null \
      | grep -q '"state":"STATE_OPEN"'; then
    echo "    ICA channel is OPEN."
    exit 0
  fi
  if [ "$i" -eq "$CHANNEL_ATTEMPTS" ]; then
    echo "ERROR: ICA channel did not open. Check: docker compose logs hermes"
    exit 1
  fi
  sleep 2
done
