#!/bin/bash
# Simulates a session and a cancelled run against a stub `via`, and checks
# that the session really ends: exposure stopped, interface and the Caddy the
# action started stopped, the repository's .env restored, no sleep left, and
# a cleanup log line for each of those. Then the same with a keep-alive that
# is killed outright (SIGKILL): the final step must do everything itself.
#
# Run: bash tests/cancel.sh   (needs bash, jq; no network, no real CLI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAILS=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

# A unique interval, so a leftover keep-alive sleep can be found by its args.
INTERVAL=$(( 3000 + RANDOM % 900 ))

make_stubs() {
  local t="$1"
  mkdir -p "$t/bin"
  # via: records calls; keeps fake state in $t/fake.
  cat > "$t/bin/via" <<'EOF'
#!/bin/bash
echo "via $*" >> "$FAKE/calls"
case "$1 ${2:-}" in
  "init --yes")      echo "ADDED_BY_INIT=1" >> .env ;;
  "ttyd start")      touch "$FAKE/ttyd" "$FAKE/caddy" ;;
  "ttyd stop")       rm -f "$FAKE/ttyd" ;;
  "codeserver stop") : ;;
  "caddy stop")      rm -f "$FAKE/caddy" ;;
  "expose stop")     rm -f "$FAKE/exposed" ;;
  "expose list")
    if [ -f "$FAKE/exposed" ]; then
      echo '{"exposed":[{"id":"demo","name":"demo","url":"https://demo-ci.relay.example.com/"}]}'
    else
      echo '{"exposed":[]}'
    fi ;;
  "expose ttyd"|"expose "[0-9]*) touch "$FAKE/exposed" ;;
esac
exit 0
EOF
  # pgrep: only answers for the fake Caddy (a real one on this machine must
  # not change the test).
  cat > "$t/bin/pgrep" <<'EOF'
#!/bin/bash
[ "$*" = "-x caddy" ] && [ -f "$FAKE/caddy" ]
EOF
  cat > "$t/bin/curl" <<'EOF'
#!/bin/bash
if [ -f "$FAKE/exposed" ]; then printf 401; else printf 404; fi
EOF
  chmod +x "$t/bin/"*
}

# Runs credentials-free steps of a session in $t/repo: start + publish.
start_session() {
  local t="$1"
  mkdir -p "$t/repo" "$t/fake" "$t/state"
  printf 'MINE=1\n' > "$t/repo/.env"
  export FAKE="$t/fake" STATE_DIR="$t/state" SESSION_NAME=demo SESSION_INTERFACE=terminal \
    SESSION_TARGET=ttyd SESSION_USERNAME=via SESSION_PASSWORD='p a$s"w' SESSION_SHELL=bash \
    ASD_BASIC_AUTH_USERNAME=via ASD_BASIC_AUTH_PASSWORD='p a$s"w' SESSION_TIMEOUT_MINUTES=0 \
    SCRIPTS_DIR="$SCRIPTS" PATH="$t/bin:$PATH" GITHUB_ACTIONS="" GITLAB_CI=""
  (cd "$t/repo" && bash "$SCRIPTS/start-interface.sh" >"$t/start.log" 2>&1)
  (cd "$t/repo" && bash "$SCRIPTS/connect.sh" >"$t/connect.log" 2>&1)
}

run_keepalive_bg() {
  local t="$1"
  # Job control on: without it a non-interactive shell starts background
  # jobs with SIGINT ignored, and an ignored signal cannot be trapped. The
  # runner's step process does not have that problem; the test must not
  # either.
  set -m
  (cd "$t/repo" && KEEPALIVE_INTERVAL="$INTERVAL" exec bash "$SCRIPTS/keepalive.sh" >"$t/keepalive.log" 2>&1) &
  KA_PID=$!
  set +m
  for _ in $(seq 50); do
    grep -q "Session is up" "$t/keepalive.log" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.2
}

# ps, not pgrep: the test puts a pgrep stub on PATH.
# Waits up to 15 s for a process to end; never hangs the test.
wait_gone() {
  local pid="$1"
  for _ in $(seq 150); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  return 1
}

no_sleep_left() { ! ps -eo args= | grep -qx "sleep ${INTERVAL}"; }

