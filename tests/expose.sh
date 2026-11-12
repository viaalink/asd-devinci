#!/bin/bash
# The expose feature against a stub `via`: the expose input is checked (ports,
# names, count, the auth word) and nothing in it is ever run as code; the
# addresses come out as the `urls` output and VIAALINK_URL_<NAME>; and every
# exposure is stopped when the session ends: after a failed step, on cancel
# (interactive mode) and in the post step (background mode, job end).
#
# Run: bash tests/expose.sh   (needs bash, jq, node; no network, no real CLI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAILS=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

INTERVAL=$(( 4000 + RANDOM % 900 ))
CANARY="$(mktemp -d)/pwned"

make_stubs() {
  local t="$1"
  mkdir -p "$t/bin" "$t/fake/exposed.d"
  # via: one file per exposed name in $FAKE/exposed.d; expose list prints them.
  # FAKE_FAIL_NAME: the expose of a name starting with it publishes nothing.
  cat > "$t/bin/via" <<'EOF'
#!/bin/bash
echo "via $*" >> "$FAKE/calls"
case "$1 ${2:-}" in
  "init --yes")
    cp .env .env.bak; chmod 600 .env.bak
    printf '\n# .env hygiene (added by .via)\n.env\n' >> .gitignore
    mkdir -p "${VIA_WORKSPACE_DIR:-workspace}" .via ;;
  "ttyd start")  touch "$FAKE/ttyd" "$FAKE/caddy" ;;
  "ttyd stop")   rm -f "$FAKE/ttyd" ;;
  "caddy stop")  rm -f "$FAKE/caddy" ;;
  "expose stop") rm -f "$FAKE/exposed.d/$3" "$FAKE/exposed" ;;
  "expose list")
    rows=""
    for f in "$FAKE"/exposed.d/*; do
      [ -e "$f" ] || continue
      n=$(basename "$f")
      rows="${rows:+$rows,}{\"id\":\"$n\",\"name\":\"$n\",\"url\":\"https://$n-ci.relay.example.com/\",\"alive\":true,\"state\":\"online\",\"appUp\":$(cat "$f")}"
    done
    if [ -f "$FAKE/exposed" ]; then
      rows="${rows:+$rows,}{\"id\":\"demo\",\"name\":\"demo\",\"url\":\"https://demo-ci.relay.example.com/\",\"alive\":true,\"state\":\"online\"}"
    fi
    echo "{\"exposed\":[${rows}]}" ;;
  "expose ttyd") touch "$FAKE/exposed" "$FAKE/caddy" ;;
  "expose "[0-9]*)
    echo "$4" > "$FAKE/auth-$3"
    touch "$FAKE/caddy"
    if [ -n "${FAKE_FAIL_NAME:-}" ] && [[ "$3" == "$FAKE_FAIL_NAME"* ]]; then exit 0; fi
    if [ -f "$FAKE/app-down" ]; then echo false > "$FAKE/exposed.d/$3"; else echo true > "$FAKE/exposed.d/$3"; fi ;;
esac
exit 0
EOF
  cat > "$t/bin/pgrep" <<'EOF'
#!/bin/bash
[ "$*" = "-x caddy" ] && [ -f "$FAKE/caddy" ]
EOF
  # curl: 200 while the address's name is exposed, 404 after.
  cat > "$t/bin/curl" <<'EOF'
#!/bin/bash
url="${*: -1}"; host="${url#https://}"; n="${host%%-ci.*}"
if [ -f "$FAKE/exposed.d/$n" ] || { [ "$n" = demo ] && [ -f "$FAKE/exposed" ]; }; then printf 200; else printf 404; fi
EOF
  chmod +x "$t/bin/"*
}

# credentials.sh with the given expose input (and optional overrides as
# KEY=VALUE arguments). Prints its output; the exit status is the script's.
cred() {
  local spec="$1"; shift
  env INPUT_TUNNEL_KEY=k INPUT_TUNNEL_KEY_ID=i INPUT_TUNNEL_HOST=h INPUT_HOST_KEY_FINGERPRINTS=SHA256:x \
    INPUT_PASSWORD=pw INPUT_USERNAME=via INPUT_INTERFACE=none INPUT_MODE=background \
    INPUT_CLI_VERSION=latest GITHUB_SHA=abcdef1234 INPUT_TIMEOUT_MINUTES=0 \
    RUNNER_TEMP="${CRED_TEMP:-$(mktemp -d)}" GITHUB_ACTIONS="" GITLAB_CI="" SCRIPTS_DIR="$SCRIPTS" \
    INPUT_EXPOSE="$spec" "$@" bash "$SCRIPTS/credentials.sh" 2>&1
}
accepted() { cred "$@" >/dev/null; }
refused() { ! cred "$@" >/dev/null; }

echo "# 1. The expose input: what is accepted"
CRED_TEMP="$(mktemp -d)"
OUT1="$(CRED_TEMP="$CRED_TEMP" cred $'# the app\n3000 shop\n\n8080   webhooks  public  # Mollie\r\n09 api login')"
SPEC="$CRED_TEMP/via-cicd-abcdef1/expose-spec"
check "three services counted" grep -q "services to expose: 3" <<<"$OUT1"
check "spec has three lines" test "$(wc -l < "$SPEC" | tr -d ' ')" = 3
check "port, name, login, published name (tab separated)" \
  grep -qE $'^3000\tshop\tlogin\tshop-[0-9a-f]{16}$' "$SPEC"
check "public kept" grep -qE $'^8080\twebhooks\tpublic\twebhooks-[0-9a-f]{16}$' "$SPEC"
check "leading zeros are base 10" grep -qE $'^9\tapi\tlogin\t' "$SPEC"
check "interface none runs the CLI outside the checkout" grep -q "project_dir=.*/via-cicd-abcdef1/project" <<<"$OUT1"
R1=$(cut -f4 "$SPEC" | head -1)
CRED_TEMP2="$(mktemp -d)"
CRED_TEMP="$CRED_TEMP2" cred "3000 shop" >/dev/null
R2=$(cut -f4 "$CRED_TEMP2/via-cicd-abcdef1/expose-spec")
check "the random part differs per run" test "$R1" != "$R2"
check "a 32-character name is accepted" accepted "1 $(printf 'a%.0s' $(seq 32))"
check "ten services are accepted" accepted "$(for i in $(seq 10); do echo "$((3000 + i)) s$i public"; done)"
check "public only, interface none: no password needed" accepted "8080 hooks public" INPUT_PASSWORD=
check "port 65535 accepted" accepted "65535 top"

