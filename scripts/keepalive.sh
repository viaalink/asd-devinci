#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"
# shellcheck source=cleanup.sh
source "${SCRIPTS_DIR}/cleanup.sh"

# Port of the CLI terminal workflow's "Keep session alive" step, plus the
# stop. action.yml runs this with `exec`, so the cancel signal reaches this
# shell; `sleep & wait` lets the trap run at once instead of after the sleep.
# The action's final always() step runs the same cleanup if this one could not.

trap 'cleanup_session; exit 0' INT TERM
trap cleanup_session EXIT

# 0 means no limit (credentials.sh normalised it to base 10).
LIMIT_MIN=$((10#${SESSION_TIMEOUT_MINUTES:-0}))
START=$(date +%s)

echo "Session is up. Cancel the run to end it."
while true; do
  sleep 60 &
  wait $!
  if [ "$LIMIT_MIN" -gt 0 ] && [ $(( $(date +%s) - START )) -ge $(( LIMIT_MIN * 60 )) ]; then
    echo "timeout-minutes (${LIMIT_MIN}) reached."
    exit 0
  fi
  echo "$(date): session still active"
done
