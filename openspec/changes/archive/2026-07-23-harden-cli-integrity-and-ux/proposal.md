## Why

`proxmoxctl` currently has several gaps where valid-looking CLI input can expose part of a token secret, make configuration and Keychain state disagree, silently overwrite credentials, or report an empty result when the host is unavailable. The standalone CLI should fail safely, preserve existing state across partial failures, and make consequential behavior explicit and predictable.

## What Changes

- Redact the entire API token secret from verbose logs even when the supplied secret contains delimiter characters.
- Scope Keychain entries so separate `--config` files cannot overwrite each other's secrets when they reuse a host alias.
- Make host add, replace, and remove operations failure-safe across config and Keychain storage, and require explicit intent before replacing an existing alias.
- Validate host aliases, HTTPS base URLs, and decoded timeout values before persisting or using them.
- Accept config and verbose options in conventional global positions while retaining documented leaf-command placement.
- Distinguish “no online nodes” from a genuine empty guest inventory and return an actionable failure instead of a successful empty result.
- Stop the build/run helper from terminating unrelated `proxmoxctl` processes.
- **BREAKING**: Require confirmation, or `--yes` for non-interactive use, for every guest lifecycle operation, including start, shutdown, and resume.
- Align command help and user documentation with the resulting validation, replacement, guest-resolution, and safety behavior.

## Capabilities

### New Capabilities

- `credential-integrity`: Complete secret redaction, config-scoped Keychain identity, explicit host replacement, and failure-safe coordination between config and secret storage.
- `cli-input-validation`: Validation requirements for aliases, base URLs, persisted timeout values, and actionable configuration errors.
- `cli-command-experience`: Global option placement, truthful empty-state handling, non-destructive helper behavior, and accurate command help.
- `guest-lifecycle-safety`: Confirmation requirements for all guest lifecycle mutations in interactive and non-interactive contexts.

### Modified Capabilities

None. This repository does not yet contain baseline OpenSpec capability specifications.

## Impact

- Core configuration, credential, Keychain, redaction, and client-support logic in `Sources/ProxmoxCtlCore`.
- CLI option parsing, host management, guest listing, and lifecycle confirmation in `Sources/proxmoxctl`.
- The SwiftPM build/run helper in `script/build_and_run.sh`.
- Unit and CLI integration tests under `Tests/ProxmoxCtlCoreTests` and `script/`.
- User-facing behavior and safety guidance in `README.md` and the architecture, decisions, and development documentation.
- Existing automation that runs `guest start`, `guest shutdown`, or `guest resume` without `--yes` will need to add explicit approval.
- Existing custom-config Keychain entries need a safe compatibility or re-enrollment path because their current alias-only identity is ambiguous across config files.
