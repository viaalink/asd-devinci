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
# The login check retries without waiting here.
export LOGIN_PROBE_INTERVAL=0 LOGIN_PROBE_TRIES=3
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
      u="https://$n-ci.relay.example.com/"
      # FAKE/bad-url: the relay hands back something that is not a plain URL.
      [ -f "$FAKE/bad-url" ] && u=$(cat "$FAKE/bad-url")
      rows="${rows:+$rows,}$(jq -cn --arg n "$n" --arg u "$u" --argjson up "$(cat "$f")" \
        '{id: $n, name: $n, url: $u, alive: true, state: "online", appUp: $up}')"
    done
    if [ -f "$FAKE/exposed" ]; then
      rows="${rows:+$rows,}{\"id\":\"demo\",\"name\":\"demo\",\"url\":\"https://demo-ci.relay.example.com/\",\"alive\":true,\"state\":\"online\"}"
    fi
    echo "{\"exposed\":[${rows}]}" ;;
  "expose ttyd") echo "$4" > "$FAKE/auth-demo"; touch "$FAKE/exposed" "$FAKE/caddy" ;;
  "expose "[0-9]*)
    echo "$4" > "$FAKE/auth-$3"
    touch "$FAKE/caddy"
    if [ -n "${FAKE_FAIL_NAME:-}" ] && [[ "$3" == "$FAKE_FAIL_NAME"* ]]; then exit 1; fi
    # Like the CLI: exit 1 when the tunnel failed, and also when it is up but
    # the address does not answer (nothing on the port).
    if [ -f "$FAKE/app-down" ]; then echo false > "$FAKE/exposed.d/$3"; exit 1; fi
    echo true > "$FAKE/exposed.d/$3" ;;
esac
exit 0
EOF
  cat > "$t/bin/pgrep" <<'EOF'
#!/bin/bash
[ "$*" = "-x caddy" ] && [ -f "$FAKE/caddy" ]
EOF
  # curl: while the address's name is exposed, 401 without credentials when
  # it was exposed with --auth=basic (FAKE/fail-open: the login is missing,
  # 200), else 200; 404 after (FAKE/still-answers: 200 after the stop too).
  cat > "$t/bin/curl" <<'EOF'
#!/bin/bash
url="${*: -1}"; host="${url#https://}"; n="${host%%-ci.*}"
hdrfile=""; prev=""; for a in "$@"; do [ "$prev" = "-D" ] && hdrfile="$a"; prev="$a"; done
emit() {  # $1 = status, $2 = "basic" when the login challenges
  if [ -n "$hdrfile" ]; then
    { printf 'HTTP/2 %s\r\n' "$1"; [ "${2:-}" = basic ] && printf 'www-authenticate: Basic realm="restricted"\r\n'; printf '\r\n'; } > "$hdrfile"
  fi
  printf '%s' "$1"
}
if [ -f "$FAKE/exposed.d/$n" ] || { [ "$n" = demo ] && [ -f "$FAKE/exposed" ]; }; then
  creds=0; for a in "$@"; do [ "$a" = "-u" ] && creds=1; done
  if [ "$(cat "$FAKE/auth-$n" 2>/dev/null)" = "--auth=basic" ] && [ "$creds" = 0 ] && [ ! -f "$FAKE/fail-open" ]; then
    emit 401 basic
  elif [ -f "$FAKE/app-401" ]; then
    emit 401          # the app's own 401, no Basic challenge
  else
    emit 200
  fi
elif [ -f "$FAKE/still-answers" ]; then emit 200
else emit 404; fi
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
SPEC=$(echo "$CRED_TEMP"/via-cicd-abcdef1-*/expose-spec)
check "three services counted" grep -q "services to expose: 3" <<<"$OUT1"
check "spec has three lines" test "$(wc -l < "$SPEC" | tr -d ' ')" = 3
check "port, name, login, published name (tab separated)" \
  grep -qE $'^3000\tshop\tlogin\tshop-[0-9a-f]{16}$' "$SPEC"
