# Development Guide

Use this guide when adding features or changing behavior.

## Setup

```bash
swift build
swift test
./script/build_and_run.sh --verify
```

If the active developer directory is not Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Script Entrypoint

`script/build_and_run.sh` is the project-local build/run helper:

```bash
./script/build_and_run.sh run --help
./script/build_and_run.sh run nodes
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug --help
```

The script builds with SwiftPM, resolves the debug binary path, and runs the CLI.

## Test Categories

- Config and credential normalization.
- Keychain and authorization abstractions.
- Proxmox endpoint construction and HTTP response handling.
- API token Authorization headers.
- Secret redaction in verbose logging.
- QEMU/LXC guest status and lifecycle behavior.
- Single-node inference and multi-node errors.
- JSON/table rendering.
- Confirmation policy for disruptive commands.
- Interactive parser, loop behavior, session cache, and history policy.

Add focused tests for each behavior change. Prefer fake transports and stores
over live Proxmox calls.

## Safe Live Smoke Tests

Start with read-only commands:

```bash
proxmoxctl doctor
proxmoxctl nodes
proxmoxctl guests
proxmoxctl guest status <vmid>
```

Only run lifecycle commands against a live host when the user explicitly
authorizes the exact operation and target. Prefer `--yes` only in scripts or
when confirmation has already been handled by the caller.

## Adding A New Command

1. Add or update core behavior in `ProxmoxCtlCore` with tests.
2. Add CLI parsing and output behavior in the executable target.
3. Keep network calls inside `ProxmoxClient`.
4. Keep secrets behind `SecretStore` abstractions.
5. Add `--json` when the command returns structured data.
6. Update README and design docs if user-facing behavior changes.
7. Run the required verification commands from `AGENTS.md`.

## Agentic Spec-Driven Workflow

For future agents:

1. Read `AGENTS.md`, `README.md`, `docs/ARCHITECTURE.md`, and
   `docs/DECISIONS.md`.
2. Inspect relevant tests before changing implementation.
3. State the intended behavior and safety impact.
4. Add tests first for new or changed behavior.
5. Make the smallest implementation change that satisfies the spec.
6. Run the required verification commands.
7. Update docs with any changed commands, safety constraints, or design
   decisions.

Do not rely on live Proxmox behavior when a fake transport test can prove the
same contract.
