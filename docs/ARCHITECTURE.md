# Architecture

`proxmoxctl` is a SwiftPM macOS CLI split into a reusable core library and a
thin executable target.

## Package Layout

- `ProxmoxCtlCore`: configuration, credential normalization, Keychain
  abstractions, Proxmox API client, output rendering, interactive parsing, and
  testable runtime support.
- `proxmoxctl`: ArgumentParser command tree, runtime wiring, terminal input,
  confirmation prompts, and command execution.
- `CEditLine`: system library target for macOS readline/libedit headers and
  `libreadline` linkage.
- `ProxmoxCtlCoreTests`: unit tests for config, auth, HTTP logging, endpoint
  behavior, output rendering, lifecycle safety, interactive parsing, and caches.

## Runtime Flow

1. ArgumentParser parses the selected command.
2. Global options resolve the config path and verbose logging flag.
3. The runtime loads host config from `FileConfigStore`.
4. The selected host alias resolves to a URL and token ID.
5. The token secret is loaded through `AuthorizingSecretStore`, which authorizes
   through LocalAuthentication before reading Keychain.
6. The runtime passes the effective global API timeout to `ProxmoxClient`;
   missing values use the 5-second default.
7. `ProxmoxClient` builds `/api2/json/...` requests, assigns the timeout to
   every `URLRequest`, injects a
   `PVEAPIToken=<tokenID>=<secret>` Authorization header, sends through
   `ProxmoxTransport`, and decodes Proxmox `data` envelopes.
8. Commands render JSON or table output, or print Proxmox task IDs for lifecycle
   operations.

## Config And Secrets

Host configuration lives at:

```text
~/.config/proxmoxctl/config.json
```

The config contains:

- Schema version.
- Default host alias.
- Host aliases, base URLs, and API token IDs.
- Global API timeout in seconds.

Token secrets are not written to the config file. They are stored in the macOS
Keychain by alias. Keychain reads and writes are wrapped by
`AuthorizingSecretStore`, which requests Touch ID or passcode authorization.

## Proxmox API Client

`ProxmoxClient` owns endpoint construction and decoding. It currently supports:

- `GET /version`
- `GET /nodes`
- `GET /nodes/{node}/qemu`
- `GET /nodes/{node}/lxc`
- `GET /cluster/resources?type=vm`
- `GET /nodes/{node}/{qemu|lxc}/{vmid}/status/current`
- `POST /nodes/{node}/{qemu|lxc}/{vmid}/status/{operation}`

Guest status and lifecycle commands resolve QEMU vs LXC automatically when type
is omitted. The client checks cluster inventory first and falls back to endpoint
probing when inventory is unavailable or incomplete.

## Interactive Runtime

`proxmoxctl interactive` runs normal proxmoxctl commands inside one process. It
uses an `InteractiveRuntimeSession` with a `SessionCache` shared across commands.

The cache is process-local and stores:

- API token secrets by host alias.
- Node lists by host alias.

`cache clear` clears both. `host remove <alias>` invalidates that alias. No
interactive cache is persisted.

TTY input uses macOS readline/libedit:

- `readline("proxmoxctl> ")`
- `using_history()`
- `add_history(...)`
- explicit `^R` binding to editline reverse search

Non-TTY input falls back to plain Swift `readLine()` for piped smoke tests.

## Testing Seams

- `ProxmoxTransport` makes network behavior testable without live Proxmox.
- `SecretStore` and `Authorizer` abstractions avoid touching real Keychain or
  LocalAuthentication in tests.
- `InteractiveLineReader` lets tests exercise REPL control flow without terminal
  control.
- Renderers produce deterministic JSON and table output for assertions.

Keep new behavior behind similar seams whenever possible.