check "public kept" grep -qE $'^8080\twebhooks\tpublic\twebhooks-[0-9a-f]{16}$' "$SPEC"
check "leading zeros are base 10" grep -qE $'^9\tapi\tlogin\t' "$SPEC"
check "interface none runs the CLI outside the checkout" grep -qE "project_dir=.*/via-cicd-abcdef1-[A-Za-z0-9_-]+-[0-9a-f]{12}/project" <<<"$OUT1"
R1=$(cut -f4 "$SPEC" | head -1)
CRED_TEMP2="$(mktemp -d)"
CRED_TEMP="$CRED_TEMP2" cred "3000 shop" >/dev/null
R2=$(cut -f4 "$CRED_TEMP2"/via-cicd-abcdef1-*/expose-spec)
check "the random part differs per run" test "$R1" != "$R2"
check "a 32-character name is accepted" accepted "1 $(printf 'a%.0s' $(seq 32))"
check "ten services are accepted" accepted "$(for i in $(seq 10); do echo "$((3000 + i)) s$i public"; done)"
check "public only, interface none: no password needed" accepted "8080 hooks public" INPUT_PASSWORD=
check "port 65535 accepted" accepted "65535 top"
: > "$CRED_TEMP/out"
GEN_LOG="$(cred "8080 hooks public" INPUT_PASSWORD= GITHUB_ACTIONS=true GITHUB_OUTPUT="$CRED_TEMP/out")"
GEN=$(grep '^generated_password=' "$CRED_TEMP/out" | cut -d= -f2-)
check "no password: a random login for the CLI (48 hex)" grep -qE '^[0-9a-f]{48}$' <<<"$GEN"
check "and it is masked" grep -qxF "::add-mask::${GEN}" <<<"$GEN_LOG"
: > "$CRED_TEMP/out"
cred "3000 shop" GITHUB_ACTIONS=true GITHUB_OUTPUT="$CRED_TEMP/out" >/dev/null
check "a given password: nothing generated" grep -qx 'generated_password=' "$CRED_TEMP/out"

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
check "and does not fail on via expose's exit 1" test -f "$T4B/state/exposure-urls"

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

echo "# 10. Two sessions in one job: each has its own state, nothing is shared"
T10="$(mktemp -d)"
OUT10A="$(CRED_TEMP="$T10" cred "8080 hooks public" GITHUB_ACTION=via1)"
DIR_A=$(sed -n 's/^OUTPUT: state_dir=//p' <<<"$OUT10A")
touch "$DIR_A/exposures"; echo "hooks-aaaa" > "$DIR_A/exposures"
OUT10B="$(CRED_TEMP="$T10" cred "8081 api public" GITHUB_ACTION=via2)"
DIR_B=$(sed -n 's/^OUTPUT: state_dir=//p' <<<"$OUT10B")
check "same session name, two state directories" test -n "$DIR_A" -a -n "$DIR_B" -a "$DIR_A" != "$DIR_B"
check "the step id is part of it" bash -c '[[ "$1" == *-via1-* && "$2" == *-via2-* ]]' _ "$DIR_A" "$DIR_B"
check "session 2 left session 1's markers alone" test "$(cat "$DIR_A/exposures")" = "hooks-aaaa"
OUT10C="$(CRED_TEMP="$T10" cred "8080 hooks public" GITHUB_ACTION=via1)"
DIR_C=$(sed -n 's/^OUTPUT: state_dir=//p' <<<"$OUT10C")
check "even the same step id twice gets a new directory" test -n "$DIR_C" -a "$DIR_C" != "$DIR_A"
check "and session 1's markers are still there" test -f "$DIR_A/exposures"
# A second terminal session in the same checkout is refused while one runs.
WS10="$T10/checkout"; mkdir -p "$WS10"
OUT10D="$(CRED_TEMP="$T10" cred "" INPUT_INTERFACE=terminal GITHUB_ACTION=t1 GITHUB_WORKSPACE="$WS10")"
DIR_D=$(sed -n 's/^OUTPUT: state_dir=//p' <<<"$OUT10D")
touch "$DIR_D/env-seeded"
check "a second terminal session in the same checkout is refused" \
  refused "" INPUT_INTERFACE=terminal GITHUB_ACTION=t2 GITHUB_WORKSPACE="$WS10" RUNNER_TEMP="$T10"
OUT10E="$(CRED_TEMP="$T10" cred "" INPUT_INTERFACE=terminal GITHUB_ACTION=t2 GITHUB_WORKSPACE="$WS10" || true)"
check "with a clear message" grep -q "Another session of this action is still running in this checkout" <<<"$OUT10E"
check "and the first session's state is untouched" test -f "$DIR_D/env-seeded"
check "an expose-only session next to it is fine" accepted "8080 hooks public" GITHUB_ACTION=t3 GITHUB_WORKSPACE="$WS10" RUNNER_TEMP="$T10"

