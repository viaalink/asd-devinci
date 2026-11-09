#!/bin/bash
# Ends a session and puts the checkout back as it was. Safe to call more than
# once and from any step: each part runs only if its marker is in STATE_DIR,
# and the state directory is removed at the end.
#
#   STATE_DIR     per-session state (credentials.sh)
#   SESSION_NAME  the published name
#   DEPLOY_ID     GitHub deployment to mark inactive (optional)
#
# Sourced by the step scripts (cleanup_session) and run as the action's final
# always() step.

cleanup_session() {
  local state="${STATE_DIR:-}"
  [ -n "$state" ] && [ -d "$state" ] || return 0

  if [ -f "$state/exposed" ] && [ -n "${SESSION_NAME:-}" ]; then
    via expose stop "${SESSION_NAME}" >/dev/null 2>&1 || true
  fi
  if [ -f "$state/interface" ]; then
    case "$(cat "$state/interface")" in
      codeserver) via codeserver stop >/dev/null 2>&1 || true ;;
      *)          via ttyd stop >/dev/null 2>&1 || true ;;
    esac
  fi
  if [ -n "${DEPLOY_ID:-}" ] && command -v ci_deactivate_deployment >/dev/null 2>&1; then
    ci_deactivate_deployment "${DEPLOY_ID}"
  fi

  # .env holds the login: give the repository back its own .env (with the
  # lines `via init` added gone too), or remove the one the action created.
  if [ -f "$state/env-seeded" ]; then
    if [ -f "$state/env.backup" ]; then
      cp -p "$state/env.backup" .env
    else
      rm -f .env
    fi
  fi

  rm -rf "$state"
}

# Run directly (the action's final step): do it now.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
  # shellcheck source=lib/ci.sh
  source "${SCRIPTS_DIR}/lib/ci.sh"
  cleanup_session
fi
