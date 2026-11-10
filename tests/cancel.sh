#!/bin/bash
# Simulates a session and a cancelled run against a stub `via`, and checks
# that the session really ends: exposure stopped, interface and the Caddy the
# action started stopped, the repository's .env restored, no sleep left, and
# a cleanup log line for each of those, and nothing via init left in the
# checkout (.env backups, .gitignore lines, workspace/, .asd/). Then the same with a keep-alive that
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
  "init --yes")
    # As the real via init: a copy of .env before each rewrite (with the
    # login in it), its .gitignore rules, its runtime state directories.
    cp .env .env.bak; cp .env .env.bak.1; chmod 600 .env.bak .env.bak.1
    echo "ADDED_BY_INIT=1" >> .env
    printf '\n# .env hygiene (added by .asd)\n.env\n.env.*\n!.env.example\n' >> .gitignore
    mkdir -p "${ASD_WORKSPACE_DIR:-workspace}/caddy" .asd/workspace ;;
  "ttyd start")      touch "$FAKE/ttyd" "$FAKE/caddy" ;;
  "ttyd stop")       [ ! -f "$FAKE/fail-ttyd-stop" ] || exit 1; rm -f "$FAKE/ttyd" ;;
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
  # A repository with its own .gitignore, as a checkout has.
  if [ ! -d "$t/repo/.git" ]; then
    printf '.env\n' > "$t/repo/.gitignore"
    git -C "$t/repo" init -q
    git -C "$t/repo" add .gitignore
    git -C "$t/repo" -c user.name=t -c user.email=t@t commit -qm init
  fi
  export FAKE="$t/fake" STATE_DIR="$t/state" SESSION_NAME=demo SESSION_INTERFACE=terminal \
    ASD_WORKSPACE_DIR="$t/repo/workspace" \
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
check "no .env backup left (they hold the login)" bash -c "! ls -A '$T1/repo' | grep -q '^\.env\.bak'"
check ".env backups logged as removed" grep -q "Removed .env.bak.1 (a copy of the session's .env" "$T1/keepalive.log"
check ".gitignore reverted and logged" grep -q "Reverted .gitignore" "$T1/keepalive.log"
check "workspace/ removed and logged" grep -q "Removed workspace/" "$T1/keepalive.log"
check ".asd/ removed and logged" grep -q "Removed .asd/" "$T1/keepalive.log"
check "checkout is clean (git status)" test -z "$(git -C "$T1/repo" status --porcelain)"
check "no keep-alive sleep left" no_sleep_left
check "final step says why there is nothing left" \
  grep -q "Nothing left to do: the session was already ended by the keep-alive step (cancelled)" <<<"$FINAL1"

echo "# 1c. Keep-alive stopped after its last part, before ended (self-hosted)"
T1C="$(mktemp -d)"
make_stubs "$T1C"
start_session "$T1C"
(cd "$T1C/repo" && PATH="$T1C/bin:$PATH" CLEANUP_BY="the keep-alive step (cancelled)" \
  bash "$SCRIPTS/cleanup.sh" >/dev/null 2>&1)
rm -f "$T1C/state/ended"   # killed before it could write ended
FINAL1C="$(cd "$T1C/repo" && PATH="$T1C/bin:$PATH" DEPLOY_ID=123 bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "final step still marks the deployment inactive" grep -q "Marked deployment 123 inactive" <<<"$FINAL1C"
check "final step says the keep-alive step ended the session" \
  grep -q "Nothing left to do: the session was already ended by the keep-alive step (cancelled)" <<<"$FINAL1C"
check "and not that nothing was started" bash -c "! grep -q 'nothing was started yet' <<<\"\$1\"" _ "$FINAL1C"
check "a third caller says the same" \
  grep -q "already ended by the keep-alive step (cancelled)" <<<"$(cd "$T1C/repo" && PATH="$T1C/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"

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
check "final step removes the .env backups" bash -c "! ls -A '$T2/repo' | grep -q '^\.env\.bak'"
check "final step leaves the checkout clean" test -z "$(git -C "$T2/repo" status --porcelain)"

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
check "no .env backup left" bash -c "! ls -A '$T4/repo' | grep -q '^\.env\.bak'"

echo "# 4b. What the repository had before is kept: its .env backup, workspace/, .asd/"
T4B="$(mktemp -d)"
make_stubs "$T4B"
mkdir -p "$T4B/repo/workspace" "$T4B/repo/.asd"
printf 'OLD_BACKUP=1\n' > "$T4B/repo/.env.bak"
printf 'keep\n' > "$T4B/repo/workspace/mine.txt"
start_session "$T4B"
FINAL4B="$(cd "$T4B/repo" && PATH="$T4B/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "the repository's .env.bak is back as it was" test "$(cat "$T4B/repo/.env.bak")" = "OLD_BACKUP=1"
check "and logged as restored" grep -q "Restored the repository's own .env.bak" <<<"$FINAL4B"
check "the new .env.bak.1 is removed" test ! -e "$T4B/repo/.env.bak.1"
check "workspace/ that was there is kept" test -f "$T4B/repo/workspace/mine.txt"
check "and the log says why" grep -q "Left workspace/ in place: it was there before" <<<"$FINAL4B"
check ".asd/ that was there is kept" test -d "$T4B/repo/.asd"

