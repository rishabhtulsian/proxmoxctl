# proxmoxctl

`proxmoxctl` is a macOS Swift command-line tool for querying and controlling
Proxmox VE hosts. It stores host configuration locally, stores API token
secrets in the macOS Keychain, and uses Touch ID or passcode authorization
through LocalAuthentication before accessing secrets.

The CLI currently supports:

- Managing multiple Proxmox host aliases.
- Checking connectivity with `doctor`.
- Listing nodes and guests.
- Inspecting QEMU VM and LXC guest status.
- Starting, shutting down, stopping, rebooting, suspending, and resuming guests
  with safety prompts for disruptive operations.
- Interactive mode with in-memory session caching, up/down command history, and
  Ctrl-R reverse search.
- Verbose HTTP request/response logging with token secrets redacted.

## Requirements

- macOS 13 or newer.
- Xcode or Xcode Command Line Tools with Swift 6.
- Network access to a Proxmox VE API endpoint.
- A Proxmox API token with permissions for the commands you intend to run.

The package is SwiftPM-first. There is intentionally no Xcode project for the
CLI.

## Build, Test, And Run

```bash
swift build
swift test
./script/build_and_run.sh --verify
```

Run through the helper script:

```bash
./script/build_and_run.sh run --help
./script/build_and_run.sh run nodes
```

Run the debug binary directly:

```bash
.build/debug/proxmoxctl --help
```

Install a local release build somewhere on your `PATH`:

```bash
swift build -c release
install -m 0755 "$(swift build -c release --show-bin-path)/proxmoxctl" /usr/local/bin/proxmoxctl
```

If Xcode is installed but not selected globally, use:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Configure A Host

Create a Proxmox API token in the Proxmox UI, then add it by alias:

```bash
proxmoxctl host add home1 \
  --url https://pve.example.test:8006 \
  --token-id 'admin@pve!cli' \
  --default
```

You will be prompted for the API token secret. You can also pass it through
standard input:

```bash
printf '%s\n' "$PVE_TOKEN_SECRET" | proxmoxctl host add home1 \
  --url https://pve.example.test:8006 \
  --token-id 'admin@pve!cli' \
  --default \
  --token-secret-stdin
```

Configuration is stored as JSON at:

```text
~/.config/proxmoxctl/config.json
```

The config stores aliases, URLs, token IDs, and the default host. Token secrets
are stored separately in the macOS Keychain.

Manage host aliases:

```bash
proxmoxctl host list
proxmoxctl host use home1
proxmoxctl host remove home1
```

## Read-Only Commands

Use these first when validating a host:

```bash
proxmoxctl doctor
proxmoxctl nodes
proxmoxctl guests
proxmoxctl guest status 200
```

Use `--json` for machine-readable output:

```bash
proxmoxctl nodes --json
proxmoxctl guests --json
proxmoxctl guest status 200 --json
```

Use `--host <alias>` to target a non-default configured host.

## Guest Lifecycle Commands

Examples:

```bash
proxmoxctl guest start 200
proxmoxctl guest shutdown 200
proxmoxctl guest reboot 200 --yes
```

For commands that accept `--node`, the node is optional when the configured host
has exactly one node. If the host has multiple nodes, pass `--node <node>`.

When guest type is omitted, `proxmoxctl` resolves QEMU vs LXC by checking cluster
inventory first, then probing QEMU and LXC status endpoints. This avoids calling
the wrong lifecycle endpoint for a VMID.

Disruptive operations require confirmation unless `--yes` is passed. In
non-interactive standard input, disruptive operations require `--yes`.

## Interactive Mode

Start a REPL-style session:

```bash
proxmoxctl interactive
```

Inside interactive mode, enter normal `proxmoxctl` subcommands:

```text
proxmoxctl> doctor
proxmoxctl> nodes
proxmoxctl> guest status 200
proxmoxctl> guest start 200 --yes
proxmoxctl> cache clear
proxmoxctl> exit
```

Interactive mode behavior:

- Optional leading `proxmoxctl` is accepted.
- `exit`, `quit`, and EOF leave the session.
- `help` prints root help.
- `cache clear` clears in-memory secret and node caches.
- Nested `interactive` commands are rejected.
- API token secrets and node lists are cached in memory for the lifetime of the
  interactive process only.
- TTY sessions use macOS readline/libedit history. Up/down navigates commands
  entered in the current session, and Ctrl-R performs reverse history search.
- Piped input falls back to plain `readLine()` behavior for smoke tests.

No persistent `~/.proxmoxctl_history` file is read or written.

## Verbose HTTP Debugging

Use `--verbose` or `-v` to log request and response details to standard error:

```bash
proxmoxctl nodes --verbose
proxmoxctl interactive --verbose
```

Authorization headers are redacted as:

```text
PVEAPIToken=admin@pve!cli=<redacted>
```

Do not paste verbose logs publicly without reviewing hostnames, node names, VM
names, and response bodies.

## Publishing To GitHub Later

This local standalone repo is intentionally created without a remote. To publish
later:

```bash
cd ~/workspace/proxmoxctl
git remote add origin git@github.com:rishabhtulsian/proxmoxctl.git
git push -u origin main
```

If using GitHub CLI on a machine where `gh` is installed and authenticated:

```bash
gh repo create rishabhtulsian/proxmoxctl --private --source=. --remote=origin --push
```

Change `--private` to `--public` only if you intend to publish the project
publicly.

## Development Context

Future agents should start with:

- `AGENTS.md`
- `docs/ARCHITECTURE.md`
- `docs/DECISIONS.md`
- `docs/DEVELOPMENT.md`
- Existing tests under `Tests/ProxmoxCtlCoreTests`

Keep behavior changes spec-driven and covered by focused tests before broad
refactors.