echo "# 2. The expose input: what is refused"
check "port 0" refused "0 shop"
check "port 65536" refused "65536 shop"
check "port not a number" refused "web shop"
check "name with capitals" refused "3000 Shop"
check "name with an underscore" refused "3000 my_shop"
check "name with a leading hyphen" refused "3000 -shop"
check "name with a trailing hyphen" refused "3000 shop-"
check "a 33-character name" refused "1 $(printf 'a%.0s' $(seq 33))"
check "a missing name" refused "3000"
check "an unknown third word" refused "3000 shop open"
check "a fourth word" refused "3000 shop public extra"
check "a name used twice" refused $'3000 shop\n3001 shop public'
check "eleven services" refused "$(for i in $(seq 11); do echo "$((3000 + i)) s$i public"; done)"
check "a login service without a password" refused "3000 shop" INPUT_PASSWORD=
check "interface none without services" refused ""
check "an unknown interface" refused "3000 shop" INPUT_INTERFACE=shell
check "an unknown mode" refused "3000 shop" INPUT_MODE=detached
check "timeout-minutes in background mode" refused "3000 shop" INPUT_TIMEOUT_MINUTES=5
check "a terminal still needs a password" refused "" INPUT_INTERFACE=terminal INPUT_PASSWORD=

echo "# 3. Nothing in the expose input runs as code"
for attempt in \
  "3000 \$(touch $CANARY)" \
  "3000 \`touch $CANARY\`" \
  "3000 shop;touch $CANARY" \
  "3000 shop public && touch $CANARY" \
  "3000 shop|touch $CANARY" \
  "\$(touch $CANARY) shop" \
  "3000 \${IFS}shop" \
  "3000 shop'\"" \
  "3000 shop > $CANARY" \
  "3000 sh*p" \
  $'3000 shop\n$(touch '"$CANARY"')' ; do
  OUT=$(cred "$attempt" || true)
  check "refused: $(printf '%q' "$attempt")" bash -c "! grep -q 'services to expose' <<<\"\$1\"" _ "$OUT"
  check "and the error does not repeat the line" bash -c "! grep -qF -- 'touch' <<<\"\$1\"" _ "$OUT"
done
check "no injected command ran" test ! -e "$CANARY"