echo "# 4c. A .gitignore edited beyond via init's lines is left alone"
T4C="$(mktemp -d)"
make_stubs "$T4C"
start_session "$T4C"
printf 'changed in the session\n' > "$T4C/repo/.gitignore"
FINAL4C="$(cd "$T4C/repo" && PATH="$T4C/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check ".gitignore keeps the session's edit" test "$(cat "$T4C/repo/.gitignore")" = "changed in the session"
check "and the log says why" grep -q "Left .gitignore as it is" <<<"$FINAL4C"

echo "# 4d. A repository without .gitignore: the one via init created is removed"
T4D="$(mktemp -d)"
make_stubs "$T4D"
mkdir -p "$T4D/repo"
git -C "$T4D/repo" init -q
git -C "$T4D/repo" -c user.name=t -c user.email=t@t commit -qm init --allow-empty
start_session "$T4D"
FINAL4D="$(cd "$T4D/repo" && PATH="$T4D/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "no .gitignore left" test ! -e "$T4D/repo/.gitignore"
check "and logged" grep -q "Removed the .gitignore via init created" <<<"$FINAL4D"

echo "# 4e. The repository's symlinks named .env.bak* (a dangling one too) are kept"
T4E="$(mktemp -d)"
make_stubs "$T4E"
mkdir -p "$T4E/repo"
ln -s /nonexistent/target "$T4E/repo/.env.bak.link"
printf 'TARGET=1\n' > "$T4E/repo/target"
start_session "$T4E"
(cd "$T4E/repo" && PATH="$T4E/bin:$PATH" bash "$SCRIPTS/cleanup.sh" >/dev/null 2>&1)
check "dangling .env.bak.link kept" test "$(readlink "$T4E/repo/.env.bak.link")" = "/nonexistent/target"
T4K="$(mktemp -d)"
make_stubs "$T4K"
mkdir -p "$T4K/repo" "$T4K/outside"
printf 'ORIG=1\n' > "$T4K/outside/file"
ln -s "$T4K/outside/file" "$T4K/repo/.env.bak"
start_session "$T4K"   # the stub via init writes the session .env through the link
check "via init wrote the login through the link (test premise)" grep -q "ASD_BASIC_AUTH_PASSWORD" "$T4K/outside/file"
FINAL4K="$(cd "$T4K/repo" && PATH="$T4K/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "the link is kept" test "$(readlink "$T4K/repo/.env.bak")" = "$T4K/outside/file"
check "the file it points to has its own content again" test "$(cat "$T4K/outside/file")" = "ORIG=1"
check "and that is logged" grep -q "Restored the content of the file .env.bak links to" <<<"$FINAL4K"
T4F="$(mktemp -d)"
make_stubs "$T4F"
mkdir -p "$T4F/repo"
printf 'TARGET=1\n' > "$T4F/repo/target"
ln -s target "$T4F/repo/.env.bak"
start_session "$T4F"
rm -f "$T4F/repo/.env.bak"; printf 'SESSION\n' > "$T4F/repo/.env.bak"   # replaced by a plain file
FINAL4F="$(cd "$T4F/repo" && PATH="$T4F/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "symlinked .env.bak is a symlink again" test "$(readlink "$T4F/repo/.env.bak")" = "target"
check "and logged as restored" grep -q "Restored the repository's own .env.bak" <<<"$FINAL4F"

echo "# 4f. An incomplete note never deletes the repository's own backups"
T4G="$(mktemp -d)"
make_stubs "$T4G"
mkdir -p "$T4G/repo"
printf 'REPO_OWN=1\n' > "$T4G/repo/.env.bak"
start_session "$T4G"
rm -rf "$T4G/state/checkout"     # a cleanup killed half way, the old order
printf 'REPO_OWN=1\n' > "$T4G/repo/.env.bak"
FINAL4G="$(cd "$T4G/repo" && PATH="$T4G/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "the repository's .env.bak is still there" test "$(cat "$T4G/repo/.env.bak")" = "REPO_OWN=1"
check "and the log says why nothing was removed" grep -q "the note of what the repository had is incomplete" <<<"$FINAL4G"
T4H="$(mktemp -d)"
make_stubs "$T4H"
start_session "$T4H"
: > "$T4H/state/checkout/root"
FINAL4H="$(cd "$T4H/repo" && PATH="$T4H/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "an empty checkout path removes nothing" test -d "$T4H/repo/workspace"
check "and says so" grep -q "no usable checkout path" <<<"$FINAL4H"

