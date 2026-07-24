# Design Decisions

This file records durable project decisions that future contributors and agents
should preserve unless a new spec explicitly changes them.

## SwiftPM First

`proxmoxctl` is a command-line tool, not a `.app` bundle. SwiftPM is the primary
build, test, and run path. Xcode may be used as a toolchain provider, but the
repo should not grow an Xcode project without a concrete app-bundle or
distribution requirement.

## macOS 26 Minimum

The package minimum is macOS 26. The primary use case is running this tool on a
current personal Mac, so CI targets `macos-26` instead of preserving older macOS
compatibility by default.

## API Tokens Instead Of Password Auth

The CLI uses Proxmox API tokens and sends `PVEAPIToken=<tokenID>=<secret>`.
Password/session-cookie authentication is intentionally out of scope for the
current implementation.

## Keychain And LocalAuthentication

Host config stores token IDs only. Token secrets live in macOS Keychain and are
accessed through LocalAuthentication authorization. This keeps secrets out of
the config file and gives users Touch ID or passcode authorization for Keychain
access.

## Multiple Hosts By Alias

Users can configure multiple hosts. Commands accept `--host <alias>` and
otherwise use the selected default host. Aliases remain config and node-cache
keys, but secret storage uses a config-scoped opaque identity so the same alias
in two custom configs cannot overwrite or delete the other credential.

## Config-Scoped Credential References

New and explicitly replaced hosts receive an opaque credential reference.
Keychain accounts combine that reference with SHA-256 of the canonical config
path. The config contains the non-secret reference but never the token secret.
The default config retains alias-based legacy lookup. Custom configs do not
silently claim ambiguous legacy aliases; users re-enroll with `--replace`.

Host add/replace stages the new secret, commits config, then removes a
superseded secret. Removal commits config before cleanup. Post-commit cleanup
failure is reported as a warning while preserving the successful active state.

## Strict Configuration Boundaries

Aliases, base URLs, and timeout values are validated both at CLI input and
config load/save boundaries. Host URLs are canonical root HTTPS endpoints, and
decoded non-positive or non-finite timeouts are rejected rather than bypassing
the public setter.

## Root And Leaf Global Options

`--config`, `--verbose`, and `-v` are accepted before the root subcommand and in
the established leaf positions. Parent command state and one resolver determine
effective values. Equivalent config paths can be repeated; conflicting paths
fail before runtime construction, including inside interactive mode.

## One Global Request-Level API Timeout

`apiTimeoutSeconds` is global across configured hosts because timeout behavior is
a CLI transport policy rather than host identity. Missing values default to 5
seconds for backward compatibility. `ProxmoxClient` assigns the effective value
to every `URLRequest`, covering all GET and POST API operations through one
central request-construction path.

## Session-Only Interactive Caches

Interactive mode caches secrets and node lists only in memory for the lifetime
of the process. It does not write API token caches or command history to disk.

## Single-Node Inference

Commands that need a node allow `--node` to be omitted only when the selected
host has exactly one node. Multi-node clusters require an explicit `--node`.

## Inventory-First Guest Type Resolution

When guest type is omitted, the client checks cluster resources before trying
guest-specific QEMU/LXC status endpoints. This prevents avoidable errors such as
calling a QEMU endpoint for an LXC VMID.

## Lifecycle Safety Prompts

All lifecycle operations require interactive confirmation unless `--yes` is
passed. Non-interactive input requires `--yes`. The invariant is node
resolution, type resolution, support validation, confirmation, then POST, so an
unsupported LXC reset never prompts and no mutation precedes approval.

## Truthful Guest Availability

Guest listing without `--node` queries online nodes only. No online nodes is an
actionable error, while successful online-node queries returning no guests are a
valid empty inventory. Explicit `--node` bypasses inventory filtering.

## Secret-Redacted Verbose Logging

Verbose mode is meant for debugging HTTP behavior. It logs URLs, methods,
headers, status codes, and response bodies, but Authorization secrets must be
redacted from the first secret delimiter. Unrecognized Authorization formats
are redacted completely.

## Helper Process Ownership

The build/run helper never terminates processes by executable name. Foreground
mode returns its child status. Logs and telemetry modes record the exact app and
diagnostic child PIDs and use traps to clean up only those children.

## Readline/Libedit For Interactive History

Interactive history uses macOS's readline-compatible libedit layer through a
small system-library target. The project avoids custom terminal-control code and
does not persist history.
