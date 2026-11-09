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
| Self-test | Action works end-to-end | `.github/workflows/self-test.yml` (needs the VIA_* secrets) |
| CI | Nothing broke upstream | `gh run list` |

### Working Rules

- **Spec first** — Task contract before code.
- **Trace everything** — Capture CI output.
- **Gate before merge** — ShellCheck + self-test green.
- **Never skip gates** — Document and escalate failures.

---

## Overview

**Viaalink CI Terminal** (repo `viaalink/ci-terminal`, renamed from `viaalink/asd-devinci`; formerly "DevInCi") is a reusable GitHub Composite Action that puts a browser terminal (ttyd) or VS Code (code-server) on a CI runner and publishes it through the user's own Viaalink Relay, behind a login. There is no default relay (eu.viaal.ink is a production relay, but never a default).

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
│   ├── connect.sh                     # via expose, read the URL back, outputs + summary
│   ├── keepalive.sh                   # Hold the session until cancel / timeout
│   └── cleanup.sh                     # End the session: stop, restore .env, deployment (idempotent)
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
workflow with `uses: viaalink/ci-terminal@v2`. A change to how a session is
started, published or stopped goes here first, then the CLI wrapper follows.

## How It Works

1. `credentials.sh` checks the inputs: relay key, key id, host, optional port,
   host key fingerprints, login password, username (`[A-Za-z0-9._-]+`), session
   name (DNS label), interface (`terminal` | `codeserver`).
2. Installs the Viaalink CLI with the official installer (`cli-version`:
   latest, release tag or nightly tag; nightlies via `VIA_INSTALL_BASE_URL`).
3. Seeds the login into `.env` (escaped), `via init --yes`, then
   `via ttyd start` or `via codeserver start`. The login is also step env.
4. `via expose ttyd <name>` (socket, Linux/macOS) or `via expose <port> <name>`
   (Windows, code-server); the URL is read back from `via expose list --json`.
5. Uploads the `tunnel-url-<session>` artifact (`via gh terminal` reads
   `tunnel-url.txt` from it), then keeps the job alive until cancel, job timeout
   or the `timeout-minutes` input.
6. `cleanup.sh` (from the failing step's trap, keepalive's trap and a final
   `if: always()` step): stop the exposure, the interface and the Caddy the
   action started, restore the repository's `.env` from the backup (or remove
   it), deployment inactive. One `[cleanup]` log line per part; each part's
   marker is removed when done, so a killed cleanup leaves the rest to the
   next caller. keepalive.sh kills its background sleep first: left alive it
   holds the step's output open and the trap's log is lost.
   Session state (backup, markers, URL file) lives in `$RUNNER_TEMP/ci-terminal-<session>`;
   steps pass values as step outputs, never `$GITHUB_ENV`.

## Key Design Decisions

- **No default relay**, no provisioning API, no legacy modes (v2)
- **Secrets are `VIA_*`**; the runner env uses the `ASD_*` names every CLI release reads (the CLI copies VIA_X onto ASD_X from 3.2 on). Do not add other aliases.
- **URL never assembled**: shared and dedicated relays shape hostnames differently
- **Host key pinning is never skipped** (`tunnel-host-key-fingerprints` is required)
- **Logs**: never echo an input value in an error; mask the password (raw and URL-encoded) before any CLI step; do not print the relay host or key id

## Consumer Usage

```yaml
- uses: viaalink/ci-terminal@v2
  with:
    tunnel-key: ${{ secrets.VIA_TUNNEL_KEY }}
    tunnel-key-id: ${{ secrets.VIA_TUNNEL_KEY_ID }}
    tunnel-host: ${{ secrets.VIA_TUNNEL_HOST }}
    tunnel-port: ${{ secrets.VIA_TUNNEL_PORT }}
    tunnel-host-key-fingerprints: ${{ secrets.VIA_TUNNEL_HOST_KEY_FINGERPRINTS }}
    password: ${{ secrets.VIA_TERMINAL_PASSWORD }}
```

`viaalink/ci-terminal@v2` and `via ci install` are the target and become available with the v2 release (repo rename + v2 tag + CLI release). Until then the CLI command is `via devinci install`, which installs the self-contained workflow.

## Related

- **GitLab CI/CD Component**: [accelerated-software-development/devinci](https://gitlab.com/accelerated-software-development/devinci) (separate repo)
