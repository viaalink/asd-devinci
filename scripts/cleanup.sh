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
# env-seeded (+ env.backup), checkout-noted (+ checkout/), stop-failed,
# tunnel-url.txt.

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

# What `via init` writes into the checkout besides .env: a copy of .env before
# each rewrite (.env.bak, .env.bak.1, ...: mode 0600, with the login in it),
# lines appended to .gitignore, its runtime state in the workspace directory
# (ASD_WORKSPACE_DIR, workspace/ in action.yml) and .asd/. Called in the
# checkout before the action seeds .env: notes which of these the repository
# already had, and keeps a copy of its backups and .gitignore, so the cleanup
# removes or reverts only what the session added. `complete` is written last:
# a snapshot without it is never acted on.
note_checkout_before() {
  local snap="${STATE_DIR}/checkout" f d
  rm -rf "$snap"
  mkdir -p "$snap/files"
  pwd -P > "$snap/root"
  : > "$snap/had-files"
  for f in .env.bak .env.bak.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    echo "$f" >> "$snap/had-files"
    # Files and symlinks (dangling ones too) are kept as they are; a
    # directory by that name is only noted, and never touched.
    if [ -L "$f" ] || [ -f "$f" ]; then cp -P -p "$f" "$snap/files/$f"; fi
    # A link to a regular file: via init writes the session .env (with the
    # login) through it into that file, which may be outside the checkout.
    # Keep the file's content too.
    if [ -L "$f" ] && [ -f "$f" ]; then cp -p "$f" "$snap/files/$f.link-target"; fi
  done
  if [ -f .gitignore ]; then
    cp -p .gitignore "$snap/gitignore"
  else
    touch "$snap/no-gitignore"
  fi
  : > "$snap/dirs"
  : > "$snap/had-dirs"
  local ws="${ASD_WORKSPACE_DIR:-$PWD/workspace}"
  # Windows: github.workspace is D:\a\..., Git Bash's PWD is /d/a/...
  if command -v cygpath >/dev/null 2>&1; then ws=$(cygpath -u "$ws"); fi
  for d in "$ws" "$PWD/.asd"; do
    echo "$d" >> "$snap/dirs"
    if [ -e "$d" ] || [ -L "$d" ]; then echo "$d" >> "$snap/had-dirs"; fi
  done
  touch "$snap/complete"
  touch "${STATE_DIR}/checkout-noted"
}

# The physical path of $1 without following $1 itself (it may be a symlink
# the session made): its parent resolved, `.` and `..` gone. Empty when the
# parent does not exist or the last part is `.` or `..`.
physical_path() {
  local base parent
  base=$(basename -- "$1")
  case "$base" in .|..|/) return 0 ;; esac
  parent=$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 0
  if [ "$parent" = / ]; then echo "/$base"; else echo "$parent/$base"; fi
}

# Removes the .env backups, .gitignore lines and directories the session
# added (see note_checkout_before), and puts back the repository's own.
# Runs after the interface, the exposure and Caddy stopped; works in the
# checkout the snapshot was taken in. Returns non-zero when something could
# not be restored: the caller then keeps the snapshot for the next try.
restore_checkout() {
  local state="$1" snap="$1/checkout" root
  local f
  for f in complete root had-files dirs had-dirs; do
    if [ ! -f "$snap/$f" ]; then
      cleanup_log "Left the checkout's .env backups, .gitignore, workspace/ and .asd/ as they are: the note of what the repository had is incomplete (${f} missing), so nothing can be told apart."
      return 0
    fi
  done
  root=$(cat "$snap/root")
  if [ -z "$root" ] || [ "$root" = / ] || [ ! -d "$root" ]; then
    cleanup_log "Left the checkout's .env backups, .gitignore, workspace/ and .asd/ as they are: no usable checkout path in the note (${root:-empty})."
    return 0
  fi
  ( cd -- "$root" && restore_checkout_in_root "$state" "$snap" "$root" )
}

