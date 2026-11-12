# Viaalink CI/CD

Three things during a CI/CD job, published through your own Viaalink Relay:

- **A browser terminal** (ttyd) on the runner, behind a login.
- **VS Code** (code-server) on the runner, behind a login.
- **Your services on temporary public addresses**: an app or API the job started, reachable from outside while the job runs. For example to receive payment-provider webhooks (Mollie, Adyen) in an end-to-end test. See [Expose services during a job](#expose-services-during-a-job).

Start a terminal from your laptop, open the link, and you are working inside the runner: the checked-out repository, the toolchain and the environment your pipeline sees. Useful to debug a job that only fails in CI, or to work on a machine you do not have locally. Nothing is opened on the runner itself: it connects out to your relay over SSH, and the relay serves the session under its own domain.

> **The CLI command.** `uses: viaalink/cicd@v2` is the action; use it in a workflow of your own (see "In your own workflow" below). The `via ci install` command that writes it for you comes with the next Viaalink CLI release.

## Quick start

You need the [Viaalink CLI](https://github.com/viaalink/cli) (`via`) and a relay you are enrolled on.

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
- uses: viaalink/cicd@v2
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
        uses: viaalink/cicd@v2
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

## Expose services during a job

Give the action an `expose` list, one service per line, and it publishes each port of the runner on an address of its own through your relay:

```yaml
expose: |
  3000 shop              # behind the login (username + password)
  8080 webhooks public   # no login: for senders that cannot log in
```

| Part | What |
|------|------|
| `<port>` | The port the service listens on, on the runner (1-65535) |
| `<name>` | 1-32 lowercase letters, digits and inner hyphens; the output and variable name |
| `login` (the default) | Basic auth in front: the action's `username` and `password`, the same login as the terminal |
| `public` | No login. Only for senders that cannot authenticate, such as webhook senders |

Blank lines and `#` comments are skipped; at most 10 services. Anything else in a line (quotes, `$`, `;`, capitals, a fourth word) stops the action before anything starts, and the error names the line number, not its content.

**Every address gets a random part per run**: `webhooks` is published as `webhooks-3f9a1c0d2b4e5f67` (64 random bits, different for each service and each run), so the address cannot be guessed from the name, and no address of an earlier run works again. The relay decides the rest of the host name (a shared relay adds your client id), so the action reads each address back from the CLI and never builds it itself.

### Two modes

| `mode` | What the step does | When it ends |
|--------|--------------------|--------------|
| `interactive` (default) | Publishes, then holds the job | When you cancel the run, at `timeout-minutes`, or at the job timeout |
| `background` | Publishes, writes the addresses for the later steps, and returns | At the end of the job, in the action's post step: after success, after a failed step, and after a cancel |

`interface` picks what else is published: `terminal`, `codeserver`, or `none` for the services only. They combine freely: a terminal plus a few services in one session, or only services. With `interface: none` the CLI runs in a directory of its own in `RUNNER_TEMP`: your checkout is not touched at all (no `.env` lines, no `workspace/`).

### The addresses in later steps

| Where | Example |
|-------|---------|
| `urls` output, JSON, name to address | `${{ fromJSON(steps.via.outputs.urls).webhooks }}` |
| `VIAALINK_URL_<NAME>` in the job environment (hyphens become underscores) | `$VIAALINK_URL_WEBHOOKS` |
| `VIAALINK_URLS`, the same JSON | `jq -r .webhooks <<< "$VIAALINK_URLS"` |

The addresses have no trailing slash and no login in them. A composite action only passes outputs it declares, so there is no `webhooks-url` output per service: use `fromJSON(...).webhooks`. The log and the run summary list each address (they are not secret on their own; see the security notes). If your relay host is stored as a secret, GitHub masks it in the log (`https://webhooks-...-***`); the output and the variables hold the full address.

When nothing listens on a port yet, the service is published anyway and the log warns: start your app before the action, or make the test wait until it answers.

### Teardown

Each exposure is stopped with `via expose stop` and checked: it is gone from `via expose list`, and the log has the HTTP status the relay now answers (404). In background mode the post step does this at the end of the job, also when a later step failed or the run was cancelled; when a step of the action itself fails, that step and the action's final step do it right away. Everything in "On the way out" below applies.

## Receive Mollie / Adyen webhooks in CI

A payment provider calls your webhook endpoint from the internet; in CI that endpoint runs on the runner. Start the app, expose its port in background mode, and hand the address to the test that creates the payment:

```yaml
jobs:
  payment-e2e:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
      - run: npm ci

      - name: Start the shop
        run: |
          nohup npm start > shop.log 2>&1 &
          curl --retry 30 --retry-delay 1 --retry-all-errors -fsS http://127.0.0.1:3000/health

      - name: Expose the webhook endpoint
        id: via
        uses: viaalink/cicd@v2
        with:
          tunnel-key: ${{ secrets.VIA_TUNNEL_KEY }}
          tunnel-key-id: ${{ secrets.VIA_TUNNEL_KEY_ID }}
          tunnel-host: ${{ secrets.VIA_TUNNEL_HOST }}
          tunnel-port: ${{ secrets.VIA_TUNNEL_PORT }}
          tunnel-host-key-fingerprints: ${{ secrets.VIA_TUNNEL_HOST_KEY_FINGERPRINTS }}
          interface: none
          mode: background
          expose: |
            3000 webhooks public

      - name: Payment test
        env:
          MOLLIE_API_KEY: ${{ secrets.MOLLIE_TEST_API_KEY }}
          # e.g. https://webhooks-3f9a1c0d2b4e5f67.relay.example.com/webhooks/mollie
          WEBHOOK_URL: ${{ fromJSON(steps.via.outputs.urls).webhooks }}/webhooks/mollie
        run: npm run test:payments
```

The test creates a Mollie payment with `webhookUrl: process.env.WEBHOOK_URL`, completes it in test mode, and waits until the shop has processed the webhook. When the job ends the address is gone (the relay answers 404). A `public` service needs no `password` input.

**Mollie** cannot send a login with its webhooks, so expose the endpoint `public`. Mollie's payment webhook (the `webhookUrl` of a payment) carries only the payment id (`id=tr_...`): your handler must not trust the call, but fetch the payment by that id from the Mollie API and act on the status it returns. Mollie takes the webhook URL per payment, which suits an address that changes every run.

**Adyen** supports basic authentication on its webhooks, so keep the endpoint behind the login (leave out `public`):

```yaml
          password: ${{ secrets.VIA_TERMINAL_PASSWORD }}
          username: adyen
          expose: |
            3000 webhooks
```

and configure the same username and password for the webhook in Adyen. Also verify the HMAC signature of every notification in your handler (Adyen's HMAC key). Adyen keeps the webhook URL on the webhook configuration, not per payment: point it at this run's address before the test (for example with Adyen's Management API) and back afterwards.

**What the action does and does not protect.** The random part keeps the address from being guessed; the login (when not `public`) keeps out callers without the password; your relay serves it over HTTPS. Whoever has the address of a `public` service can call it until the job ends: the provider, and anyone who can read the run's log or summary. That is why the handler must verify every webhook itself (Mollie: fetch the payment; Adyen: check the HMAC signature) and never act on what the request body claims.

## Start, stop and manage a session

| What | How |
|------|-----|
| Start a session | `via gh terminal` |
| See the sessions that are running | `via gh active` |
| Stop a session | `via gh stop` (asks which when more than one runs), or `via gh stop <run-id>` |
| See recent runs | `via gh runs` |
| List the workflows you can start | `via gh list` |
| Sign the GitHub CLI in | `via gh login` |

An interactive session also ends when you cancel the run on GitHub, when the action's `timeout-minutes` input is reached, or when the job reaches its own `timeout-minutes` (6 hours in the installed workflow, the GitHub maximum for hosted runners). A background session ends with the job.

On the way out, and also when a step of the action fails, the action:

- stops every exposure (`via expose stop`): the terminal's or VS Code's and each service of `expose`, so the relay addresses are no longer public; then the terminal or VS Code server;
- stops Caddy if the action started it (a Caddy that was already running is left alone);
- puts back the repository's own `.env` exactly as it was before the session (the login lines and whatever `via init` added are gone), or removes `.env` if the repository had none;
- removes the copies of `.env` that `via init` writes (`.env.bak`, `.env.bak.1`, ...; they hold the login), and puts back any `.env.bak` the repository already had;
- takes the lines `via init` appended to `.gitignore` back out, and removes the `workspace/` directory and the CLI's runtime state folder (`.via/`) the session created (ones the repository already had are left alone);
- marks the deployment inactive.

The log has one `[cleanup]` line for each of these, or says why there was nothing to do. A final `if: always()` step (interactive mode; in background mode only after a failed step or a cancel) and, in background mode, the post step at the end of the job repeat this for anything a cancelled step could not finish. If stopping the terminal, VS Code or Caddy failed, `workspace/` is left (a process may still run from it) and the log says so. Anything else you made in the checkout from the terminal stays.

The CLI itself is installed for the job only, in the runner's temporary directory (`RUNNER_TEMP`); a `via` the runner already has (`~/.local/bin/via` and `~/.local/share/via`, on Windows `%LOCALAPPDATA%\via`) is not replaced, and no shell profile or user `PATH` is changed. `PATH` and `VIA_HOME` point at that install for the rest of the job, so a later step of yours that runs `via` gets the same CLI. Every step of the action, the install included, also sets `XDG_CONFIG_HOME` to the session's own directory, so the CLI's config directory (relay registry; on Windows otherwise `%APPDATA%\via`) is not the runner's. The terminal inherits that, so a tool that keeps its settings under `XDG_CONFIG_HOME` (the GitHub CLI, Git's `~/.config/git/config`) starts without the job's; Git's `~/.gitconfig` is still read. Your later steps keep the runner's `XDG_CONFIG_HOME`, and a `via` you run there uses the runner's config directory.

## Your own runners

The session works the same on self-hosted runners: choose `self-hosted` as the operating system in `via gh terminal`, or set `runs-on` in your own workflow.

- The runner needs outbound SSH to the relay port (2222 unless `VIA_TUNNEL_PORT` says otherwise), HTTPS to GitHub (the CLI installer), and `bash`, `curl` and `jq`; on Windows also PowerShell and Git Bash.
- Linux, macOS and Windows runners are supported (x64; arm64 on Linux and macOS).
- A self-hosted runner keeps its disk between jobs. The action takes back what it and `via init` put in the checkout (see above) and installs the CLI for the job only, so other jobs on the runner keep the `via` they had. What you do in the terminal itself (files you make, programs you install, processes you leave running) stays: prefer ephemeral runners, or a runner dedicated to these sessions.

## Security notes

- **Whoever can open the terminal can read the relay key on the runner.** The tunnel runs on the runner with that key. That is why the key belongs to a device enrolled for CI alone: if it leaks, remove that device from the relay.
- Anyone who can start the workflow can open a session with the repository's secrets in reach. Keep `workflow_dispatch` workflows that use this action to people you would give that access.
- The session is behind a login (basic auth) and served over HTTPS by your relay. The output `url` embeds the login, for one-click access: treat it like a password. The password, its URL-encoded forms and the `url` output are masked in the logs, and the relay host and key id are not printed.
- Exposed services are behind the same login unless you mark them `public`. A `public` address is protected only by its random part: anyone who has it (the run's log and summary list it) can call the service until the job ends. Expose only what is meant to be called from outside, and verify what comes in (see the webhook section). The address is not a secret the action hides, and the action adds no signature checks of its own.
- The service on the port answers whoever reaches the address: the action publishes it as it is. Debug endpoints, admin pages or test data of the app are reachable too.
- The relay's host key is pinned (`VIA_TUNNEL_HOST_KEY_FINGERPRINTS`): the runner refuses a relay that does not present it.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `tunnel-key` | Relay device key (secret `VIA_TUNNEL_KEY`) | required |
| `tunnel-key-id` | Relay device key id (`VIA_TUNNEL_KEY_ID`) | required |
| `tunnel-host` | Relay host (`VIA_TUNNEL_HOST`) | required |
| `tunnel-port` | Relay SSH port (`VIA_TUNNEL_PORT`) | 2222 |
| `tunnel-host-key-fingerprints` | Relay host key fingerprints (`VIA_TUNNEL_HOST_KEY_FINGERPRINTS`) | required |
| `password` | Login password (`VIA_TERMINAL_PASSWORD`); needed for the terminal, VS Code and every service without `public` | empty |
| `username` | Login username (letters, digits, `.`, `_`, `-`) | `via` |
| `interface` | `terminal` (ttyd), `codeserver` (VS Code) or `none` (services only) | `terminal` |
| `expose` | Services to publish, one per line: `<port> <name> [login\|public]` (see [Expose services during a job](#expose-services-during-a-job)) | empty |
| `mode` | `interactive` (the step holds the job) or `background` (the step returns; the session ends with the job) | `interactive` |
| `shell` | `bash`, `zsh` or `powershell` | `bash` |
| `tunnel-name` | Name of the session, the first label of its hostname | short commit SHA |
| `cli-version` | Viaalink CLI: `latest`, a release tag or a nightly tag. `latest` works once the next CLI release after 3.2.6 is out; until then empty (the default) installs the first build this action works with | empty |
| `timeout-minutes` | Interactive mode: end the session after this many minutes (0 = at cancel or job timeout) | `0` |

## Outputs

| Output | Description |
|--------|-------------|
| `url` | Terminal or VS Code URL with the login embedded (treat it like a password); empty with `interface: none` |
| `url-base` | Terminal or VS Code URL without the login |
| `urls` | The exposed services as JSON, name to address, e.g. `{"webhooks":"https://webhooks-3f9a1c0d2b4e5f67.relay.example.com"}`; read one with `fromJSON(steps.<id>.outputs.urls).<name>` |
| `session-name` | Name the session was published under |
| `local-port` | Port of the interface on the runner (empty when the terminal listens on a socket, Linux and macOS) |

## Troubleshooting

**"Missing inputs"**: a secret is not set, or not passed. Run `via gh setup` in the repository, and check the `with:` block names the `VIA_*` secrets (secrets of a fork are not passed to pull-request runs).

**`via expose` fails**: check that the runner can reach the relay's SSH port, that the device is still enrolled on the relay, that `VIA_TUNNEL_HOST` is the relay's host, and that `VIA_TUNNEL_HOST_KEY_FINGERPRINTS` matches the relay's host key.

**The URL does not answer yet**: the interface can take a few seconds after the URL appears. The run log shows what was published.

**An exposed service answers 502**: nothing listens on its port on the runner (yet). Start the app before the action, and check it binds to `127.0.0.1` or `0.0.0.0` on that port.

**`expose line N: ...`**: the line does not have the form `<port> <name> [login|public]`. The message says which part is wrong.

## Links

- [Viaalink](https://viaalink.com)
- [Viaalink Relay plans](https://viaalink.com/relay#plans)
- [Viaalink CLI](https://github.com/viaalink/cli)

## License

MIT, see [LICENSE](LICENSE).
