# CLAUDE.md

## FDAID (Feedback-Driven AI Development) — v2

> SSOT: `ext/asd-ai/CLAUDE.md` — update there first, then propagate.

SPEC → EXECUTE → EVAL → TRACE → GATE → COMMIT → LEARN

1. **SPEC** — Task contract before code: goal, start_state, expected_state, disallowed, eval_method, pass_threshold.
2. **EXECUTE** — Small increment. One concern at a time.
3. **EVAL** — Layered proof (deterministic → scenario → production-derived regression).
4. **TRACE** — Every significant run produces captured output.
5. **GATE** — Explicit release conditions pass before commit/merge.
6. **COMMIT** — Gate passes. ShellCheck clean + self-test green.
7. **LEARN** — Failed evals → new eval cases. Production incidents → eval backlog.

### Eval Layers (Project-Specific)

| Layer | Prove what | How |
|-------|-----------|-----|
| Static | Shell scripts are valid | ShellCheck (CI workflow) |
| Cancel | Session really ends on cancel / kill | `bash tests/cancel.sh` (stub CLI, CI workflow) |
| Expose | Input checks, no injection, outputs, teardown | `bash tests/expose.sh` (stub CLI, CI workflow) |
| E2E | Real relay: webhook in, login 401/200, 404 after | test branch on `kwuite/via-ci-demo` (`uses: viaalink/ci-terminal@<branch>`) |
| Self-test | Action works end-to-end | `.github/workflows/self-test.yml` (needs the VIA_* secrets) |
| CI | Nothing broke upstream | `gh run list` |

### Working Rules

- **Spec first** — Task contract before code.
- **Trace everything** — Capture CI output.
- **Gate before merge** — ShellCheck + self-test green.
- **Never skip gates** — Document and escalate failures.

---

## Overview

**Viaalink CI/CD** (repo `viaalink/ci-terminal`, to be renamed `viaalink/cicd`; earlier `viaalink/asd-devinci`, "DevInCi", "CI Terminal") is a reusable GitHub Composite Action that does three things during a CI/CD job, all published through the user's own Viaalink Relay: a browser terminal (ttyd), VS Code (code-server), and exposing services running in the job on temporary addresses (`expose`). The terminal and VS Code are always behind a login; an exposed service is behind it unless marked `public`. There is no default relay (eu.viaal.ink is a production relay, but never a default). User-facing text says "Viaalink CI/CD", never "CI Terminal".

## Structure

```
.
├── action.yml                         # Composite action definition (v2)
├── scripts/
│   ├── lib/
│   │   └── ci.sh                      # CI platform abstraction layer (shared with the GitLab component)
│   ├── credentials.sh                 # Check every input first (relay key, pins, login, name)
│   ├── install-cli.sh                 # Official install.sh (release / nightly / latest)
│   ├── install-cli.ps1                # Official install.ps1 on Windows
│   ├── start-interface.sh             # Seed the login, via init, start ttyd or code-server
│   ├── connect.sh                     # via expose (terminal/VS Code), read the URL back, outputs + summary
│   ├── expose.sh                      # via expose per service of the expose input, urls output + VIAALINK_URL_*
│   ├── stage-post.sh                  # Background mode: copy post/ next to the checkout
│   ├── keepalive.sh                   # Interactive mode: hold the session until cancel / timeout
│   └── cleanup.sh                     # End the session: stop, restore .env, deployment (idempotent)
├── post/                              # Internal helper action (node24): its post step runs cleanup.sh at job end
├── tests/
│   ├── cancel.sh                      # Cancel / kill / cleanup against a stub CLI
│   └── expose.sh                      # expose input validation, injection, outputs, teardown (stub CLI)
├── .github/workflows/
│   ├── ci.yml                         # CI pipeline (shellcheck, action.yml parses)
│   ├── self-test.yml                  # Self-test workflow (VIA_* secrets)
│   └── release.yml                    # Tag → release + moving major tag
├── README.md
├── CLAUDE.md
├── LICENSE
└── .gitignore
```

