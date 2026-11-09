#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Checks every input before anything is installed or started, so a missing
# secret fails in seconds with the steps to fix it. Error messages never
# repeat an input's value: they are fixed text.

ci_group_start "Checking relay credentials"

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
[ -n "${INPUT_PASSWORD:-}" ] || missing="$missing password (VIA_TERMINAL_PASSWORD)"
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
case "${INPUT_SHELL:-bash}" in
  bash|zsh|powershell) ;;
  *)
    ci_error "shell must be bash, zsh or powershell."
    exit 1
    ;;
esac

case "${INPUT_INTERFACE:-terminal}" in
  terminal|codeserver) ;;
  *)
    ci_error "interface must be terminal or codeserver."
    exit 1
    ;;
esac

# latest, a release tag or a nightly tag (the installer is handed this value).
if ! [[ "${INPUT_CLI_VERSION:-latest}" =~ ^(latest|v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$ ]]; then
  ci_error "cli-version must be latest, a release tag (vX.Y.Z) or a nightly tag (vX.Y.Z-nightly.YYYYMMDDTHHMM)."
  exit 1
fi

# 0 (or 00, ...) means no limit. Base 10, so 08 is eight, not an octal error.
TIMEOUT="${INPUT_TIMEOUT_MINUTES:-0}"
if ! [[ "$TIMEOUT" =~ ^[0-9]{1,6}$ ]]; then
  ci_error "timeout-minutes must be a whole number of minutes (0 = no limit)."
  exit 1
fi
TIMEOUT=$((10#$TIMEOUT))

NAME="${INPUT_TUNNEL_NAME:-${GITHUB_SHA:0:7}}"
if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  ci_error "tunnel-name is not a DNS label (lowercase letters, digits and inner hyphens)."
  exit 1
fi

# Per-session state (the .env backup, markers, the URL file) lives outside the
# repository checkout.
STATE_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-terminal-${NAME}"
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Step outputs, not job env: nothing of this leaks into the caller's steps.
ci_set_output "session_name" "${NAME}"
ci_set_output "interface" "${INPUT_INTERFACE:-terminal}"
ci_set_output "timeout_minutes" "${TIMEOUT}"
ci_set_output "state_dir" "${STATE_DIR}"

echo "Session: ${NAME} (${INPUT_INTERFACE:-terminal})"

ci_group_end
