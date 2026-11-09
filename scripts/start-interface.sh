#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# Port of the CLI terminal workflow's "Start the interface" step. The username
# and password were checked by credentials.sh. The login also reaches this
# step as step env (ASD_BASIC_AUTH_*, ASD_TTYD_*, ASD_CODESERVER_*), so the
# CLI does not depend on reading it back from .env.

ci_group_start "Starting the session interface (${SESSION_INTERFACE})"

# A .env value, double-quoted with \ " $ ` escaped: the CLI's .env reader and
# bash `source` both read back exactly what was written.
envq() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//\$/\\\$}
  v=${v//\`/\\\`}
  printf '"%s"' "$v"
}

# Seed .env first: via init keeps values that are already there. Appended, so
# a .env the repository already has is kept. The session login is the
# project login (ASD_BASIC_AUTH_*): Caddy's login in front of the terminal and
# of the published route is that one, and without it `via init` generates a
# hub login the laptop does not know (every request answered 401).
{
  echo "ASD_BASIC_AUTH_USERNAME=${SESSION_USERNAME}"
  echo "ASD_BASIC_AUTH_PASSWORD=$(envq "$SESSION_PASSWORD")"
  echo "ASD_TTYD_USERNAME=${SESSION_USERNAME}"
  echo "ASD_TTYD_PASSWORD=$(envq "$SESSION_PASSWORD")"
  echo "ASD_TTYD_SHELL_CMD=$(envq "$SESSION_SHELL")"
  if [ "$SESSION_INTERFACE" = "codeserver" ]; then
    echo "ASD_CODESERVER_AUTH=password"
    echo "ASD_CODESERVER_PASSWORD=$(envq "$SESSION_PASSWORD")"
  fi
} >> .env
chmod 600 .env
via init --yes

if [ "$SESSION_INTERFACE" = "codeserver" ]; then
  via codeserver start
  PORT_VAR=ASD_CODESERVER_PORT
else
  via ttyd start
  PORT_VAR=ASD_TTYD_PORT
fi

# What via expose publishes: on Linux/macOS the web terminal listens on its
# socket, not a port, so the service itself (via expose ttyd <name>);
# elsewhere the interface's port.
PORT=""
if [ "$SESSION_INTERFACE" != "codeserver" ] && [ "$CI_RUNNER_OS" != "Windows" ]; then
  TARGET=ttyd
else
  PORT=$(grep -E "^${PORT_VAR}=" .env | tail -1 | cut -d= -f2-)
  if [ -z "$PORT" ]; then
    ci_error "${PORT_VAR} is not in .env after the interface started."
    exit 1
  fi
  TARGET="$PORT"
fi
ci_set_env "SESSION_TARGET" "${TARGET}"
ci_set_env "SESSION_PORT" "${PORT}"
ci_set_output "port" "${PORT}"

echo "Interface: ${SESSION_INTERFACE}, published as: ${TARGET}"
ci_group_end
