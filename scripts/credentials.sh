#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Checks every input before anything is installed or started, so a missing
# secret fails in seconds with the steps to fix it. Error messages never
# repeat an input's value: they are fixed text.

ci_group_start "Checking relay credentials"

# Byte-wise character ranges: [a-z] is only a to z.
LC_ALL=C

# --- Masks, before any CLI step runs -------------------------------------
# GitHub masks secrets.* already; this also covers values passed another way
# and the encoded forms the CLI may put in a URL (user:pass@host).
ci_mask "${INPUT_TUNNEL_KEY:-}"
ci_mask "${INPUT_PASSWORD:-}"
if [ -n "${INPUT_PASSWORD:-}" ]; then
  # jq's @uri escapes everything but A-Za-z0-9-_.~; JavaScript's
  # encodeURIComponent (the CLI) also leaves !'()* as they are.
  ENC_PASS=$(printf '%s' "$INPUT_PASSWORD" | jq -sRr @uri)
  ENC_PASS_JS=$(printf '%s' "$ENC_PASS" | sed -e 's/%21/!/g' -e "s/%27/'/g" -e 's/%28/(/g' -e 's/%29/)/g' -e 's/%2A/*/g')
  ci_mask "$ENC_PASS"
  ci_mask "$ENC_PASS_JS"
fi

# --- Required secrets ------------------------------------------------------
missing=""
[ -n "${INPUT_TUNNEL_KEY:-}" ] || missing="$missing tunnel-key (VIA_TUNNEL_KEY)"
[ -n "${INPUT_TUNNEL_KEY_ID:-}" ] || missing="$missing tunnel-key-id (VIA_TUNNEL_KEY_ID)"
[ -n "${INPUT_TUNNEL_HOST:-}" ] || missing="$missing tunnel-host (VIA_TUNNEL_HOST)"
[ -n "${INPUT_HOST_KEY_FINGERPRINTS:-}" ] || missing="$missing tunnel-host-key-fingerprints (VIA_TUNNEL_HOST_KEY_FINGERPRINTS)"
if [ -n "$missing" ]; then
  ci_error "Missing inputs:${missing}. Run 'via gh setup' in this repository on a device enrolled on your relay; it stores these as repository secrets. Then pass them as \${{ secrets.VIA_* }}."
  exit 1
fi

if [ -n "${INPUT_TUNNEL_PORT:-}" ] && ! [[ "$INPUT_TUNNEL_PORT" =~ ^[0-9]{1,5}$ ]]; then
  ci_error "tunnel-port must be a port number."
  exit 1
fi

# --- Values written to .env: no line breaks, known characters -------------
# The username goes into .env and the URL as it is.
if ! [[ "${INPUT_USERNAME:-}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  ci_error "The username input may hold only letters, digits, dots, underscores and hyphens."
  exit 1
fi
case "${INPUT_SHELL:-bash}" in
  bash|zsh|powershell) ;;
  *)
    ci_error "shell must be bash, zsh or powershell."
    exit 1
    ;;
esac

INTERFACE="${INPUT_INTERFACE:-terminal}"
case "$INTERFACE" in
  terminal|codeserver|none) ;;
  *)
    ci_error "interface must be terminal, codeserver or none."
    exit 1
    ;;
esac

# interactive: the step holds the job until it is cancelled or times out.
# background: the step returns once everything is published; the action's
# post step ends it all when the job ends (also on failure and cancel).
MODE="${INPUT_MODE:-interactive}"
case "$MODE" in
  interactive|background) ;;
  *)
    ci_error "mode must be interactive or background."
    exit 1
    ;;
esac

