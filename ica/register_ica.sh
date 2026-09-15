#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$(dirname "$0")/common.sh"

SHINZOHUB_CONNECTION_ID="${SHINZOHUB_CONNECTION_ID:-connection-0}"
SOURCEHUB_CONNECTION_ID="${SOURCEHUB_CONNECTION_ID:-connection-0}"
CHANNEL_ATTEMPTS="${CHANNEL_ATTEMPTS:-60}"

ensure_key

# Registering the ICA is a one-shot, not a retryable operation: once it lands,
# every further attempt fails with "active channel already set for this owner".
# So it is issued once and tolerated if already done, and the readiness check is
# the channel state below rather than the tx succeeding.
echo "==> Registering ICA ($SHINZOHUB_CONNECTION_ID -> $SOURCEHUB_CONNECTION_ID)..."
TOLERATE='active channel already set' \
  tx sourcehub register-ica "$SHINZOHUB_CONNECTION_ID" "$SOURCEHUB_CONNECTION_ID"

# The upstream script polled for this in start_all_docker.sh. Keeping the poll
# inside the container means this service only exits once the channel is open,
# so downstream services can gate on service_completed_successfully instead of
# guessing with a sleep.
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