echo "# 4. expose.sh: addresses as the urls output and VIAALINK_URL_<NAME>"
T4="$(mktemp -d)"
make_stubs "$T4"
mkdir -p "$T4/state" "$T4/project"
printf '3000\tshop\tlogin\tshop-0123456789abcdef\n8080\tmy-hooks\tpublic\tmy-hooks-fedcba9876543210\n' > "$T4/state/expose-spec"
echo no > "$T4/state/caddy-before"
: > "$T4/out"; : > "$T4/env"; : > "$T4/summary"
EXPOSE4="$(cd "$T4/project" && FAKE="$T4/fake" PATH="$T4/bin:$PATH" STATE_DIR="$T4/state" SESSION_NAME=demo \
  SESSION_MODE=background SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS=true GITHUB_OUTPUT="$T4/out" \
  GITHUB_ENV="$T4/env" GITHUB_STEP_SUMMARY="$T4/summary" bash "$SCRIPTS/expose.sh" 2>&1)" || fail "expose.sh failed: $EXPOSE4"
URLS4=$(grep '^urls=' "$T4/out" | cut -d= -f2-)
check "urls is JSON keyed by the given names" \
  test "$(jq -r '.shop' <<<"$URLS4")" = "https://shop-0123456789abcdef-ci.relay.example.com"
check "and has no trailing slash" test "$(jq -r '."my-hooks"' <<<"$URLS4")" = "https://my-hooks-fedcba9876543210-ci.relay.example.com"
check "urls is one line" test "$(grep -c '^urls=' "$T4/out")" = 1
check "VIAALINK_URL_SHOP in the job env" grep -qxF "VIAALINK_URL_SHOP=https://shop-0123456789abcdef-ci.relay.example.com" "$T4/env"
check "VIAALINK_URL_MY_HOOKS (hyphen to underscore)" grep -qxF "VIAALINK_URL_MY_HOOKS=https://my-hooks-fedcba9876543210-ci.relay.example.com" "$T4/env"
check "VIAALINK_URLS holds the JSON" grep -qxF "VIAALINK_URLS=$URLS4" "$T4/env"
check "login service exposed with --auth=basic" test "$(cat "$T4/fake/auth-shop-0123456789abcdef")" = "--auth=basic"
check "public service exposed with --auth=none" test "$(cat "$T4/fake/auth-my-hooks-fedcba9876543210")" = "--auth=none"
check "both noted for the cleanup" test "$(wc -l < "$T4/state/exposures" | tr -d ' ')" = 2
check "summary lists both" test "$(grep -c 'relay.example.com' "$T4/summary")" = 2
check "the log names no password or login" bash -c "! grep -qi 'pw\|password=' <<<\"\$1\"" _ "$EXPOSE4"

echo "# 4b. A service whose port answers nothing yet: published, with a warning"
T4B="$(mktemp -d)"
make_stubs "$T4B"
mkdir -p "$T4B/state" "$T4B/project"; touch "$T4B/fake/app-down"
printf '3000\tshop\tlogin\tshop-0123456789abcdef\n' > "$T4B/state/expose-spec"
OUT4B="$(cd "$T4B/project" && FAKE="$T4B/fake" PATH="$T4B/bin:$PATH" STATE_DIR="$T4B/state" SESSION_NAME=demo \
  SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/expose.sh" 2>&1)" || true
check "warns that nothing answers on the port yet" grep -q "Nothing answers on port 3000 yet" <<<"$OUT4B"

echo "# 5. A failed expose step stops what it already exposed"
T5="$(mktemp -d)"
make_stubs "$T5"
mkdir -p "$T5/state" "$T5/project"
printf '3000\tshop\tlogin\tshop-0123456789abcdef\n8080\thooks\tpublic\thooks-fedcba9876543210\n' > "$T5/state/expose-spec"
set +e
OUT5="$(cd "$T5/project" && FAKE="$T5/fake" FAKE_FAIL_NAME=hooks PATH="$T5/bin:$PATH" STATE_DIR="$T5/state" \
  SESSION_NAME=demo SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/expose.sh" 2>&1)"
RC5=$?
set -e
check "the step fails" test "$RC5" -ne 0
check "and says why, without claiming success" grep -q "is not published through the relay" <<<"$OUT5"
check "the first service is stopped" grep -qx "via expose stop shop-0123456789abcdef" "$T5/fake/calls"
check "the half-published one too" grep -qx "via expose stop hooks-fedcba9876543210" "$T5/fake/calls"
check "logged per exposure" test "$(grep -c "Stopped the exposure" <<<"$OUT5")" = 2
check "the address answers 404 after" grep -q "now answers HTTP 404 for https://shop-0123456789abcdef" <<<"$OUT5"
check "no exposure marker left" test ! -e "$T5/state/exposures"

