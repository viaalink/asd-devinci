#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Port of the CLI terminal workflow's "Keep session alive" step, plus the
# stop: the tunnel, the deployment and the .env with the login go when the
# run is cancelled, the job times out or timeout-minutes is reached.

cleanup() {
  echo ""
  echo "Ending the session..."
  ci_deactivate_deployment "${DEPLOY_ID:-}"
  via expose stop "${SESSION_NAME}" 2>/dev/null || true
  rm -f .env 2>/dev/null || true
  echo "Session ended"
}
trap cleanup EXIT INT TERM

LIMIT_MIN="${SESSION_TIMEOUT_MINUTES:-0}"
START=$(date +%s)

echo "Session is up. Cancel the run to end it."
while true; do
  sleep 60
  if [ "$LIMIT_MIN" != "0" ] && [ $(( $(date +%s) - START )) -ge $(( LIMIT_MIN * 60 )) ]; then
    echo "timeout-minutes (${LIMIT_MIN}) reached."
    exit 0
  fi
  echo "$(date): session still active"
done
