#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Keeps the job (and with it the tunnel connect.sh started) alive until the
# run is cancelled or times out, then cleans up.

PORT="${SESSION_PORT:-${ASD_TTYD_PORT:-}}"
NAME="${SESSION_NAME:-}"

if [ -n "${CI_TOKEN:-}" ]; then
  ci_mask "${CI_TOKEN}"
fi

# T1: Cleanup handler for workflow cancellation
cleanup() {
  echo ""
  echo "Ending the session..."

  # Mark deployment as inactive
  ci_deactivate_deployment "${DEPLOY_ID:-}"

  # Stop the tunnel started by via expose
  if [ -n "$NAME" ]; then
    via expose stop "$NAME" 2>/dev/null || true
  fi

  # Remove .env with secrets
  rm -f .env 2>/dev/null || true

  echo "Cleanup complete"
}
trap cleanup EXIT INT TERM

if [ -z "$PORT" ]; then
  ci_error "SESSION_PORT / ASD_TTYD_PORT not set. start-interface step must set it."
  exit 1
fi

echo "Session active. Cancel the workflow run to end it."
echo ""

# Keep alive with health checks
HEALTH_FAILURES=0
while true; do
  sleep 60

  # Health-check local service (accept any non-5xx: 401=auth-protected, 302=login redirect)
  HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' "http://localhost:${PORT}/" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" -gt 0 ] 2>/dev/null && [ "$HTTP_CODE" -lt 500 ] 2>/dev/null; then
    HEALTH_FAILURES=0
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC'): session active"
  else
    HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    ci_warning "Health check failed (${HEALTH_FAILURES}/3)"
    if [ "$HEALTH_FAILURES" -ge 3 ]; then
      ci_error "Local service on port ${PORT} is unresponsive after 3 consecutive checks"
      exit 1
    fi
  fi
done