# A whole session in a project directory: prepare + expose (+ terminal).
start_session() {
  local t="$1" iface="$2"
  mkdir -p "$t/repo" "$t/state"
  printf 'MINE=1\n' > "$t/repo/.env"
  printf '.env\n' > "$t/repo/.gitignore"
  git -C "$t/repo" init -q
  git -C "$t/repo" add .gitignore
  git -C "$t/repo" -c user.name=t -c user.email=t@t commit -qm init
  printf '3000\tshop\tlogin\tshop-0123456789abcdef\n8080\thooks\tpublic\thooks-fedcba9876543210\n' > "$t/state/expose-spec"
  export FAKE="$t/fake" STATE_DIR="$t/state" SESSION_NAME=demo SESSION_INTERFACE="$iface" \
    VIA_WORKSPACE_DIR="$t/repo/workspace" SESSION_TARGET=ttyd SESSION_USERNAME=via \
    SESSION_PASSWORD='p a$s"w' SESSION_SHELL=bash VIA_BASIC_AUTH_USERNAME=via \
    VIA_BASIC_AUTH_PASSWORD='p a$s"w' SESSION_TIMEOUT_MINUTES=0 SCRIPTS_DIR="$SCRIPTS" \
    PATH="$t/bin:$PATH" GITHUB_ACTIONS="" GITLAB_CI=""
  (cd "$t/repo" && bash "$SCRIPTS/start-interface.sh" >"$t/start.log" 2>&1)
  if [ "$iface" != none ]; then (cd "$t/repo" && bash "$SCRIPTS/connect.sh" >"$t/connect.log" 2>&1); fi
  (cd "$t/repo" && bash "$SCRIPTS/expose.sh" >"$t/expose.log" 2>&1)
}

echo "# 6. Interactive, terminal + services, cancelled: everything is stopped"
T6="$(mktemp -d)"
make_stubs "$T6"
start_session "$T6" terminal
check "terminal and two services up" test -f "$T6/fake/exposed" -a -f "$T6/fake/exposed.d/shop-0123456789abcdef" -a -f "$T6/fake/exposed.d/hooks-fedcba9876543210"
set -m
(cd "$T6/repo" && KEEPALIVE_INTERVAL="$INTERVAL" exec bash "$SCRIPTS/keepalive.sh" >"$T6/keepalive.log" 2>&1) &
KA=$!
set +m
for _ in $(seq 50); do grep -q "Session is up" "$T6/keepalive.log" 2>/dev/null && break; sleep 0.1; done
sleep 0.2
kill -INT "$KA"
for _ in $(seq 150); do kill -0 "$KA" 2>/dev/null || break; sleep 0.1; done
wait "$KA" 2>/dev/null || true
check "the terminal's exposure stopped" grep -q "Stopped the exposure 'demo'" "$T6/keepalive.log"
check "shop stopped" grep -q "Stopped the exposure 'shop-0123456789abcdef'" "$T6/keepalive.log"
check "hooks stopped" grep -q "Stopped the exposure 'hooks-fedcba9876543210'" "$T6/keepalive.log"
check "nothing exposed any more" test -z "$(ls -A "$T6/fake/exposed.d")"
check "addresses answer 404" test "$(grep -c 'now answers HTTP 404 for https://' "$T6/keepalive.log")" = 2
check ".env restored" test "$(cat "$T6/repo/.env")" = "MINE=1"
check "checkout clean" test -z "$(git -C "$T6/repo" status --porcelain)"
check "no keep-alive sleep left" bash -c "! ps -eo args= | grep -qx 'sleep ${INTERVAL}'"