echo "# 11. Two background sessions in one job: ending one leaves the other up"
T11="$(mktemp -d)"
make_stubs "$T11"
run_session() {  # $1 = state dir, $2 = spec line
  mkdir -p "$1/project"
  printf '%s\n' "$2" > "$1/expose-spec"
  (cd "$1/project" && FAKE="$T11/fake" PATH="$T11/bin:$PATH" STATE_DIR="$1" SESSION_NAME=abcdef1 \
    SESSION_INTERFACE=none SESSION_USERNAME=via SESSION_PASSWORD=pw SESSION_SHELL=bash \
    VIA_WORKSPACE_DIR="$1/project/workspace" SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" \
    bash "$SCRIPTS/start-interface.sh" >/dev/null 2>&1 && \
   cd "$1/project" && FAKE="$T11/fake" PATH="$T11/bin:$PATH" STATE_DIR="$1" SESSION_NAME=abcdef1 \
    VIA_BASIC_AUTH_USERNAME=via VIA_BASIC_AUTH_PASSWORD=pw SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" \
    bash "$SCRIPTS/expose.sh" >/dev/null 2>&1)
}
post_session() {  # $1 = state dir
  env FAKE="$T11/fake" PATH="$T11/bin:$PATH" GITHUB_ACTIONS="" "INPUT_STATE-DIR=$1" \
    "INPUT_PROJECT-DIR=$1/project" "INPUT_SESSION-NAME=abcdef1" "INPUT_SCRIPTS-DIR=$SCRIPTS" \
    INPUT_USERNAME=via INPUT_PASSWORD=pw node "$ROOT/post/post.js" 2>&1
}
S1="$T11/via-cicd-abcdef1-via1-aaaaaaaaaaaa"; S2="$T11/via-cicd-abcdef1-via2-bbbbbbbbbbbb"
run_session "$S1" $'8080\thooks\tpublic\thooks-1111111111111111'
run_session "$S2" $'8081\tapi\tlogin\tapi-2222222222222222'
check "both sessions published" test -f "$T11/fake/exposed.d/hooks-1111111111111111" -a -f "$T11/fake/exposed.d/api-2222222222222222"
POST11B="$(post_session "$S2")"
check "session 2's post step stops its own service" test ! -e "$T11/fake/exposed.d/api-2222222222222222"
check "and not session 1's" test -f "$T11/fake/exposed.d/hooks-1111111111111111"
check "session 2 never names session 1's service" bash -c "! grep -q hooks-1111 <<<\"\$1\"" _ "$POST11B"
POST11A="$(post_session "$S1")"
check "session 1's post step stops its service" test ! -e "$T11/fake/exposed.d/hooks-1111111111111111"
check "and says it now answers 404" grep -q "now answers HTTP 404 for https://hooks-1111111111111111" <<<"$POST11A"

echo "# 12. A login route that answers without the login is taken down"
T12="$(mktemp -d)"
make_stubs "$T12"; touch "$T12/fake/fail-open"
mkdir -p "$T12/state" "$T12/project"
printf '8080\thooks\tpublic\thooks-1111111111111111\n3000\tshop\tlogin\tshop-0123456789abcdef\n' > "$T12/state/expose-spec"
set +e
OUT12="$(cd "$T12/project" && FAKE="$T12/fake" PATH="$T12/bin:$PATH" STATE_DIR="$T12/state" SESSION_NAME=demo \
  SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/expose.sh" 2>&1)"; RC12=$?