## Single source

The action is the product. It is a faithful port of the CLI's
`modules/gh/workflows/terminal.yml` (CLI repo); `via ci install` writes a thin
workflow with `uses: viaalink/cicd@v2`. A change to how a session is
started, published or stopped goes here first, then the CLI wrapper follows.

## How It Works

1. `credentials.sh` checks the inputs: relay key, key id, host, optional port,
   host key fingerprints, login password (needed unless `interface: none` and
   every service is `public`), username (`[A-Za-z0-9._-]+`), session name (DNS
   label), interface (`terminal` | `codeserver` | `none`), mode (`interactive` |
   `background`), and the `expose` lines (`<port> <name> [login|public]`: port
   1-65535, name `^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`, at most 10, parsed
   with `read`, never evaluated; errors name the line number only). Each
   service gets a published name `<name>-<16 hex random>`, written to
   `STATE_DIR/expose-spec`. With `interface: none` the CLI's project
   directory is `STATE_DIR/project` (the checkout is never touched); otherwise
   the checkout. Background mode: the next two steps stage `post/` at
   `$GITHUB_WORKSPACE/../.via-cicd-post` and use it as `./../.via-cicd-post`
   (`uses:` cannot name `github.action_path`); its post step (`post-if:
   always()`) runs cleanup.sh at job end.
2. Installs the Viaalink CLI with the official installer (`cli-version`:
   latest, release tag or nightly tag; nightlies via `VIA_INSTALL_BASE_URL`)
   into `$STATE_DIR/cli` (`VIA_HOME` = `cli/home`; `INSTALL_DIR` =
   `cli/bin` on Linux/macOS, `cli\home\bin` on Windows, the installers'
   own layouts; no PATH/profile/registry edits), then `GITHUB_PATH` + `VIA_HOME` in
   `GITHUB_ENV` for the rest of the job. Never the runner's `~/.local/bin`:
   a self-hosted runner's other jobs keep their CLI. The action's own steps
   set `XDG_CONFIG_HOME=$STATE_DIR/cli/config` (step env, not the job): the
   CLI's config dir (relay registry) follows it.
3. Seeds the login into `.env` (escaped), `via init --yes`, then
   `via ttyd start` or `via codeserver start`. The login is also step env.
4. `via expose ttyd <name>` (socket, Linux/macOS) or `via expose <port> <name>`
   (Windows, code-server); the URL is read back from `via expose list --json`.
   Then `expose.sh`: `via expose <port> <published> --auth=basic|none` per
   service (each name goes into `STATE_DIR/exposures` first), the URL read
   back from `via expose list --json` (must be `alive`, https, not `local`),
   `urls` output (JSON) and `VIAALINK_URL_<NAME>` / `VIAALINK_URLS` in
   `GITHUB_ENV`. A composite action only passes declared outputs, so there is
   no per-service `<name>-url` output.
5. Uploads the `tunnel-url-<session>` artifact (`via gh terminal` reads
   `tunnel-url.txt` from it; not with `interface: none`), then, in interactive
   mode, keeps the job alive until cancel, job timeout or the
   `timeout-minutes` input. Background mode returns here.
6. `cleanup.sh` (from the failing step's trap, keepalive's trap, a final
   `if: always()` step (background mode: only on failure/cancel) and the
   post helper): stop the exposures, the interface and the Caddy the
   action started, restore the repository's `.env` from the backup (or remove
   it), take back what `via init` added to the checkout (`.env.bak*` copies
   with the login, appended `.gitignore` lines, `workspace/`, `.via/` (older CLIs: the older state folder); noted
   by `note_checkout_before` so what the repository had is kept), deployment
   inactive. One `[cleanup]` log line per part; each part's
   marker is removed when done, so a killed cleanup leaves the rest to the
   next caller. keepalive.sh kills its background sleep first: left alive it
   holds the step's output open and the trap's log is lost.
   Session state (backup, markers, URL file) lives in
   `$RUNNER_TEMP/via-cicd-<session>-<GITHUB_ACTION>-<12 hex random>`, made with
   `mkdir` (never reused, never `rm -rf`ed by another session): two sessions in
   one job never share it. A second terminal/VS Code session in the same
   checkout is refused while another has live markers there (`project-dir`);
   steps pass values as step outputs, never `$GITHUB_ENV` (the exceptions:
   the job-scoped CLI's `VIA_HOME`, next to its `GITHUB_PATH` entry, and the
   exposed addresses `VIAALINK_URL_*`, which are meant for the later steps).

