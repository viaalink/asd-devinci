#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"
# shellcheck source=cleanup.sh
source "${SCRIPTS_DIR}/cleanup.sh"
# shellcheck source=lib/relay-checks.sh
source "${SCRIPTS_DIR}/lib/relay-checks.sh"

# Port of the CLI terminal workflow's "Publish through the relay" step. The
# relay key, host key pins and login arrive as step env (VIA_TUNNEL_*,
# VIA_BASIC_AUTH_*); SESSION_NAME, SESSION_TARGET, STATE_DIR come from earlier
# steps' outputs. Returns once published; keepalive.sh holds the session.

ci_group_start "Publishing the ${SESSION_INTERFACE} through the relay"
if [ "$SESSION_INTERFACE" = "codeserver" ]; then SESSION_LABEL="VS Code"; else SESSION_LABEL="Terminal"; fi

# On failure the keep-alive step never runs: end the session now.
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    CLEANUP_BY="the publish step (failed)" cleanup_session
  fi
}
trap on_exit EXIT

touch "${STATE_DIR}/exposed"
# --auth=basic: the terminal and VS Code are never published without the
# login, whatever expose_auth or a checked-out via.yaml says.
via expose "$SESSION_TARGET" "$SESSION_NAME" --auth=basic
note_caddy_started

# The hostname depends on the relay (a shared relay appends the client id, a
# dedicated one does not), so it is read back from the CLI, never assembled.
URL=$(via expose list --json | jq -r --arg n "$SESSION_NAME" \
  'first(.exposed[] | select(.id == $n or .name == $n) | .url) // empty')
if [ -z "$URL" ]; then
  ci_error "via expose returned but lists no tunnel URL for this session."
  exit 1
fi
if ! relay_url_ok "$URL"; then
  ci_error "via expose list returned an address for this session that is not a plain https URL; refusing to use it."
  exit 1
fi

# The login must really be in front: without credentials the address has to
# answer 401. Anything else (200, a 502 from the app itself) means it is
# open; the session is ended (the trap) instead of handed out.
CODE=$(login_probe "$URL")
if [ "$CODE" != "401" ]; then
  ci_error "The ${SESSION_INTERFACE} was published, but a request without credentials gets HTTP ${CODE}, not 401 with the login's Basic challenge. It is taken down again: the action never leaves it open."
  exit 1
fi
echo "Login in front checked: HTTP 401 without credentials."

echo "$URL" > "${STATE_DIR}/tunnel-url.txt"
echo "Tunnel URL: $URL"

# The URL with the login embedded, for the `url` output only. Masked before
# it is written anywhere.
URL_HOST="${URL#*://}"
URL_HOST="${URL_HOST%%/*}"
ENCODED_USER=$(printf '%s' "${VIA_BASIC_AUTH_USERNAME}" | jq -sRr @uri)
ENCODED_PASS=$(printf '%s' "${VIA_BASIC_AUTH_PASSWORD}" | jq -sRr @uri)
FULL_URL="https://${ENCODED_USER}:${ENCODED_PASS}@${URL_HOST}/"
ci_mask "${ENCODED_PASS}"
ci_mask "${FULL_URL}"
ci_set_output "url" "${FULL_URL}"
ci_set_output "url_base" "${URL}"

LIMIT="until the run is cancelled or the job times out"
ENDS="Cancel the run to end it."
if [ "${SESSION_MODE:-interactive}" = "background" ]; then
  LIMIT="while the job runs"
  ENDS="It ends with the job (the action's post step)."
elif [ "$((10#${SESSION_TIMEOUT_MINUTES:-0}))" -gt 0 ]; then
  LIMIT="for up to $((10#${SESSION_TIMEOUT_MINUTES})) minutes"
fi
ci_set_summary "$(cat << EOF2
## ${SESSION_LABEL:-Session} ready

**[${URL}](${URL})** (sign in as \`${VIA_BASIC_AUTH_USERNAME}\`)

Open ${LIMIT}. ${ENDS}
EOF2
)"

# GitHub: a "View deployment" button (needs deployments: write; skipped
# without it). Passed on as a step output; the cleanup marks it inactive.
ci_create_deployment "via-cicd" "Viaalink CI/CD ${SESSION_INTERFACE} session" "${URL}"
ci_set_output "deploy_id" "${DEPLOY_ID:-}"
# The post step (background mode) has no step output to read it from.
if [ -n "${DEPLOY_ID:-}" ]; then echo "$DEPLOY_ID" > "${STATE_DIR}/deploy-id"; fi

ci_group_end
