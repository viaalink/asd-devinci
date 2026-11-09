# Viaalink CI Terminal

A browser terminal (ttyd) or VS Code (code-server) on your CI runner, published through your own Viaalink Relay, behind a login. Start it from your laptop, open the link, and you are working inside the runner: the checked-out repository, the toolchain and the environment your pipeline sees. Useful to debug a job that only fails in CI, or to work on a machine you do not have locally. Nothing is opened on the runner itself: it connects out to your relay over SSH, and the relay serves the session under its own domain.

> **The CLI command.** `uses: viaalink/ci-terminal@v2` works today. The `via ci install` command that writes this workflow for you comes with the next Viaalink CLI release; until then the command is `via devinci install`, which installs a self-contained workflow that `via gh terminal` starts the same way.

## Quick start

You need the [Viaalink CLI](https://github.com/viaalink/cli) (`via`; `asd` still works as an alias) and a relay you are enrolled on.

```bash
# In your repository: installs .github/workflows/terminal.yml
via ci install

# Commit and push it
git add .github/workflows/terminal.yml
git commit -m "ci: add terminal workflow"
git push

# Store the relay key and the login password as secrets (see Set up), then:
via gh terminal
```

`via gh terminal` asks for the operating system, shell, username and session name, starts the run and prints the URL once the session is up. When sessions are already running it offers to reconnect to one of them.

## Set up

The runner reaches your relay with a device key, and the login in front of the session uses a password. Both are kept in repository secrets.

On a device enrolled on your relay (`via relay add '<invite link>'`), run in your repository:

```bash
via gh setup
```

It stores these secrets without printing them:

| Secret | What | |
|--------|------|---|
| `VIA_TUNNEL_KEY` | the device key (base64) | required |
| `VIA_TUNNEL_KEY_ID` | the device key's id | required |
| `VIA_TUNNEL_HOST` | the relay host | required |
| `VIA_TUNNEL_PORT` | the relay SSH port | optional, 2222 when unset |
| `VIA_TUNNEL_HOST_KEY_FINGERPRINTS` | the relay's SSH host key fingerprints (`SHA256:...`, comma separated) | required: the CLI never connects to a relay whose host key it cannot pin |
| `VIA_TERMINAL_PASSWORD` | the password of the login in front of the session | required |

To store them by hand instead, `via auth export` prints the relay values; set each one with `gh secret set <NAME> --repo <owner>/<repo>`.

**Enrol a device for CI alone.** Ask your relay for a separate invite link for CI and enrol it on a machine (or container) that has no other relay, so the key in the secrets is not your own. It can then be removed from the relay without touching your own devices.

There is no default relay: the session is always published through the relay whose key you give it.

## Use

```bash
via gh terminal
```

Pick the options, wait for the URL, open it and sign in with the username you chose and the `VIA_TERMINAL_PASSWORD` password. The same URL is in the run's summary and in its `tunnel-url-<session name>` artifact.

### In your own workflow

`via ci install` writes a short workflow that uses this action. To add a session to a workflow of your own, use the action directly:

```yaml
- uses: viaalink/ci-terminal@v2
  with:
    tunnel-key: ${{ secrets.VIA_TUNNEL_KEY }}
    tunnel-key-id: ${{ secrets.VIA_TUNNEL_KEY_ID }}
    tunnel-host: ${{ secrets.VIA_TUNNEL_HOST }}
    tunnel-port: ${{ secrets.VIA_TUNNEL_PORT }}
    tunnel-host-key-fingerprints: ${{ secrets.VIA_TUNNEL_HOST_KEY_FINGERPRINTS }}
    password: ${{ secrets.VIA_TERMINAL_PASSWORD }}
    tunnel-name: debug-${{ github.run_id }}
```

The step does not end on its own: the job stays alive while the session is open. Put it last, or behind a condition, for example only when the tests failed:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      deployments: write
    steps:
      - uses: actions/checkout@v4

      - name: Run tests
        id: tests
        run: npm test
        continue-on-error: true

      - name: Open a terminal on failure
        if: steps.tests.outcome == 'failure'
        uses: viaalink/ci-terminal@v2
        with:
          tunnel-key: ${{ secrets.VIA_TUNNEL_KEY }}
          tunnel-key-id: ${{ secrets.VIA_TUNNEL_KEY_ID }}
          tunnel-host: ${{ secrets.VIA_TUNNEL_HOST }}
          tunnel-port: ${{ secrets.VIA_TUNNEL_PORT }}
          tunnel-host-key-fingerprints: ${{ secrets.VIA_TUNNEL_HOST_KEY_FINGERPRINTS }}
          password: ${{ secrets.VIA_TERMINAL_PASSWORD }}
          tunnel-name: debug-${{ github.run_id }}
```

For VS Code in the browser, add `interface: codeserver`.

`deployments: write` lets the action add a "View deployment" button to the run; without it the session still works.

## Start, stop and manage a session

| What | How |
|------|-----|
| Start a session | `via gh terminal` |
| See the sessions that are running | `via gh active` |
| Stop a session | `via gh stop` (asks which when more than one runs), or `via gh stop <run-id>` |
| See recent runs | `via gh runs` |
| List the workflows you can start | `via gh list` |
| Sign the GitHub CLI in | `via gh login` |

A session also ends when you cancel the run on GitHub, when the action's `timeout-minutes` input is reached, or when the job reaches its own `timeout-minutes` (6 hours in the installed workflow, the GitHub maximum for hosted runners).

On the way out, and also when a step of the action fails, the action:

- stops the exposure (`via expose stop`), so the relay address is no longer public, and the terminal or VS Code server;
- stops Caddy if the action started it (a Caddy that was already running is left alone);
- puts back the repository's own `.env` exactly as it was before the session (the login lines and whatever `via init` added are gone), or removes `.env` if the repository had none;
- marks the deployment inactive.

The log has one `[cleanup]` line for each of these, or says why there was nothing to do. A final `if: always()` step repeats this for anything a cancelled step could not finish. Other files the session created (`via init` output, the `workspace/` directory, anything you made in the terminal) stay.

## Your own runners

The session works the same on self-hosted runners: choose `self-hosted` as the operating system in `via gh terminal`, or set `runs-on` in your own workflow.

- The runner needs outbound SSH to the relay port (2222 unless `VIA_TUNNEL_PORT` says otherwise), HTTPS to GitHub (the CLI installer), and `bash`, `curl` and `jq`; on Windows also PowerShell and Git Bash.
- Linux, macOS and Windows runners are supported (x64; arm64 on Linux and macOS).
- A self-hosted runner keeps its disk between jobs. The action restores `.env` (see above), but anything else the session created stays. Prefer ephemeral runners, or a runner dedicated to these sessions.

## Security notes

- **Whoever can open the terminal can read the relay key on the runner.** The tunnel runs on the runner with that key. That is why the key belongs to a device enrolled for CI alone: if it leaks, remove that device from the relay.
- Anyone who can start the workflow can open a session with the repository's secrets in reach. Keep `workflow_dispatch` workflows that use this action to people you would give that access.
- The session is behind a login (basic auth) and served over HTTPS by your relay. The output `url` embeds the login, for one-click access: treat it like a password. The password, its URL-encoded forms and the `url` output are masked in the logs, and the relay host and key id are not printed.
- The relay's host key is pinned (`VIA_TUNNEL_HOST_KEY_FINGERPRINTS`): the runner refuses a relay that does not present it.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `tunnel-key` | Relay device key (secret `VIA_TUNNEL_KEY`) | required |
| `tunnel-key-id` | Relay device key id (`VIA_TUNNEL_KEY_ID`) | required |
| `tunnel-host` | Relay host (`VIA_TUNNEL_HOST`) | required |
| `tunnel-port` | Relay SSH port (`VIA_TUNNEL_PORT`) | 2222 |
| `tunnel-host-key-fingerprints` | Relay host key fingerprints (`VIA_TUNNEL_HOST_KEY_FINGERPRINTS`) | required |
| `password` | Login password (`VIA_TERMINAL_PASSWORD`) | required |
| `username` | Login username (letters, digits, `.`, `_`, `-`) | `via` |
| `interface` | `terminal` (ttyd) or `codeserver` (VS Code) | `terminal` |
| `shell` | `bash`, `zsh` or `powershell` | `bash` |
| `tunnel-name` | Name of the session, the first label of its hostname | short commit SHA |
| `cli-version` | Viaalink CLI: `latest`, a release tag or a nightly tag. `latest` works once the next CLI release after 3.2.6 is out; until then the default is the first build this action works with | `v3.2.6-nightly.20261109T1503` |
| `timeout-minutes` | End the session after this many minutes (0 = at cancel or job timeout) | `0` |

## Outputs

| Output | Description |
|--------|-------------|
| `url` | Session URL with the login embedded (treat it like a password) |
| `url-base` | Session URL without the login |
| `session-name` | Name the session was published under |
| `local-port` | Port of the interface on the runner (empty when the terminal listens on a socket, Linux and macOS) |

## Troubleshooting

**"Missing inputs"**: a secret is not set, or not passed. Run `via gh setup` in the repository, and check the `with:` block names the `VIA_*` secrets (secrets of a fork are not passed to pull-request runs).

**`via expose` fails**: check that the runner can reach the relay's SSH port, that the device is still enrolled on the relay, that `VIA_TUNNEL_HOST` is the relay's host, and that `VIA_TUNNEL_HOST_KEY_FINGERPRINTS` matches the relay's host key.

**The URL does not answer yet**: the interface can take a few seconds after the URL appears. The run log shows what was published.

## Also available

- **GitLab CI/CD component**: [accelerated-software-development/devinci](https://gitlab.com/explore/catalog/accelerated-software-development/devinci)

## Links

- [Viaalink](https://viaalink.com)
- [Viaalink Relay plans](https://viaalink.com/relay#plans)
- [Viaalink CLI](https://github.com/viaalink/cli)

## License

MIT, see [LICENSE](LICENSE).
