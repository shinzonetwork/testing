#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$(dirname "$0")/common.sh"

# Positional args to register-objects.
RESOURCES="${RESOURCES:-block logs event transaction}"

ensure_key

echo "==> Registering Shinzo objects: $RESOURCES"
# shellcheck disable=SC2086
tx_retry sourcehub register-objects $RESOURCES
