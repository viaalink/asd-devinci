#!/bin/bash
# Checks on what the CLI and the relay hand back, before it is used.
# Sourced by connect.sh and expose.sh.

# An address from via expose list is used only when it is a plain https URL
# of a host (optionally a port and a trailing slash): no path, no query, no
# login part, no control characters. It goes into GITHUB_OUTPUT/GITHUB_ENV,
# where a line break would add a variable of its own.
relay_url_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/?$ ]]
}

# The HTTP status the address answers without credentials, as seen from the
# runner (certificates validated). Asked until the login answers or the tries
# run out: a new route can take a moment to reach the relay. Prints "401"
# only when the answer is 401 with a `WWW-Authenticate: Basic` challenge (the
# login in front of the route); an app's own 401 without it prints
# "401 without a Basic login challenge". Otherwise the last status.
login_probe() {
  local url="$1" code="000" i hdr
  hdr=$(mktemp)
  for i in $(seq 1 "${LOGIN_PROBE_TRIES:-15}"); do
    : > "$hdr"
    code=$(curl -s -o /dev/null -D "$hdr" -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)
    if [ "$code" = "401" ]; then
      if tr -d '\r' < "$hdr" | grep -qiE '^www-authenticate:[[:space:]]*basic([[:space:]]|$)'; then
        break
      fi
      code="401 without a Basic login challenge"
    fi
    [ "$i" -lt "${LOGIN_PROBE_TRIES:-15}" ] && sleep "${LOGIN_PROBE_INTERVAL:-2}"
  done
  rm -f "$hdr"
  echo "${code:-000}"
}
