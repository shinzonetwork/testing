#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$(dirname "$0")/common.sh"

ensure_key

echo "==> Registering Shinzo policy..."
tx_retry sourcehub register-policy
