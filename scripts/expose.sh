#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"
# shellcheck source=cleanup.sh
source "${SCRIPTS_DIR}/cleanup.sh"
# shellcheck source=lib/relay-checks.sh
source "${SCRIPTS_DIR}/lib/relay-checks.sh"

# Publishes the services of the `expose` input through the relay, one
# `via expose <port> <name>-<random> --auth=basic|none` each, and hands their
# addresses to the rest of the job: the `urls` output (JSON, name -> URL) and
# VIAALINK_URL_<NAME> in GITHUB_ENV. credentials.sh checked every line and
# wrote STATE_DIR/expose-spec: port, name, login|public, published name,
# tab separated. Nothing here comes from an input unchecked, and nothing is
# evaluated.
#
# Each published name goes into STATE_DIR/exposures before `via expose`
# runs, so a cleanup (failed step, cancel, the post step) stops it even when
# this step is killed half way.

ci_group_start "Exposing services"

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    CLEANUP_BY="the expose step (failed)" cleanup_session
  fi
}
trap on_exit EXIT

SPEC="${STATE_DIR}/expose-spec"
if [ ! -s "$SPEC" ]; then
  echo "No services to expose."
  ci_group_end
  exit 0
fi

URLS='{}'
SUMMARY=""
# fd 3: via must not read the list from stdin.
while IFS=$'\t' read -r port name auth published <&3; do
  [ -n "$published" ] || continue
  if [ "$auth" = "public" ]; then
    flag="--auth=none"
    what="public, no login"
  else
    flag="--auth=basic"
    what="login"
  fi

  echo "$published" >> "${STATE_DIR}/exposures"
  echo "Exposing port ${port} as ${name} (${what})"
  # via expose exits 1 both when the tunnel failed and when the tunnel is up
  # but the address does not answer yet (nothing listens on the port). Which
  # one it was is read from via expose list below, not from the exit code.
  rc=0
  via expose "$port" "$published" "$flag" < /dev/null || rc=$?
  note_caddy_started

  # The address depends on the relay (a shared relay appends the client id,
  # a dedicated one does not): read back from the CLI, never assembled.
  row=$(via expose list --json < /dev/null | jq -c --arg n "$published" \
    'first(.exposed[]? | select(.id == $n or .name == $n)) // empty')
  [ -n "$row" ] || row='{}'
  url=$(jq -r '.url // empty' <<< "$row")
  alive=$(jq -r '.alive // false' <<< "$row")
  state=$(jq -r '.state // empty' <<< "$row")
  app_up=$(jq -r 'if has("appUp") then (.appUp | tostring) else "unknown" end' <<< "$row")
  if [ -n "$url" ] && ! relay_url_ok "$url"; then
    ci_error "via expose list returned an address for ${name} that is not a plain https URL; refusing to use it."
    exit 1
  fi
  if [ -z "$url" ] || [ "$alive" != "true" ] || [ "$state" = "local" ] || [ "$state" = "not-running" ]; then
    ci_error "${name} is not published through the relay (via expose exited ${rc}; via expose list shows no running tunnel with an https address for it). See the via expose output above."
    exit 1
  fi
  url="${url%/}"
  printf '%s\t%s\n' "$published" "$url" >> "${STATE_DIR}/exposure-urls"
  # A login service must answer 401 without credentials. If not (no login
  # resolved, a via.yaml that turns logins off, ...), it is open: the step
  # fails and the trap takes every exposure of the session down.
  if [ "$auth" != "public" ]; then
    code=$(login_probe "$url")
    if [ "$code" != "401" ]; then
      ci_error "${name} was published, but a request without credentials gets HTTP ${code}, not 401 with the login's Basic challenge. It is taken down again: a service without public is never left open."
      exit 1
    fi
    echo "${name}: login in front checked (HTTP 401 without credentials)."
  fi
  if [ "$app_up" = "false" ]; then
    ci_warning "Nothing answers on port ${port} yet: ${name} is published, but requests get HTTP 502 until your app listens there."
  elif [ "$rc" -ne 0 ]; then
    ci_warning "${name} is published (its tunnel runs), but its address did not answer when via expose checked it (exit ${rc}). See the via expose output above."
  fi

  URLS=$(jq -c --arg k "$name" --arg v "$url" '. + {($k): $v}' <<< "$URLS")
  env_name="VIAALINK_URL_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  ci_set_env "$env_name" "$url"
  echo "${name}: ${url}  (${what}; \$${env_name})"
  SUMMARY+="| \`${name}\` | ${port} | ${url} | ${what} |"$'\n'
done 3< "$SPEC"

ci_set_output "urls" "$URLS"
ci_set_env "VIAALINK_URLS" "$URLS"

if [ "${SESSION_MODE:-interactive}" = "background" ]; then
  UNTIL="They stay up until the job ends; the action's post step then takes them down."
else
  UNTIL="They stay up while the session runs."
fi
ci_set_summary "$(cat << EOF2
## Exposed services

| Name | Port | Address | Access |
|------|------|---------|--------|
${SUMMARY}
${UNTIL} Services with a login use the action's username and password.
EOF2
)"

ci_group_end