echo "# 7. Background, interface none: the post step ends it at job end"
T7="$(mktemp -d)"
make_stubs "$T7"
mkdir -p "$T7/state/project"
start_session_none() {
  printf '3000\tshop\tlogin\tshop-0123456789abcdef\n8080\thooks\tpublic\thooks-fedcba9876543210\n' > "$T7/state/expose-spec"
  export FAKE="$T7/fake" STATE_DIR="$T7/state" SESSION_NAME=demo SESSION_INTERFACE=none \
    VIA_WORKSPACE_DIR="$T7/state/project/workspace" SESSION_USERNAME=via SESSION_PASSWORD='pw' \
    SESSION_SHELL=bash SCRIPTS_DIR="$SCRIPTS" PATH="$T7/bin:$PATH" GITHUB_ACTIONS="" GITLAB_CI=""
  (cd "$T7/state/project" && bash "$SCRIPTS/start-interface.sh" >"$T7/start.log" 2>&1)
  (cd "$T7/state/project" && bash "$SCRIPTS/expose.sh" >"$T7/expose.log" 2>&1)
}
start_session_none
check "no terminal started" bash -c "! grep -q 'ttyd start' '$T7/fake/calls'"
check "no interface marker" test ! -e "$T7/state/interface"
check "no ttyd login lines in the session's .env" bash -c "! grep -q TTYD '$T7/state/project/.env'"
check "both services up" test "$(ls "$T7/fake/exposed.d" | wc -l | tr -d ' ')" = 2
# The runner runs post.js with the helper's inputs as INPUT_* (and the
# job's GITHUB_* env). Here: a later step failed and the job is ending.
POST7="$(env -u STATE_DIR -u SESSION_NAME FAKE="$T7/fake" PATH="$T7/bin:$PATH" GITHUB_ACTIONS="" \
  "INPUT_STATE-DIR=$T7/state" "INPUT_PROJECT-DIR=$T7/state/project" "INPUT_SESSION-NAME=demo" \
  "INPUT_SCRIPTS-DIR=$SCRIPTS" "INPUT_XDG-CONFIG-HOME=$T7/state/cli/config" \
  "INPUT_WORKSPACE-DIR=$T7/state/project/workspace" INPUT_USERNAME=via INPUT_PASSWORD=pw \
  node "$ROOT/post/post.js" 2>&1)"
check "post step: shop stopped" grep -q "Stopped the exposure 'shop-0123456789abcdef'" <<<"$POST7"
check "post step: hooks stopped" grep -q "Stopped the exposure 'hooks-fedcba9876543210'" <<<"$POST7"
check "post step: Caddy stopped" grep -q "Stopped Caddy (started by this action)" <<<"$POST7"
check "post step names itself" grep -q "the post step (job end)" "$T7/state/ended"
check "nothing exposed any more" test -z "$(ls -A "$T7/fake/exposed.d")"
POST7B="$(env FAKE="$T7/fake" PATH="$T7/bin:$PATH" GITHUB_ACTIONS="" "INPUT_STATE-DIR=$T7/state" \
  "INPUT_PROJECT-DIR=$T7/state/project" "INPUT_SESSION-NAME=demo" "INPUT_SCRIPTS-DIR=$SCRIPTS" \
  node "$ROOT/post/post.js" 2>&1)"
check "a second post step finds nothing left" grep -q "Nothing left to do" <<<"$POST7B"

echo "# 7b. Background, cancelled while a later step runs: the final step leaves it to post"
check "action.yml's final step skips background mode unless failed or cancelled" \
  grep -qF "if: always() && (steps.credentials.outputs.mode != 'background' || failure() || cancelled())" "$ROOT/action.yml"
check "the helper's post runs always (failure and cancel too)" grep -qF "post-if: 'always()'" "$ROOT/post/action.yml"

echo "# 8. stage-post.sh puts the helper next to the checkout, not in it"
T8="$(mktemp -d)"
mkdir -p "$T8/work/repo/repo"
STAGE8="$(GITHUB_WORKSPACE="$T8/work/repo/repo" SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/stage-post.sh" 2>&1)"
check "helper staged where action.yml uses it (./../.via-cicd-post)" \
  test -f "$T8/work/repo/.via-cicd-post/action.yml" -a -f "$T8/work/repo/.via-cicd-post/post.js"
check "the checkout is untouched" test -z "$(ls -A "$T8/work/repo/repo")"
check "action.yml uses that path" grep -qF "uses: ./../.via-cicd-post" "$ROOT/action.yml"
check "and says so" grep -q "ends at the end of the job" <<<"$STAGE8"

echo "# 9. No input is inlined into a run: script"
INLINED="$(awk '/^ *run: /{print FILENAME":"NR": "$0}' "$ROOT/action.yml" | grep -F '${{' || true)"
check "every run: line is free of \${{ }} (${INLINED:-none})" test -z "$INLINED"

rm -rf "$CRED_TEMP" "$CRED_TEMP2" "$T4" "$T4B" "$T5" "$T6" "$T7" "$T8" "$(dirname "$CANARY")"
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
