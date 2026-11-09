#!/bin/bash
set -uo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"
# shellcheck source=cleanup.sh
source "${SCRIPTS_DIR}/cleanup.sh"

# Port of the CLI terminal workflow's "Keep session alive" step, plus the
# stop. action.yml runs this with `exec`, so the cancel signal reaches this
# shell. sleep runs in the background and the shell waits on it, so the trap
# runs when the signal comes. The trap kills that sleep first: left alive it
# outlives the step and holds the step's output open, so nothing the trap
# prints reaches the log (seen in run 42614595335). Whatever the trap cannot
# finish before the runner kills the step, the final if: always() step does.

SLEEP_PID=""

stop_session() {
  local why="$1"
  trap '' INT TERM
  if [ -n "$SLEEP_PID" ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  echo "Ending the session (${why})."
  CLEANUP_BY="the keep-alive step (${why})" cleanup_session
  exit 0
}
trap 'stop_session cancelled' INT TERM

# 0 means no limit (credentials.sh normalised it to base 10).
LIMIT_MIN=$((10#${SESSION_TIMEOUT_MINUTES:-0}))
START=$(date +%s)

echo "Session is up. Cancel the run to end it."
while true; do
  sleep "${KEEPALIVE_INTERVAL:-60}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
  SLEEP_PID=""
  if [ "$LIMIT_MIN" -gt 0 ] && [ $(( $(date +%s) - START )) -ge $(( LIMIT_MIN * 60 )) ]; then
    stop_session "timeout-minutes (${LIMIT_MIN}) reached"
  fi
  echo "$(date): session still active"
done
