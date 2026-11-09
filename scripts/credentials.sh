#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Checks the inputs before anything is installed or started, so a missing
# secret fails in seconds with the steps to fix it.

ci_group_start "Checking relay credentials"

# Mask secrets early (GitHub masks secrets.* already; this covers values
# passed in another way).
ci_mask "${INPUT_TUNNEL_KEY:-}"
ci_mask "${INPUT_PASSWORD:-}"

missing=""
[ -n "${INPUT_TUNNEL_KEY:-}" ] || missing="$missing tunnel-key (VIA_TUNNEL_KEY)"
[ -n "${INPUT_TUNNEL_KEY_ID:-}" ] || missing="$missing tunnel-key-id (VIA_TUNNEL_KEY_ID)"
[ -n "${INPUT_TUNNEL_HOST:-}" ] || missing="$missing tunnel-host (VIA_TUNNEL_HOST)"
[ -n "${INPUT_HOST_KEY_FINGERPRINTS:-}" ] || missing="$missing tunnel-host-key-fingerprints (VIA_TUNNEL_HOST_KEY_FINGERPRINTS)"
[ -n "${INPUT_PASSWORD:-}" ] || missing="$missing password (VIA_TERMINAL_PASSWORD)"
if [ -n "$missing" ]; then
  ci_error "Missing inputs:${missing}. Run 'via gh setup' in this repository on a device enrolled on your relay; it stores these as repository secrets. Then pass them as \${{ secrets.VIA_* }}."
  exit 1
fi

if [ -n "${INPUT_TUNNEL_PORT:-}" ] && ! [[ "$INPUT_TUNNEL_PORT" =~ ^[0-9]{1,5}$ ]]; then
  ci_error "tunnel-port must be a port number."
  exit 1
fi

# The username goes into .env and the URL as it is.
if ! [[ "${INPUT_USERNAME:-}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  ci_error "The username input may hold only letters, digits, dots, underscores and hyphens."
  exit 1
fi
case "$INPUT_PASSWORD" in
  *$'\n'*|*$'\r'*)
    ci_error "The password holds a line break, which a .env value cannot. Store another one (via gh setup)."
    exit 1
    ;;
esac

case "${INPUT_INTERFACE:-terminal}" in
  terminal|codeserver) ;;
  *)
    ci_error "interface must be terminal or codeserver, not '${INPUT_INTERFACE}'."
    exit 1
    ;;
esac

if ! [[ "${INPUT_TIMEOUT_MINUTES:-0}" =~ ^[0-9]+$ ]]; then
  ci_error "timeout-minutes must be a whole number of minutes (0 = no limit)."
  exit 1
fi

NAME="${INPUT_TUNNEL_NAME:-${GITHUB_SHA:0:7}}"
if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  ci_error "Tunnel name '${NAME}' is not a DNS label (lowercase letters, digits and inner hyphens)."
  exit 1
fi

# For the later steps of this action (not secret).
ci_set_env "SESSION_NAME" "${NAME}"
ci_set_env "SESSION_INTERFACE" "${INPUT_INTERFACE:-terminal}"
ci_set_env "SESSION_TIMEOUT_MINUTES" "${INPUT_TIMEOUT_MINUTES:-0}"

echo "Relay: ${INPUT_TUNNEL_HOST}:${INPUT_TUNNEL_PORT:-2222} (key ${INPUT_TUNNEL_KEY_ID})"
echo "Session: ${NAME} (${INPUT_INTERFACE:-terminal})"

ci_group_end
