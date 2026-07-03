# Agent Instructions For proxmoxctl

This repo is intended for spec-driven, agentic development. Preserve the
project's safety and security constraints before optimizing for speed.

## Ground Rules

- Inspect the existing code and tests before changing behavior.
- Treat `Package.swift`, `Sources/ProxmoxCtlCore`, `Sources/proxmoxctl`, and
  `Tests/ProxmoxCtlCoreTests` as the primary sources of truth.
- Prefer small, test-backed changes over broad rewrites.
- Keep SwiftPM as the build system. Do not add an Xcode project unless the user
  explicitly asks for app-bundle behavior or Xcode-only distribution.
- Use `macos-26` as the primary GitHub Actions runner. Use `macos-latest` only
  for scheduled drift checks.
- Update docs when command behavior, auth behavior, config shape, safety policy,
  or developer workflow changes.

## Safety Constraints

- Never log API token secrets. Verbose logs may include token IDs, but token
  secret values must remain redacted.
- Never persist interactive-mode API token caches or command history unless the
  user explicitly asks for persistent storage.
- Never run live lifecycle commands such as `start`, `stop`, `shutdown`,
  `reboot`, `reset`, `suspend`, or `resume` against a real host without explicit
  user approval for that exact operation.
- Prefer read-only live smoke tests: `doctor`, `nodes`, `guests`, and
  `guest status`.
- Keep disruptive command confirmation behavior intact unless the requested
  change explicitly modifies the safety policy.

## Architecture Constraints

- Keep reusable logic in `ProxmoxCtlCore`.
- Keep CLI parsing and command structs in the executable target
  `Sources/proxmoxctl`.
- Keep macOS readline/libedit interop isolated to `CEditLine` and the executable
  input layer.
- Keep Proxmox API calls behind `ProxmoxTransport` so tests can use fake
  transports.
- Keep Keychain access behind `SecretStore` abstractions so tests do not touch a
  real user Keychain.
- Keep interactive session caches memory-only and scoped to the interactive
  process.

## Required Verification

Run these before declaring implementation complete:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/build_and_run.sh --verify
printf 'help\nexit\n' | .build/debug/proxmoxctl interactive
```

If touching interactive history, also verify a real TTY manually where possible:

```bash
./script/build_and_run.sh run interactive
```

Then check up/down recall and Ctrl-R search.

## Documentation Expectations

- `README.md` should stay user-facing and command-oriented.
- `docs/ARCHITECTURE.md` should explain how the system is put together.
- `docs/DECISIONS.md` should record durable design decisions and why they were
  chosen.
- `docs/DEVELOPMENT.md` should guide future implementation and testing.

When in doubt, document the current behavior and the reason for preserving it.