set -e
check "the step fails" test "$RC12" -ne 0
check "and says the login is missing" grep -q "shop was published, but a request without credentials gets HTTP 200" <<<"$OUT12"
check "shop is taken down" test ! -e "$T12/fake/exposed.d/shop-0123456789abcdef"
check "and so is the rest of the session" test ! -e "$T12/fake/exposed.d/hooks-1111111111111111"
check "a public service is not probed for a login" bash -c "! grep -q 'hooks was published, but' <<<\"\$1\"" _ "$OUT12"
check "login services are exposed with --auth=basic" test "$(cat "$T12/fake/auth-shop-0123456789abcdef")" = "--auth=basic"
# The terminal: --auth=basic, and the same check.
T12B="$(mktemp -d)"
make_stubs "$T12B"
mkdir -p "$T12B/state" "$T12B/repo"
(cd "$T12B/repo" && FAKE="$T12B/fake" PATH="$T12B/bin:$PATH" STATE_DIR="$T12B/state" SESSION_NAME=demo \
  SESSION_INTERFACE=terminal SESSION_TARGET=ttyd VIA_BASIC_AUTH_USERNAME=via VIA_BASIC_AUTH_PASSWORD=pw \
  SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/connect.sh" >"$T12B/ok.log" 2>&1) || fail "connect.sh failed: $(cat "$T12B/ok.log")"
check "the terminal is exposed with --auth=basic" grep -qx "via expose ttyd demo --auth=basic" "$T12B/fake/calls"
check "and its login checked" grep -q "Login in front checked: HTTP 401" "$T12B/ok.log"
T12C="$(mktemp -d)"
make_stubs "$T12C"; touch "$T12C/fake/fail-open"
mkdir -p "$T12C/state" "$T12C/repo"
set +e
OUT12C="$(cd "$T12C/repo" && FAKE="$T12C/fake" PATH="$T12C/bin:$PATH" STATE_DIR="$T12C/state" SESSION_NAME=demo \
  SESSION_INTERFACE=terminal SESSION_TARGET=ttyd VIA_BASIC_AUTH_USERNAME=via VIA_BASIC_AUTH_PASSWORD=pw \
  SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/connect.sh" 2>&1)"; RC12C=$?
set -e
check "an open terminal fails the step" test "$RC12C" -ne 0
check "with a clear message" grep -q "terminal was published, but a request without credentials gets HTTP 200" <<<"$OUT12C"
check "and is taken down" test ! -e "$T12C/fake/exposed"
check "no url output was written for it" bash -c "! grep -q 'url_base=' <<<\"\$1\"" _ "$OUT12C"

echo "# 13. An address from the relay that is not a plain https URL is refused"
for bad in $'https://x.example.com/\nEVIL=1' "https://x.example.com/path" "http://x.example.com" \
           "https://user:pw@x.example.com" "https://x.example.com/?a=b" "https://X.example.com" "https://-x.example.com"; do
  T13="$(mktemp -d)"
  make_stubs "$T13"; printf '%s' "$bad" > "$T13/fake/bad-url"
  mkdir -p "$T13/state" "$T13/project"; : > "$T13/env"; : > "$T13/out"
  printf '8080\thooks\tpublic\thooks-1111111111111111\n' > "$T13/state/expose-spec"
  set +e
  OUT13="$(cd "$T13/project" && FAKE="$T13/fake" PATH="$T13/bin:$PATH" STATE_DIR="$T13/state" SESSION_NAME=demo \
    SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS=true GITHUB_ENV="$T13/env" GITHUB_OUTPUT="$T13/out" \
    GITHUB_STEP_SUMMARY=/dev/null bash "$SCRIPTS/expose.sh" 2>&1)"; RC13=$?
  set -e
  check "refused: $(printf '%q' "$bad")" test "$RC13" -ne 0
  check "  nothing written to GITHUB_ENV / GITHUB_OUTPUT" test ! -s "$T13/env" -a ! -s "$T13/out"
  check "  and says why" grep -q "is not a plain https URL; refusing to use it" <<<"$OUT13"
  rm -rf "$T13"
done
for good in "https://hooks-1a2b-ci.relay.example.com" "https://hooks.example.com/" "https://hooks.example.com:8443/"; do
  T13="$(mktemp -d)"; make_stubs "$T13"; printf '%s' "$good" > "$T13/fake/bad-url"
  mkdir -p "$T13/state" "$T13/project"
  printf '8080\thooks\tpublic\thooks-1111111111111111\n' > "$T13/state/expose-spec"
  check "accepted: $good" bash -c "cd '$T13/project' && FAKE='$T13/fake' PATH='$T13/bin:$PATH' STATE_DIR='$T13/state' SESSION_NAME=demo SCRIPTS_DIR='$SCRIPTS' GITHUB_ACTIONS= bash '$SCRIPTS/expose.sh' >/dev/null 2>&1"
  rm -rf "$T13"
done

echo "# 14. An address that still answers after the stop is a loud warning"
T14="$(mktemp -d)"
make_stubs "$T14"
mkdir -p "$T14/state"
echo "hooks-1111111111111111" > "$T14/state/exposures"
printf 'hooks-1111111111111111\thttps://hooks-1111111111111111-ci.relay.example.com\n' > "$T14/state/exposure-urls"
touch "$T14/fake/still-answers"
OUT14="$(cd "$T14" && FAKE="$T14/fake" PATH="$T14/bin:$PATH" STATE_DIR="$T14/state" GITHUB_ACTIONS=true \
  bash "$SCRIPTS/cleanup.sh" 2>&1)"
