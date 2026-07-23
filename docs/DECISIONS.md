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
otherwise use the selected default host. Host aliases are the keys for config,
Keychain entries, and interactive caches.

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

Disruptive lifecycle operations require interactive confirmation unless `--yes`
is passed. When standard input is not interactive, disruptive operations require
`--yes`.

## Secret-Redacted Verbose Logging

Verbose mode is meant for debugging HTTP behavior. It logs URLs, methods,
headers, status codes, and response bodies, but Authorization secrets must be
redacted.

## Readline/Libedit For Interactive History

Interactive history uses macOS's readline-compatible libedit layer through a
small system-library target. The project avoids custom terminal-control code and
does not persist history.
