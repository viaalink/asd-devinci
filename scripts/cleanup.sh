#!/bin/bash
# Ends a session and puts the checkout back as it was. Logs one line per thing
# it did, or why there was nothing to do.
#
# Each part has a marker in STATE_DIR, written by the step that started it,
# and removed right after the part is done: a cleanup that is killed half way
# (cancel: SIGINT, then SIGTERM, then SIGKILL) leaves the rest to the next
# caller, the action's final if: always() step. When everything is done the
# directory keeps only `ended` (who ended the session, and when).
#
#   STATE_DIR      per-session state (credentials.sh)
#   SESSION_NAME   the published name
#   DEPLOY_ID      GitHub deployment to mark inactive (optional)
#   CLEANUP_BY     who calls, for the log ("keep-alive (cancelled)", ...)
#
# Markers: exposed, interface (terminal|codeserver), caddy-before,
# caddy-started,
# env-seeded (+ env.backup), tunnel-url.txt.

# Whether a Caddy process runs on this machine (0 = yes, 1 = no, 2 = cannot tell).
caddy_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x caddy >/dev/null 2>&1 && return 0 || return 1
  elif command -v tasklist >/dev/null 2>&1; then
    tasklist //FI "IMAGENAME eq caddy.exe" 2>/dev/null | grep -qi caddy && return 0 || return 1
  fi
  return 2
}

# Called before the action starts anything: was a Caddy already running?
note_caddy_before() {
  local rc=0
  caddy_running || rc=$?
  case "$rc" in
    0) echo yes > "${STATE_DIR}/caddy-before" ;;
    1) echo no > "${STATE_DIR}/caddy-before" ;;
    *) echo unknown > "${STATE_DIR}/caddy-before" ;;
  esac
}

# Called after a step that may start Caddy: mark it ours when none ran before.
note_caddy_started() {
  [ "$(cat "${STATE_DIR}/caddy-before" 2>/dev/null)" = "no" ] || return 0
  [ -f "${STATE_DIR}/caddy-started" ] && return 0
  if caddy_running; then
    touch "${STATE_DIR}/caddy-started"
  fi
}

cleanup_log() {
  echo "[cleanup] $*"
}

cleanup_session() {
  local state="${STATE_DIR:-}"
  local by="${CLEANUP_BY:-cleanup}"

  if [ -z "$state" ]; then
    cleanup_log "Nothing to do: no session state (the credentials step did not run or failed, so nothing was started)."
    return 0
  fi
  if [ ! -d "$state" ]; then
    cleanup_log "Nothing to do: ${state} does not exist (the session never got past the credentials step)."
    return 0
  fi
  if [ -f "$state/ended" ] && [ ! -f "$state/exposed" ] && [ ! -f "$state/interface" ] \
     && [ ! -f "$state/caddy-started" ] && [ ! -f "$state/env-seeded" ]; then
    cleanup_log "Nothing left to do: the session was already ended by $(cat "$state/ended")."
    return 0
  fi

  local did=0

  # 1. The exposure: after this the relay address is no longer public.
  if [ -f "$state/exposed" ]; then
    did=1
    if [ -n "${SESSION_NAME:-}" ] && via expose stop "${SESSION_NAME}" >/dev/null 2>&1; then
      cleanup_log "Stopped the exposure '${SESSION_NAME}' (via expose stop)."
    else
      cleanup_log "via expose stop '${SESSION_NAME:-}' failed; the relay drops the address when the runner disconnects."
    fi
    if [ -n "${SESSION_NAME:-}" ] && command -v jq >/dev/null 2>&1; then
      local listed
      listed=$(via expose list --json 2>/dev/null | jq -r --arg n "$SESSION_NAME" \
        'first(.exposed[]? | select(.id == $n or .name == $n) | .id) // empty' 2>/dev/null || true)
      if [ -n "$listed" ]; then
        cleanup_log "Warning: '${SESSION_NAME}' is still in via expose list."
      else
        cleanup_log "'${SESSION_NAME}' is no longer in via expose list."
      fi
    fi
    if [ -f "$state/tunnel-url.txt" ] && command -v curl >/dev/null 2>&1; then
      local url code
      url=$(head -1 "$state/tunnel-url.txt")
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)
      cleanup_log "The relay now answers HTTP ${code:-000} for the session address (401 while it was published)."
    fi
    rm -f "$state/exposed"
  fi

  # 2. The interface started by start-interface.sh.
  if [ -f "$state/interface" ]; then
    did=1
    case "$(cat "$state/interface")" in
      codeserver)
        if via codeserver stop >/dev/null 2>&1; then cleanup_log "Stopped VS Code (via codeserver stop)."
        else cleanup_log "via codeserver stop failed."; fi
        ;;
      *)
        if via ttyd stop >/dev/null 2>&1; then cleanup_log "Stopped the web terminal (via ttyd stop)."
        else cleanup_log "via ttyd stop failed."; fi
        ;;
    esac
    rm -f "$state/interface"
  fi

  # 3. Caddy, only when no Caddy ran before the action started one.
  if [ ! -f "$state/caddy-started" ] && [ -f "$state/caddy-before" ]; then
    case "$(cat "$state/caddy-before")" in
      yes) cleanup_log "Caddy left running: it was already running before this action started." ;;
      unknown) cleanup_log "Caddy left running: this runner has no pgrep/tasklist to tell whether this action started it." ;;
    esac
    rm -f "$state/caddy-before"
  fi
  if [ -f "$state/caddy-started" ]; then
    did=1
    if via caddy stop --force >/dev/null 2>&1; then
      cleanup_log "Stopped Caddy (started by this action)."
    else
      cleanup_log "via caddy stop failed."
    fi
    rm -f "$state/caddy-started" "$state/caddy-before"
  fi

  # 4. .env holds the login: give the repository back its own .env (the
  #    login lines and what `via init` added go with it), or remove the one
  #    the action created.
  if [ -f "$state/env-seeded" ]; then
    did=1
    if [ -f "$state/env.backup" ]; then
      cp -p "$state/env.backup" .env
      rm -f "$state/env.backup"
      cleanup_log "Restored the repository's own .env."
    else
      rm -f .env
      cleanup_log "Removed the .env this action created (the repository had none)."
    fi
    rm -f "$state/env-seeded"
  fi

  # 5. The deployment button.
  if [ -n "${DEPLOY_ID:-}" ] && command -v ci_deactivate_deployment >/dev/null 2>&1; then
    ci_deactivate_deployment "${DEPLOY_ID}"
    cleanup_log "Marked deployment ${DEPLOY_ID} inactive."
  fi

  rm -f "$state/tunnel-url.txt"
  if [ "$did" -eq 0 ]; then
    cleanup_log "Nothing to do: nothing was started yet (no markers in ${state})."
  fi
  echo "${by} at $(date -u '+%H:%M:%S UTC')" > "$state/ended"
}

# Run directly (the action's final step): do it now.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
  # shellcheck source=lib/ci.sh
  source "${SCRIPTS_DIR}/lib/ci.sh"
  CLEANUP_BY="${CLEANUP_BY:-the final step}"
  cleanup_session
fi