check "a run warning, not a quiet line" grep -q "^::warning::https://hooks-1111111111111111-ci.relay.example.com still answers HTTP 200 after the exposure was stopped (404 expected)." <<<"$OUT14"

rm -rf "$T10" "$T11" "$T12" "$T12B" "$T12C" "$T14"

echo "# 15. Two sessions, two CLIs: each post step uses its own session's CLI"
T15="$(mktemp -d)"
make_stubs "$T15"
P1="$T15/via-cicd-abcdef1-via1-aaaaaaaaaaaa"; P2="$T15/via-cicd-abcdef1-via2-bbbbbbbbbbbb"
for st in "$P1" "$P2"; do
  mkdir -p "$st/cli/bin" "$st/cli/home" "$st/project"
  # The session's own CLI: says which one it is and its VIA_HOME, then acts.
  cat > "$st/cli/bin/via" <<EOF
#!/bin/bash
echo "\$(basename "$st") VIA_HOME=\${VIA_HOME:-} via \$*" >> "\$FAKE/own-calls"
exec "$T15/bin/via" "\$@"
EOF
  chmod +x "$st/cli/bin/via"
done
printf '8080\thooks\tpublic\thooks-1111111111111111\n' > "$P1/expose-spec"
printf '8081\tapi\tpublic\tapi-2222222222222222\n' > "$P2/expose-spec"
for st in "$P1" "$P2"; do
  (cd "$st/project" && FAKE="$T15/fake" PATH="$st/cli/bin:$T15/bin:$PATH" STATE_DIR="$st" SESSION_NAME=abcdef1 \
    SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/expose.sh" >/dev/null 2>&1)
done
: > "$T15/fake/own-calls"
# The job's PATH and VIA_HOME after the second install: session 2's CLI first.
JOB_PATH="$P2/cli/bin:$T15/bin:$PATH"
for st in "$P2" "$P1"; do   # post steps run in reverse order
  env FAKE="$T15/fake" PATH="$JOB_PATH" VIA_HOME="$P2/cli/home" GITHUB_ACTIONS="" "INPUT_STATE-DIR=$st" \
    "INPUT_PROJECT-DIR=$st/project" "INPUT_SESSION-NAME=abcdef1" "INPUT_SCRIPTS-DIR=$SCRIPTS" \
    node "$ROOT/post/post.js" >/dev/null 2>&1
done
check "session 1's service stopped by session 1's CLI" \
  grep -qxF "$(basename "$P1") VIA_HOME=$P1/cli/home via expose stop hooks-1111111111111111" "$T15/fake/own-calls"
check "session 2's service stopped by session 2's CLI" \
  grep -qxF "$(basename "$P2") VIA_HOME=$P2/cli/home via expose stop api-2222222222222222" "$T15/fake/own-calls"
check "session 2's CLI never ran session 1's cleanup" \
  bash -c "! grep -q '^$(basename "$P2") .*hooks-1111' '$T15/fake/own-calls'"
check "both addresses are gone" test -z "$(ls -A "$T15/fake/exposed.d")"

echo "# 16. An app's own 401 is not the login"
T16="$(mktemp -d)"
make_stubs "$T16"; touch "$T16/fake/fail-open" "$T16/fake/app-401"
mkdir -p "$T16/state" "$T16/project"
printf '3000\tshop\tlogin\tshop-0123456789abcdef\n' > "$T16/state/expose-spec"
set +e
OUT16="$(cd "$T16/project" && FAKE="$T16/fake" PATH="$T16/bin:$PATH" STATE_DIR="$T16/state" SESSION_NAME=demo \
  SCRIPTS_DIR="$SCRIPTS" GITHUB_ACTIONS="" bash "$SCRIPTS/expose.sh" 2>&1)"; RC16=$?
set -e
check "a 401 without a Basic challenge fails the step" test "$RC16" -ne 0
check "and says so" grep -q "gets HTTP 401 without a Basic login challenge, not 401 with" <<<"$OUT16"
check "and the service is taken down" test ! -e "$T16/fake/exposed.d/shop-0123456789abcdef"

rm -rf "$T15" "$T16"

rm -rf "$CRED_TEMP" "$CRED_TEMP2" "$T4" "$T4B" "$T5" "$T6" "$T7" "$T8" "$(dirname "$CANARY")"
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
