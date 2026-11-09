#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"
# shellcheck source=cleanup.sh
source "${SCRIPTS_DIR}/cleanup.sh"

# Port of the CLI terminal workflow's "Publish through the relay" step. The
# relay key, host key pins and login arrive as step env (ASD_TUNNEL_*,
# ASD_BASIC_AUTH_*); SESSION_NAME, SESSION_TARGET, STATE_DIR come from earlier
# steps' outputs. Returns once published; keepalive.sh holds the session.

ci_group_start "Publishing through the relay"

# On failure the keep-alive step never runs: end the session now.
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    CLEANUP_BY="the publish step (failed)" cleanup_session
  fi
}
trap on_exit EXIT

touch "${STATE_DIR}/exposed"
via expose "$SESSION_TARGET" "$SESSION_NAME"
note_caddy_started

# The hostname depends on the relay (a shared relay appends the client id, a
# dedicated one does not), so it is read back from the CLI, never assembled.
URL=$(via expose list --json | jq -r --arg n "$SESSION_NAME" \
  'first(.exposed[] | select(.id == $n or .name == $n) | .url) // empty')
if [ -z "$URL" ]; then
  ci_error "via expose returned but lists no tunnel URL for this session."
  exit 1
fi

echo "$URL" > "${STATE_DIR}/tunnel-url.txt"
echo "Tunnel URL: $URL"

# The URL with the login embedded, for the `url` output only. Masked before
# it is written anywhere.
URL_HOST="${URL#*://}"
URL_HOST="${URL_HOST%%/*}"
ENCODED_USER=$(printf '%s' "${ASD_BASIC_AUTH_USERNAME}" | jq -sRr @uri)
ENCODED_PASS=$(printf '%s' "${ASD_BASIC_AUTH_PASSWORD}" | jq -sRr @uri)
FULL_URL="https://${ENCODED_USER}:${ENCODED_PASS}@${URL_HOST}/"
ci_mask "${ENCODED_PASS}"
ci_mask "${FULL_URL}"
ci_set_output "url" "${FULL_URL}"
ci_set_output "url_base" "${URL}"

LIMIT="until the run is cancelled or the job times out"
if [ "$((10#${SESSION_TIMEOUT_MINUTES:-0}))" -gt 0 ]; then
  LIMIT="for up to $((10#${SESSION_TIMEOUT_MINUTES})) minutes"
fi
ci_set_summary "$(cat << EOF2
## Terminal session ready

**[${URL}](${URL})** (sign in as \`${ASD_BASIC_AUTH_USERNAME}\`)

Open ${LIMIT}. Cancel the run to end it.
EOF2
)"

# GitHub: a "View deployment" button (needs deployments: write; skipped
# without it). Passed on as a step output; the cleanup marks it inactive.
ci_create_deployment "ci-terminal" "Viaalink CI Terminal ${SESSION_INTERFACE} session" "${URL}"
ci_set_output "deploy_id" "${DEPLOY_ID:-}"

ci_group_end
