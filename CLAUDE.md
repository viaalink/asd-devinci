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
| Self-test | Action works end-to-end | `.github/workflows/self-test.yml` (needs the relay key secrets) |
| CI | Nothing broke upstream | `gh run list` |

### Working Rules

- **Spec first** — Task contract before code.
- **Trace everything** — Capture CI output.
- **Gate before merge** — ShellCheck + self-test green.
- **Never skip gates** — Document and escalate failures.

---

## Overview

**Viaalink CI Terminal** (repo `viaalink/asd-devinci`, to be renamed `viaalink/ci-terminal`; formerly "DevInCi") is a reusable GitHub Composite Action that puts a browser terminal (ttyd) or VS Code (code-server) on a CI runner and publishes it through the user's own Viaalink Relay, behind a login. There is no default relay and no hosted provisioning API.

## Structure

```
.
├── action.yml                         # Composite action definition
├── scripts/
│   ├── lib/
│   │   └── ci.sh                      # CI platform abstraction layer
│   ├── setup.sh                       # Download + install the Viaalink CLI (`via`, cross-platform)
│   ├── provision.sh                   # Check relay credentials (key / password / legacy API)
│   ├── start-interface.sh             # Start ttyd or code-server
│   ├── connect.sh                     # `via expose`, read the URL back, outputs + summary
│   └── keepalive.sh                   # Hold the session, clean up on cancel
├── .github/workflows/
│   ├── ci.yml                         # CI pipeline (shellcheck, action.yml parses)
│   ├── self-test.yml                  # Self-test workflow (relay key secrets)
│   └── release.yml                    # Tag → release + moving major tag
├── README.md
├── CLAUDE.md
├── LICENSE
└── .gitignore
```

## How It Works

1. Installs the Viaalink CLI (`via`; `asd` stays available as an alias) from the `viaalink/cli` GitHub releases into the 3.2 data directory (`via/bin`). Needs CLI 3.2 or newer.
2. Checks relay credentials, in this order:
   - **Relay key** (recommended): `tunnel-key` + `tunnel-key-id` + `tunnel-host` (+ optional `tunnel-port`), the values `via auth export` prints, stored as `ASD_TUNNEL_KEY`, `ASD_TUNNEL_KEY_ID`, `ASD_TUNNEL_HOST`, `ASD_TUNNEL_PORT` secrets.
   - **Password login**: `client-id` + `client-secret` + `tunnel-host` + `tunnel-port`.
   - **Legacy provisioning API**: `api-key` or ephemeral, only when `api-endpoint` is set explicitly (no default; api.asd.host is gone).
3. Starts the interface (`via ttyd start` or `via codeserver start`).
4. Publishes with `via expose <port> <name>` and reads the URL back from `via expose list --json` (never assembled by hand: shared and dedicated relays shape hostnames differently).
5. Uploads the `tunnel-url` artifact (`via gh terminal` reads it), then keeps the job alive until the run is cancelled.

## Key Design Decisions

- **CI-agnostic scripts**: Scripts use `scripts/lib/ci.sh` abstraction layer (shared with GitLab component in separate repo)
- **No default relay**: credentials always come from inputs; there is no fallback host
- **No hardcoded port defaults**: Ports come from tpl.env / `via env init`, parsed from `via ttyd|codeserver start` output
- **Env var names**: the CLI still reads `ASD_*` (ASD_TUNNEL_*, ASD_TTYD_*, ASD_BIN_DIR); do not invent `VIA_*` aliases here
- **direct**: optional `--direct` for `via expose` (skips the login in front)

## Consumer Usage

```yaml
- uses: viaalink/ci-terminal@v2
  with:
    tunnel-key: ${{ secrets.ASD_TUNNEL_KEY }}
    tunnel-key-id: ${{ secrets.ASD_TUNNEL_KEY_ID }}
    tunnel-host: ${{ secrets.ASD_TUNNEL_HOST }}
    tunnel-port: ${{ secrets.ASD_TUNNEL_PORT }}
```

`viaalink/ci-terminal@v2` resolves only after the repo rename and a v2 tag.

## Related

- **GitLab CI/CD Component**: [accelerated-software-development/devinci](https://gitlab.com/accelerated-software-development/devinci) (separate repo)