restore_checkout_in_root() {
  local state="$1" snap="$2" root="$3" f d rel real failed=0

  # .env backups: the CLI's copies of the session .env hold the login.
  for f in .env.bak .env.bak.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if grep -qxF -- "$f" "$snap/had-files"; then continue; fi
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      cleanup_log "Left ${f}/: a directory, not one of the .env copies via init writes."
      continue
    fi
    if rm -f -- "$f"; then
      cleanup_log "Removed ${f} (a copy of the session's .env, with the login, written by via init)."
    else
      cleanup_log "Warning: could not remove ${f}; it holds the session login."
      failed=1
    fi
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local kept="$snap/files/$f"
    [ -e "$kept" ] || [ -L "$kept" ] || continue  # a directory: never touched
    if [ -L "$kept" ]; then
      [ -L "$f" ] && [ "$(readlink -- "$f")" = "$(readlink -- "$kept")" ] && continue
    elif [ -f "$f" ] && [ ! -L "$f" ] && cmp -s -- "$kept" "$f"; then
      continue
    fi
    if rm -f -- "$f" && cp -P -p -- "$kept" "$f"; then
      cleanup_log "Restored the repository's own ${f}."
    else
      cleanup_log "Warning: could not restore the repository's own ${f}; its copy stays in ${snap}/files for the next try."
      failed=1
      continue
    fi
  done < "$snap/had-files"
  # Content of the files the repository's .env.bak* links point to (written
  # through by via init), put back through the link.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local was="$snap/files/$f.link-target"
    [ -f "$was" ] && [ -L "$f" ] || continue
    cmp -s -- "$was" "$f" && continue
    if cat -- "$was" > "$f"; then
      cleanup_log "Restored the content of the file ${f} links to (via init had written the session .env, with the login, into it)."
    else
      cleanup_log "Warning: could not restore the file ${f} links to; it may hold the session login. Its copy stays in ${snap}/files for the next try."
      failed=1
    fi
  done < "$snap/had-files"

  # .gitignore: via init appends its .env and .asd rules.
  if [ -f "$snap/gitignore" ]; then
    local size appended=0
    size=$(wc -c < "$snap/gitignore" | tr -d ' ')
    if [ -f .gitignore ] && ! cmp -s "$snap/gitignore" .gitignore; then
      # The original, then more lines: what via init does. (No head -c 0:
      # BSD head rejects it; an empty original is a prefix of anything.)
      if [ "$size" -eq 0 ] || head -c "$size" .gitignore | cmp -s - "$snap/gitignore"; then
        appended=1
      fi
    fi
    if [ ! -f .gitignore ]; then
      if cp -p "$snap/gitignore" .gitignore; then
        cleanup_log "Restored the repository's own .gitignore (it was gone)."
      else
        cleanup_log "Warning: could not restore .gitignore; its copy stays in ${snap} for the next try."
        failed=1
      fi
    elif cmp -s "$snap/gitignore" .gitignore; then
      :
    elif [ "$appended" -eq 1 ]; then
      if cp -p "$snap/gitignore" .gitignore; then
        cleanup_log "Reverted .gitignore: removed the lines via init appended."
      else
        cleanup_log "Warning: could not revert .gitignore; its copy stays in ${snap} for the next try."
        failed=1
      fi
    else
      cleanup_log "Left .gitignore as it is: it changed beyond the lines via init appends (edited during the session?)."
    fi
  elif [ -f "$snap/no-gitignore" ] && [ -f .gitignore ]; then
    if grep -q '(added by \.asd)' .gitignore; then
      rm -f .gitignore
      cleanup_log "Removed the .gitignore via init created (the repository had none)."
    else
      cleanup_log "Left .gitignore: the repository had none, but this one was not written by via init."
    fi
  fi

  # Directories: only ones that did not exist before, inside the checkout,
  # and only when everything that ran from them was stopped.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rel="${d#"$root"/}"
    if grep -qxF -- "$d" "$snap/had-dirs"; then
      cleanup_log "Left ${rel}/ in place: it was there before the session."
      continue
    fi
    [ -e "$d" ] || [ -L "$d" ] || continue
    real=$(physical_path "$d")
    case "$real" in
      "$root"/?*) ;;
      *) cleanup_log "Left ${d}: it is outside the checkout."; continue ;;
    esac
    rel="${real#"$root"/}"
    if [ -f "$state/stop-failed" ]; then
      cleanup_log "Left ${rel}/: $(cat "$state/stop-failed") failed, so a process may still run from it."
      continue
    fi
    if rm -rf -- "$real"; then
      cleanup_log "Removed ${rel}/ (the CLI's runtime state, created by this session)."
    else
      cleanup_log "Warning: could not remove ${rel}/ completely."
    fi
  done < "$snap/dirs"

  return "$failed"
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
     && [ ! -f "$state/caddy-started" ] && [ ! -f "$state/env-seeded" ] \
     && [ ! -f "$state/checkout-noted" ]; then
    cleanup_log "Nothing left to do: the session was already ended by $(cat "$state/ended")."
    return 0
  fi

  local did=0

  # 1. The exposure: after this the relay address is no longer public.
  if [ -f "$state/exposed" ]; then
    did=1
    # A failed expose stop does not set stop-failed: the tunnel client runs
    # from the CLI's install (RUNNER_TEMP), not from workspace/, and the
    # relay drops the address when the runner disconnects.
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
        else cleanup_log "via codeserver stop failed."; echo "via codeserver stop" > "$state/stop-failed"; fi
        ;;
      *)
        if via ttyd stop >/dev/null 2>&1; then cleanup_log "Stopped the web terminal (via ttyd stop)."
        else cleanup_log "via ttyd stop failed."; echo "via ttyd stop" > "$state/stop-failed"; fi
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
      echo "via caddy stop" > "$state/stop-failed"
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

  # 5. What via init added next to .env: its backups of .env (with the
  #    login), its .gitignore lines, workspace/ and .asd/.
  #    The marker goes before the note it points to: a cleanup killed in
  #    between leaves no marker, never a marker without its note.
  if [ -f "$state/checkout-noted" ]; then
    did=1
    if restore_checkout "$state"; then
      rm -f "$state/checkout-noted"
      rm -rf "$state/checkout"
    else
      cleanup_log "Kept the note of the repository's own files in ${state}: the next cleanup tries again."
    fi
  fi

  # 6. The deployment button.
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