echo "# 4g. A failed restore keeps the note for the next try"
T4I="$(mktemp -d)"
make_stubs "$T4I"
mkdir -p "$T4I/repo"
printf 'REPO_OWN=1\n' > "$T4I/repo/.env.bak"
start_session "$T4I"
rm -f "$T4I/repo/.env.bak"; mkdir -p "$T4I/repo/.env.bak/x"   # cannot be put back over
FINAL4I="$(cd "$T4I/repo" && PATH="$T4I/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "the failure is logged" grep -q "could not restore the repository's own .env.bak" <<<"$FINAL4I"
check "the note and its copy are kept" test -f "$T4I/state/checkout-noted" -a -f "$T4I/state/checkout/files/.env.bak"
rm -rf "$T4I/repo/.env.bak"
(cd "$T4I/repo" && PATH="$T4I/bin:$PATH" bash "$SCRIPTS/cleanup.sh" >/dev/null 2>&1)
check "the next cleanup restores it" test "$(cat "$T4I/repo/.env.bak")" = "REPO_OWN=1"
check "and drops the note" test ! -e "$T4I/state/checkout-noted"

echo "# 4h. workspace/ stays when stopping the interface failed"
T4J="$(mktemp -d)"
make_stubs "$T4J"
start_session "$T4J"
touch "$T4J/fake/fail-ttyd-stop"
FINAL4J="$(cd "$T4J/repo" && PATH="$T4J/bin:$PATH" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "workspace/ left" test -d "$T4J/repo/workspace"
check "and the log says why" grep -q "Left workspace/: via ttyd stop failed" <<<"$FINAL4J"
check "the .env backups still go" test ! -e "$T4J/repo/.env.bak"

echo "# 6. The CLI is installed for this job only, never over the runner's own"
T6="$(mktemp -d)"
mkdir -p "$T6/home/.local/bin" "$T6/bin" "$T6/state"
printf '#!/bin/sh\necho runner-own\n' > "$T6/home/.local/bin/via"
chmod +x "$T6/home/.local/bin/via"
# curl stub serving an installer that, like the real one, falls back to
# ~/.local/bin and ~/.local/share/via when INSTALL_DIR / ASD_HOME are unset.
cat > "$T6/bin/curl" <<'STUB'
#!/bin/bash
cat <<'INSTALLER'
set -eu
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
home="${ASD_HOME:-$HOME/.local/share/via}"
mkdir -p "$INSTALL_DIR" "$home/bin"
printf '#!/bin/sh\necho job-cli\n' > "$home/bin/asd"; chmod +x "$home/bin/asd"
ln -sfn "$home/bin/asd" "$INSTALL_DIR/via"
[ -n "${ASD_NO_MODIFY_PATH:-}" ] || echo 'export PATH=x' >> "$HOME/.bashrc"
INSTALLER
STUB
chmod +x "$T6/bin/curl"
: > "$T6/path"; : > "$T6/env"
INSTALL6="$(HOME="$T6/home" PATH="$T6/bin:$PATH" GITHUB_ACTIONS=true GITHUB_PATH="$T6/path" \
  GITHUB_ENV="$T6/env" STATE_DIR="$T6/state" REQUESTED_VERSION=latest SCRIPTS_DIR="$SCRIPTS" \
  bash "$SCRIPTS/install-cli.sh" 2>&1)" || true
check "the runner's ~/.local/bin/via is untouched" test "$("$T6/home/.local/bin/via")" = "runner-own"
check "nothing in the runner's ~/.local/share" test ! -e "$T6/home/.local/share"
check "no shell profile edited" test ! -e "$T6/home/.bashrc"
check "the job's via is in the state directory" test "$("$T6/state/cli/bin/via")" = "job-cli"
check "the job's PATH gets that directory" grep -qxF "$T6/state/cli/bin" "$T6/path"
check "the job's ASD_HOME points at it" grep -qxF "ASD_HOME=$T6/state/cli/home" "$T6/env"
check "the job's VIA_HOME points at it" grep -qxF "VIA_HOME=$T6/state/cli/home" "$T6/env"
check "XDG_CONFIG_HOME is not set for the job" bash -c "! grep -q '^XDG_CONFIG_HOME=' '$T6/env'"
check "and says so" grep -q "Installed for this job only" <<<"$INSTALL6"

echo "# 5. Nothing started: the final step says so"
FINAL5="$(STATE_DIR="" bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "explains why there is nothing to do" grep -q "Nothing to do: no session state" <<<"$FINAL5"

rm -rf "$T1" "$T1B" "$T1C" "$T2" "$T3" "$T4" "$T4B" "$T4C" "$T4D" "$T4E" "$T4K" "$T4F" "$T4G" "$T4H" "$T4I" "$T4J" "$T6"
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