# latest, a release tag or a nightly tag (the installer is handed this value).
# Empty means the action's own default (DEFAULT_CLI_VERSION in action.yml).
CLI_VERSION="${INPUT_CLI_VERSION:-${DEFAULT_CLI_VERSION:-latest}}"
if ! [[ "$CLI_VERSION" =~ ^(latest|v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$ ]]; then
  ci_error "cli-version must be latest, a release tag (vX.Y.Z) or a nightly tag (vX.Y.Z-nightly.YYYYMMDDTHHMM)."
  exit 1
fi
# The action passes its settings as VIA_* environment variables, which the
# CLI reads from 3.2.0 on (it copies each VIA_X onto the name it reads inside).
if [[ "$CLI_VERSION" =~ ^v?([0-9]+)\.([0-9]+)\. ]]; then
  CLI_MAJOR=$((10#${BASH_REMATCH[1]})); CLI_MINOR=$((10#${BASH_REMATCH[2]}))
  if [ "$CLI_MAJOR" -lt 3 ] || { [ "$CLI_MAJOR" -eq 3 ] && [ "$CLI_MINOR" -lt 2 ]; }; then
    ci_error "cli-version must be 3.2.0 or later: older CLIs do not read the VIA_* settings this action passes."
    exit 1
  fi
fi

# 0 (or 00, ...) means no limit. Base 10, so 08 is eight, not an octal error.
TIMEOUT="${INPUT_TIMEOUT_MINUTES:-0}"
if ! [[ "$TIMEOUT" =~ ^[0-9]{1,6}$ ]]; then
  ci_error "timeout-minutes must be a whole number of minutes (0 = no limit)."
  exit 1
fi
TIMEOUT=$((10#$TIMEOUT))
if [ "$MODE" = "background" ] && [ "$TIMEOUT" -gt 0 ]; then
  ci_error "timeout-minutes applies to mode: interactive. In background mode everything ends with the job."
  exit 1
fi

NAME="${INPUT_TUNNEL_NAME:-${GITHUB_SHA:0:7}}"
if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  ci_error "tunnel-name is not a DNS label (lowercase letters, digits and inner hyphens)."
  exit 1
fi

# --- Services to expose ---------------------------------------------------
# One per line: <port> <name> [login|public]. Blank lines and # comments are
# skipped. Parsed with `read` (no eval, no globbing); every field is checked
# against a fixed pattern before it is used. Errors name the line number,
# never its content.
EXPOSE_MAX=10
EXPOSE_SPEC=""
EXPOSE_COUNT=0
NEEDS_LOGIN=0
[ "$INTERFACE" = "none" ] || NEEDS_LOGIN=1
SEEN_NAMES=" "
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  line="${line%%#*}"
  # Tabs count as spaces; anything but a-z, 0-9, hyphens and spaces is refused.
  line="${line//$'\t'/ }"
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  if ! [[ "$line" =~ ^[a-z0-9\ -]+$ ]]; then
    ci_error "expose line ${lineno}: only lowercase letters, digits, hyphens and spaces are allowed (<port> <name> [login|public])."
    exit 1
  fi
  port="" svc="" auth="" extra=""
  read -r port svc auth extra <<< "$line"
  if [ -n "$extra" ] || [ -z "$svc" ]; then
    ci_error "expose line ${lineno}: write <port> <name> [login|public], e.g. 3000 shop or 8080 webhooks public."
    exit 1
  fi
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
    ci_error "expose line ${lineno}: the port must be a number from 1 to 65535."
    exit 1
  fi
  port=$((10#$port))
  # A DNS label part: the published host is <name>-<random>.
  if ! [[ "$svc" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]]; then
    ci_error "expose line ${lineno}: the name must be 1 to 32 lowercase letters, digits and inner hyphens."
    exit 1
  fi
  case "${auth:-login}" in
    login) auth=login; NEEDS_LOGIN=1 ;;
    public) ;;
    *)
      ci_error "expose line ${lineno}: the third word must be login (the default) or public."
      exit 1
      ;;
  esac
  if [[ "$SEEN_NAMES" == *" ${svc} "* ]]; then
    ci_error "expose line ${lineno}: the name is used twice; each service needs its own."
    exit 1
  fi
  SEEN_NAMES+="${svc} "
  EXPOSE_COUNT=$((EXPOSE_COUNT + 1))
  if [ "$EXPOSE_COUNT" -gt "$EXPOSE_MAX" ]; then
    ci_error "expose lists more than ${EXPOSE_MAX} services."
    exit 1
  fi
  # A random part per service and per run (64 bits): the address cannot be
  # guessed from the name, and one leaked address does not give the others.
  rand=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if ! [[ "$rand" =~ ^[0-9a-f]{16}$ ]]; then
    ci_error "Could not read random bytes for the service addresses."
    exit 1
  fi
  EXPOSE_SPEC+="${port}"$'\t'"${svc}"$'\t'"${auth}"$'\t'"${svc}-${rand}"$'\n'
done <<< "${INPUT_EXPOSE:-}"

if [ "$INTERFACE" = "none" ] && [ "$EXPOSE_COUNT" -eq 0 ]; then
  ci_error "interface: none needs at least one service in expose."
  exit 1
fi

# The password is the login in front of the terminal, VS Code and every
# service exposed without `public`. Not needed when there is none of those.
if [ "$NEEDS_LOGIN" -eq 1 ]; then
  if [ -z "${INPUT_PASSWORD:-}" ]; then
    ci_error "Missing input: password (VIA_TERMINAL_PASSWORD). The terminal, VS Code and services exposed without public have a login in front. Run 'via gh setup' in this repository, then pass it as \${{ secrets.VIA_TERMINAL_PASSWORD }}."
    exit 1
  fi
fi
if [ -n "${INPUT_PASSWORD:-}" ]; then
  case "$INPUT_PASSWORD" in
    *$'\n'*|*$'\r'*)
      ci_error "The password holds a line break, which a .env value cannot. Store another one (via gh setup)."
      exit 1
      ;;
  esac
  if [[ "$INPUT_PASSWORD" =~ ^[[:space:]]*$ ]]; then
    ci_error "The password is only whitespace. Store another one (via gh setup)."
    exit 1
  fi
fi

# No password given (interface: none, every service public): the CLI still
# wants a project login before it starts Caddy (the hub's own routes, such
# as its database tool, are never served without one). A random one for
# this run, masked, never printed, used for nothing the user calls: what
# `via env init` would seed.
GENERATED_PASSWORD=""
if [ -z "${INPUT_PASSWORD:-}" ]; then
  GENERATED_PASSWORD=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  if ! [[ "$GENERATED_PASSWORD" =~ ^[0-9a-f]{48}$ ]]; then
    ci_error "Could not read random bytes for the session login."
    exit 1
  fi
  ci_mask "$GENERATED_PASSWORD"
fi

# Per-session state (the .env backup, markers, the URL file) lives outside the
# repository checkout, in a directory of this step alone: the session name,
# the step's id (GITHUB_ACTION) and a random part. Two sessions in one job
# (same tunnel-name, or both on the default short SHA) never share it, and
# nothing here ever deletes another session's state.
STATE_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
STEP_ID=$(printf '%s' "${GITHUB_ACTION:-step}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
STATE_RAND=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
if ! [[ "$STATE_RAND" =~ ^[0-9a-f]{12}$ ]]; then
  ci_error "Could not read random bytes for the session state directory."
  exit 1
fi
STATE_DIR="${STATE_ROOT}/via-cicd-${NAME}-${STEP_ID}-${STATE_RAND}"
# mkdir without -p: an existing directory (never expected) is refused, not reused.
if ! mkdir "$STATE_DIR" 2>/dev/null; then
  ci_error "The session state directory already exists; refusing to reuse another session's state. Run the step again."
  exit 1
fi
chmod 700 "$STATE_DIR"
printf '%s' "$EXPOSE_SPEC" > "${STATE_DIR}/expose-spec"

# Where the CLI runs (via init, .env, its state): the checkout when there is
# a terminal or VS Code to open in it; with interface: none a directory of
# the session's own, so the checkout is never touched.
if [ "$INTERFACE" = "none" ]; then
  PROJECT_DIR="${STATE_DIR}/project"
  mkdir -p "$PROJECT_DIR"
else
  PROJECT_DIR="${GITHUB_WORKSPACE:-$PWD}"
  # One terminal or VS Code session per checkout: a second one would rewrite
  # the same .env and share the same Caddy and web terminal. Refused while
  # another session of this action still has live markers there.
  for other in "${STATE_ROOT}"/via-cicd-*/; do
    other="${other%/}"
    [ "$other" != "$STATE_DIR" ] && [ -f "$other/project-dir" ] || continue
    [ "$(cat "$other/project-dir")" = "$PROJECT_DIR" ] || continue
    for marker in exposed exposures interface env-seeded checkout-noted caddy-started; do
      if [ -e "$other/$marker" ]; then
        rm -rf -- "$STATE_DIR"   # this step's own, just made
        ci_error "Another session of this action is still running in this checkout (a terminal or VS Code). Use interface: none for a second session in the same job, or end the first one before."
        exit 1
      fi
    done
  done
fi
printf '%s' "$PROJECT_DIR" > "${STATE_DIR}/project-dir"

ci_set_output "session_name" "${NAME}"
ci_set_output "interface" "${INTERFACE}"
ci_set_output "mode" "${MODE}"
ci_set_output "expose_count" "${EXPOSE_COUNT}"
ci_set_output "project_dir" "${PROJECT_DIR}"
ci_set_output "timeout_minutes" "${TIMEOUT}"
ci_set_output "cli_version" "${CLI_VERSION}"
ci_set_output "state_dir" "${STATE_DIR}"
# Masked above; a step output of this composite only (never declared).
ci_set_output "generated_password" "${GENERATED_PASSWORD}"

echo "Session: ${NAME} (interface: ${INTERFACE}, mode: ${MODE}, services to expose: ${EXPOSE_COUNT})"

ci_group_end
