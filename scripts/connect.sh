#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

ci_group_start "Publishing through the relay"

# Get tunnel name (default to short SHA)
NAME="${TUNNEL_NAME:-${CI_COMMIT:0:7}}"

# T5: Validate tunnel name for DNS compatibility
if [[ ! "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  ci_error "Invalid tunnel name '${NAME}'. Must be lowercase alphanumeric with hyphens, not starting/ending with hyphen."
  exit 1
fi

# S2: Mask CI token before use in curl calls
if [ -n "${CI_TOKEN:-}" ]; then
  ci_mask "${CI_TOKEN}"
fi

# Get port and credentials from environment (set by previous steps via ci_set_env)
PORT="${SESSION_PORT:-${ASD_TTYD_PORT:-}}"
if [ -z "${PORT}" ]; then
  ci_error "SESSION_PORT / ASD_TTYD_PORT not set. start-interface step must set it."
  exit 1
fi
USERNAME="${SESSION_USERNAME:-${ASD_TTYD_USERNAME:-via}}"
PASSWORD="${SESSION_PASSWORD:-${ASD_TTYD_PASSWORD:-}}"
DIRECT_MODE="${DIRECT_MODE:-false}"
RELAY_AUTH="${RELAY_AUTH:-password}"

if [ -z "${ASD_TUNNEL_HOST:-}" ]; then
  ci_error "ASD_TUNNEL_HOST is empty. The credentials step must set it (tunnel-host input)."
  exit 1
fi

# Write the relay credentials and the login to .env for the CLI.
# ASD_TUNNEL_PORT is optional with a relay key (the CLI uses 2222).
{
  if [ "$RELAY_AUTH" = "key" ]; then
    echo "ASD_TUNNEL_KEY=${ASD_TUNNEL_KEY}"
    echo "ASD_TUNNEL_KEY_ID=${ASD_TUNNEL_KEY_ID}"
  else
    echo "ASD_CLIENT_ID=${ASD_CLIENT_ID}"
    echo "ASD_CLIENT_SECRET=${ASD_CLIENT_SECRET}"
  fi
  echo "ASD_TUNNEL_HOST=${ASD_TUNNEL_HOST}"
  if [ -n "${ASD_TUNNEL_PORT:-}" ]; then
    echo "ASD_TUNNEL_PORT=${ASD_TUNNEL_PORT}"
  fi
  echo "ASD_BASIC_AUTH_USERNAME=${USERNAME}"
  echo "ASD_BASIC_AUTH_PASSWORD=${PASSWORD}"
} >> .env

# S3: Restrict .env file permissions after writing secrets
chmod 600 .env

# On failure the keep-alive step never runs, so clean up here: a self-hosted
# runner keeps its workspace, and .env holds the relay credentials.
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    via expose stop "${NAME}" >/dev/null 2>&1 || true
    rm -f .env 2>/dev/null || true
  fi
}
trap on_exit EXIT

# Source the updated .env
set -a
# shellcheck disable=SC1091
source .env
set +a

# `via expose <port> <name>`: the name is the service id and the first label
# of the hostname.
EXPOSE_ARGS=("${PORT}" "${NAME}")
if [ "${DIRECT_MODE}" = "true" ]; then
  EXPOSE_ARGS+=("--direct")
fi

INTERFACE="${INTERFACE_TYPE:-ttyd}"
echo "Publishing ${INTERFACE} on port ${PORT} as ${NAME}"

if ! via expose "${EXPOSE_ARGS[@]}"; then
  ci_error "Publishing through the relay failed"
  echo "  Relay: ${ASD_TUNNEL_HOST}:${ASD_TUNNEL_PORT:-2222}"
  echo "  Check: the relay key or client credentials, outbound SSH to the relay, the relay's status"
  exit 1
fi

# The hostname depends on the relay (a shared relay appends the client id, a
# dedicated one does not), so it is read back from the CLI, never assembled.
TUNNEL_URL=$(via expose list --json | jq -r --arg n "$NAME" \
  'first(.exposed[] | select(.id == $n or .name == $n) | .url) // empty')
if [ -z "$TUNNEL_URL" ]; then
  ci_error "via expose returned but lists no URL for '${NAME}'."
  exit 1
fi
case "$TUNNEL_URL" in */) ;; *) TUNNEL_URL="${TUNNEL_URL}/" ;; esac
URL_HOST="${TUNNEL_URL#https://}"
URL_HOST="${URL_HOST#http://}"
URL_HOST="${URL_HOST%%/*}"

# URL-encode the login for embedding in the URL
ENCODED_USER=$(printf '%s' "${USERNAME}" | jq -sRr @uri)
ENCODED_PASS=$(printf '%s' "${PASSWORD}" | jq -sRr @uri)
FULL_URL="https://${ENCODED_USER}:${ENCODED_PASS}@${URL_HOST}/"

# Set outputs
ci_set_output "url" "${FULL_URL}"
ci_set_output "url_base" "${TUNNEL_URL}"

# Export TUNNEL_URL for current shell and write to dotenv so GitLab
# environment.url can resolve it (GitLab reads dotenv artifacts, not exports)
ci_set_env "TUNNEL_URL" "${TUNNEL_URL}"
ci_set_output "TUNNEL_URL" "${TUNNEL_URL}"
ci_set_env "SESSION_NAME" "${NAME}"

# Write tunnel URL file for artifact upload (`via gh terminal` reads this)
mkdir -p workspace
echo "${TUNNEL_URL}" > workspace/tunnel-url.txt

EXPIRES_AT="${ASD_EXPIRES_AT:-unknown}"

# S4: Write summary
SUMMARY_MD="$(cat << EOF
## Viaalink CI Terminal ready

### Click to Open
**[${TUNNEL_URL}](${TUNNEL_URL})**

| Setting | Value |
|---------|-------|
| Interface | \`${INTERFACE}\` |
| Username | \`${USERNAME}\` |
| Relay | \`${ASD_TUNNEL_HOST}\` |
| Expires | \`${EXPIRES_AT}\` |
| Local Port | \`${PORT}\` |

> Cancel the workflow run to end the session.

---
*[Viaalink CI Terminal](https://viaalink.com)*
EOF
)"
ci_set_summary "$SUMMARY_MD"

echo ""
echo "=============================================="
echo "SESSION URL: ${TUNNEL_URL}"
echo "=============================================="
echo ""
echo "   Interface:   ${INTERFACE}"
echo "   Relay:       ${ASD_TUNNEL_HOST}"
echo "   Username:    ${USERNAME}"
echo "   Local Port:  ${PORT}"
echo "   Expires:     ${EXPIRES_AT}"
echo ""
echo "=============================================="
echo ""

# Create deployment (GitHub: API call, GitLab: handled by environment: keyword).
# keepalive.sh marks it inactive when the session ends.
ci_create_deployment "ci-terminal" "Viaalink CI Terminal ${INTERFACE} session" "${TUNNEL_URL}"

ci_group_end