## Key Design Decisions

- **No default relay**, no provisioning API, no legacy modes (v2)
- **Secrets and runner env are `VIA_*`**: the CLI reads every `VIA_*` name from 3.2.0 on (`modules/core/helpers/via-env.ts`, first thing at start), so `cli-version` below 3.2.0 is refused. The installer reads `VIA_HOME`, `VIA_INSTALL_BASE_URL` and `VIA_NO_MODIFY_PATH` itself. Exception: the login lines seeded into `.env` keep the CLI's own `.env` key names (a `.env` key is not an environment variable; `via init` fills in keys by those names). Logs and comments never name the old brand or its folders. Do not add other aliases.
- **URL never assembled**: shared and dedicated relays shape hostnames differently
- **Host key pinning is never skipped** (`tunnel-host-key-fingerprints` is required)
- **Logs**: never echo an input value in an error; mask the password (raw and URL-encoded) before any CLI step; do not print the relay host or key id. Exposed addresses are not masked (they are not secrets; the docs say a `public` one is protected only by its random part)
- **Login routes are verified**: the terminal, VS Code and every non-`public` service are exposed with `--auth=basic`, then probed from the runner without credentials (`lib/relay-checks.sh` `login_probe`); anything but 401 with a `WWW-Authenticate: Basic` challenge ends the session and fails the step. Addresses from the CLI must match `relay_url_ok` (plain https host) before they reach GITHUB_OUTPUT/GITHUB_ENV. After a stop, anything but 404 is a run warning (`cleanup_not_gone`)
- **Each session cleans up with its own CLI**: `post.js` and `cleanup_session` put `<state>/cli/bin` (Windows `<state>/cli/home/bin`) first on PATH and set `VIA_HOME=<state>/cli/home`; with two sessions in one job the job's PATH leads to the last install
- **No input in a `run:` line**: inputs reach scripts as step env only (`tests/expose.sh` checks action.yml)
- **Public addresses are unguessable, not secret**: random part per service per run; the README tells users to verify webhook signatures / re-fetch payments, the action claims nothing more

## Consumer Usage

```yaml
- uses: viaalink/cicd@v2
  with:
    tunnel-key: ${{ secrets.VIA_TUNNEL_KEY }}
    tunnel-key-id: ${{ secrets.VIA_TUNNEL_KEY_ID }}
    tunnel-host: ${{ secrets.VIA_TUNNEL_HOST }}
    tunnel-port: ${{ secrets.VIA_TUNNEL_PORT }}
    tunnel-host-key-fingerprints: ${{ secrets.VIA_TUNNEL_HOST_KEY_FINGERPRINTS }}
    password: ${{ secrets.VIA_TERMINAL_PASSWORD }}
    # optional: services, and background mode
    # interface: none
    # mode: background
    # expose: |
    #   3000 shop
    #   8080 webhooks public
```

`viaalink/cicd@v2` and `via ci install` are the target and become available with the v2 release (repo rename to `viaalink/cicd` + v2 tag + CLI release). Until then the CLI command is `via devinci install`, which installs the self-contained workflow.

## Related

- **GitLab CI/CD Component**: [accelerated-software-development/devinci](https://gitlab.com/accelerated-software-development/devinci) (separate repo)
