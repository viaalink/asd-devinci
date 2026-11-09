# Viaalink CI Terminal

A browser terminal (ttyd) or VS Code (code-server) on your CI runner, published through your own Viaalink Relay, behind a login. Start it from your laptop, open the link, and you are working inside the runner: the checked-out repository, the toolchain and the environment your pipeline sees. Useful to debug a job that only fails in CI, or to work on a machine you do not have locally. Nothing is opened on the runner itself: it connects out to your relay over SSH, and the relay serves the session under its own domain.

## Quick start

You need the [Viaalink CLI](https://github.com/viaalink/cli) (`via`; `asd` still works as an alias) and a relay you are enrolled on.

```bash
# In your repository: installs .github/workflows/terminal.yml
via ci install

# Commit and push it
git add .github/workflows/terminal.yml
git commit -m "ci: add terminal workflow"
git push

# Give the repository a relay key (see Set up), then:
via gh terminal
```

`via gh terminal` asks for the operating system, shell, login and session name, starts the run and prints the URL once the session is up. When sessions are already running it offers to reconnect to one of them.

## Set up

The runner reaches your relay with a device key, kept in repository secrets.

1. On a device enrolled on your relay (`via relay add '<invite link>'`), run:

   ```bash
   via auth export
   ```

   It prints four values: the device key, its id, the relay host and the relay SSH port.

2. Store them as repository secrets (Settings > Secrets and variables > Actions), or with the GitHub CLI:

   | Secret | Value from `via auth export` | |
   |--------|------------------------------|---|
   | `ASD_TUNNEL_KEY` | the device key (base64) | required |
   | `ASD_TUNNEL_KEY_ID` | the device key's id | required |
   | `ASD_TUNNEL_HOST` | the relay host | required |
   | `ASD_TUNNEL_PORT` | the relay SSH port | optional, 2222 when unset |

   ```bash
   gh secret set ASD_TUNNEL_KEY --repo <owner>/<repo>
   gh secret set ASD_TUNNEL_KEY_ID --repo <owner>/<repo>
   gh secret set ASD_TUNNEL_HOST --repo <owner>/<repo>
   gh secret set ASD_TUNNEL_PORT --repo <owner>/<repo>
   ```

3. **Enrol a device for CI alone.** Ask your relay for a separate invite link for CI and enrol it on a machine (or container) that has no other relay, so `via auth export` exports that key and not your own. It can then be removed from the relay without touching your own devices.

There is no default relay: the session is always published through the relay whose key you give it.

## Use

```bash
via gh terminal
```

Pick the options, wait for the URL, open it and sign in with the login you chose. The same URL is in the run's summary and in its `tunnel-url` artifact.

### In your own workflow

The workflow that `via ci install` writes is self-contained. To add a session to a workflow of your own, use the action:

```yaml
- uses: viaalink/ci-terminal@v2
  with:
    tunnel-key: ${{ secrets.ASD_TUNNEL_KEY }}
    tunnel-key-id: ${{ secrets.ASD_TUNNEL_KEY_ID }}
    tunnel-host: ${{ secrets.ASD_TUNNEL_HOST }}
    tunnel-port: ${{ secrets.ASD_TUNNEL_PORT }}
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
          tunnel-key: ${{ secrets.ASD_TUNNEL_KEY }}
          tunnel-key-id: ${{ secrets.ASD_TUNNEL_KEY_ID }}
          tunnel-host: ${{ secrets.ASD_TUNNEL_HOST }}
          tunnel-port: ${{ secrets.ASD_TUNNEL_PORT }}
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

A session also ends when you cancel the run on GitHub, or when the job reaches its timeout (`timeout-minutes`; 6 hours in the installed workflow, the GitHub maximum for hosted runners). On the way out the action stops the tunnel, removes the `.env` that held the credentials and marks the deployment inactive.

## Your own runners

The session works the same on self-hosted runners: choose `self-hosted` as the operating system in `via gh terminal`, or set `runs-on` in your own workflow.

- The runner needs outbound SSH to the relay port (2222 unless `ASD_TUNNEL_PORT` says otherwise), and `bash`, `curl`, `jq` and `openssl`; on Windows, Git Bash and `unzip`.
- Linux, macOS and Windows runners are supported (x64; arm64 on Linux and macOS).
- A self-hosted runner keeps its disk between jobs. The action removes the `.env` it wrote, but anything you create in the session stays. Prefer ephemeral runners, or a runner dedicated to these sessions.

## Security notes

- **Whoever can open the terminal can read the relay key on the runner.** The key is in the job's environment. That is why the key belongs to a device enrolled for CI alone: if it leaks, remove that device from the relay.
- Anyone who can start the workflow can open a session with the repository's secrets in reach. Keep `workflow_dispatch` workflows that use this action to people you would give that access.
- The session is behind a login (basic auth) and served over HTTPS by your relay. The output `url` embeds the login, for one-click access: treat it like a password. Secrets are masked in the logs.
- `direct: true` connects the relay straight to the interface, without the login the CLI puts in front. Leave it off unless you know why you need it.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `tunnel-key` | Relay device key (`ASD_TUNNEL_KEY` from `via auth export`) | - |
| `tunnel-key-id` | Relay device key id (`ASD_TUNNEL_KEY_ID`) | - |
| `tunnel-host` | Relay host (`ASD_TUNNEL_HOST`); required with `tunnel-key` | - |
| `tunnel-port` | Relay SSH port (`ASD_TUNNEL_PORT`) | 2222 |
| `interface` | `ttyd` (web terminal) or `codeserver` (VS Code) | `ttyd` |
| `shell` | `bash`, `zsh` or `powershell` | `bash` |
| `username` | Login username | `via` |
| `password` | Login password (generated and masked if empty) | - |
| `tunnel-name` | Name of the session, the first label of its hostname | short commit SHA |
| `asd-version` | Viaalink CLI release to install (3.2 or newer) | `latest` |
| `direct` | Skip the login in front of the interface (see Security notes) | `false` |
| `client-id`, `client-secret` | Password login to a relay, instead of a key (needs `tunnel-host` and `tunnel-port`) | - |
| `api-key`, `api-endpoint`, `region`, `ttl-minutes` | Legacy provisioning API; only used when `api-endpoint` is set | - |

## Outputs

| Output | Description |
|--------|-------------|
| `url` | Session URL with the login embedded |
| `url-base` | Session URL without the login |
| `tunnel-user` | Relay client id (empty with a relay key) |
| `local-port` | Port of the interface on the runner |
| `expires-at` | Credential expiry, when the credential has one |

## Troubleshooting

**"No relay credentials"**: the `tunnel-key`, `tunnel-key-id` and `tunnel-host` inputs are empty. Check that the secrets exist in this repository (secrets of a fork are not passed to pull-request runs).

**"Publishing through the relay failed"**: check that the runner can reach the relay's SSH port, that the device is still enrolled on the relay, and that `ASD_TUNNEL_HOST` is the host `via auth export` printed.

**The URL does not answer yet**: the interface can take a few seconds after the URL appears. The run log shows the local port and the health checks.

## Also available

- **GitLab CI/CD component**: [accelerated-software-development/devinci](https://gitlab.com/explore/catalog/accelerated-software-development/devinci)

## Links

- [Viaalink](https://viaalink.com)
- [Viaalink Relay plans](https://viaalink.com/relay#plans)
- [Viaalink CLI](https://github.com/viaalink/cli)
- Documentation: TODO (link once the docs page exists)
- Videos: TODO (install, set up and use · start, stop and manage a session · on your own runners)

## License

MIT, see [LICENSE](LICENSE).
