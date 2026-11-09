#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Port of the CLI terminal workflow's "Publish through the relay" step. The
# relay key, host key pins and login arrive as step env (ASD_TUNNEL_*,
# ASD_BASIC_AUTH_*). Returns once published; keepalive.sh holds the session.

ci_group_start "Publishing through the relay"

# On failure the keep-alive step never runs: stop what started and remove the
# .env holding the login (a self-hosted runner keeps its workspace).
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    via expose stop "${SESSION_NAME}" >/dev/null 2>&1 || true
    rm -f .env 2>/dev/null || true
  fi
}
trap on_exit EXIT

via expose "$SESSION_TARGET" "$SESSION_NAME"

# The hostname depends on the relay (a shared relay appends the client id, a
# dedicated one does not), so it is read back from the CLI, never assembled.
URL=$(via expose list --json | jq -r --arg n "$SESSION_NAME" \
  'first(.exposed[] | select(.id == $n or .name == $n) | .url) // empty')
if [ -z "$URL" ]; then
  ci_error "via expose returned but lists no tunnel URL for '${SESSION_NAME}'."
  exit 1
fi

mkdir -p workspace
echo "$URL" > workspace/tunnel-url.txt
echo "Tunnel URL: $URL"

# The URL with the login embedded, for the `url` output only.
URL_HOST="${URL#*://}"
URL_HOST="${URL_HOST%%/*}"
ENCODED_USER=$(printf '%s' "${ASD_BASIC_AUTH_USERNAME}" | jq -sRr @uri)
ENCODED_PASS=$(printf '%s' "${ASD_BASIC_AUTH_PASSWORD}" | jq -sRr @uri)
ci_set_output "url" "https://${ENCODED_USER}:${ENCODED_PASS}@${URL_HOST}/"
ci_set_output "url_base" "${URL}"
ci_set_output "session_name" "${SESSION_NAME}"

LIMIT="until the run is cancelled or the job times out"
if [ "${SESSION_TIMEOUT_MINUTES:-0}" != "0" ]; then
  LIMIT="for up to ${SESSION_TIMEOUT_MINUTES} minutes"
fi
ci_set_summary "$(cat << EOF2
## Terminal session ready

**[${URL}](${URL})** (sign in as \`${ASD_BASIC_AUTH_USERNAME}\`)

Open ${LIMIT}. Cancel the run to end it.
EOF2
)"

# GitHub: a "View deployment" button (needs deployments: write; skipped
# without it). keepalive.sh marks it inactive.
ci_create_deployment "ci-terminal" "Viaalink CI Terminal ${SESSION_INTERFACE} session" "${URL}"

ci_group_end