echo "# 1. Cancel: SIGINT to the keep-alive step, then the final step"
T1="$(mktemp -d)"
make_stubs "$T1"
start_session "$T1"
check "session published (exposed + interface + caddy markers)" \
  test -f "$T1/state/exposed" -a -f "$T1/state/interface" -a -f "$T1/state/caddy-started"
run_keepalive_bg "$T1"
kill -INT "$KA_PID"
check "keep-alive exits on SIGINT" wait_gone "$KA_PID"
FINAL1="$(cd "$T1/repo" && PATH="$T1/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "keep-alive logs that it ends the session" grep -q "Ending the session (cancelled)" "$T1/keepalive.log"
check "via expose stop ran" grep -qx "via expose stop demo" "$T1/fake/calls"
check "exposure logged as stopped" grep -q "Stopped the exposure 'demo'" "$T1/keepalive.log"
check "relay address checked after stop" grep -q "answers HTTP 404" "$T1/keepalive.log"
check "web terminal stopped and logged" grep -q "Stopped the web terminal" "$T1/keepalive.log"
check "Caddy stopped and logged" grep -q "Stopped Caddy (started by this action)" "$T1/keepalive.log"
check ".env restored and logged" grep -q "Restored the repository's own .env" "$T1/keepalive.log"
check ".env is exactly the repository's" test "$(cat "$T1/repo/.env")" = "MINE=1"
check "no keep-alive sleep left" no_sleep_left
check "final step says why there is nothing left" \
  grep -q "Nothing left to do: the session was already ended by the keep-alive step (cancelled)" <<<"$FINAL1"

echo "# 1b. Cancel arriving as SIGTERM (the runner's second signal)"
T1B="$(mktemp -d)"
make_stubs "$T1B"
start_session "$T1B"
run_keepalive_bg "$T1B"
kill -TERM "$KA_PID"
check "keep-alive exits on SIGTERM" wait_gone "$KA_PID"
check "exposure stopped on SIGTERM" grep -q "Stopped the exposure 'demo'" "$T1B/keepalive.log"
check ".env restored on SIGTERM" test "$(cat "$T1B/repo/.env")" = "MINE=1"
check "no keep-alive sleep left after SIGTERM" no_sleep_left

echo "# 2. Keep-alive killed outright (SIGKILL): the final step does it all"
T2="$(mktemp -d)"
make_stubs "$T2"
start_session "$T2"
run_keepalive_bg "$T2"
kill -KILL "$KA_PID"
wait_gone "$KA_PID" || true
pkill -f "^sleep ${INTERVAL}\$" 2>/dev/null || true  # the runner's orphan cleanup
FINAL2="$(cd "$T2/repo" && PATH="$T2/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "final step stops the exposure" grep -q "Stopped the exposure 'demo'" <<<"$FINAL2"
check "final step stops the web terminal" grep -q "Stopped the web terminal" <<<"$FINAL2"
check "final step stops Caddy" grep -q "Stopped Caddy" <<<"$FINAL2"
check "final step restores .env" test "$(cat "$T2/repo/.env")" = "MINE=1"

echo "# 3. A Caddy that ran before the action is left alone"
T3="$(mktemp -d)"
make_stubs "$T3"
mkdir -p "$T3/fake"
touch "$T3/fake/caddy"
start_session "$T3"
FINAL3="$(cd "$T3/repo" && PATH="$T3/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "Caddy not stopped" bash -c "! grep -q 'caddy stop' '$T3/fake/calls'"
check "and the log says why" grep -q "Caddy left running: it was already running" <<<"$FINAL3"

echo "# 4. No repository .env: the one the action created is removed"
T4="$(mktemp -d)"
make_stubs "$T4"
start_session "$T4"
rm -f "$T4/state/env.backup"
FINAL4="$(cd "$T4/repo" && PATH="$T4/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check ".env removed and logged" grep -q "Removed the .env this action created" <<<"$FINAL4"
check "no .env left" test ! -e "$T4/repo/.env"

echo "# 5. Nothing started: the final step says so"
FINAL5="$(STATE_DIR="" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "explains why there is nothing to do" grep -q "Nothing to do: no session state" <<<"$FINAL5"

rm -rf "$T1" "$T1B" "$T2" "$T3" "$T4"
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
