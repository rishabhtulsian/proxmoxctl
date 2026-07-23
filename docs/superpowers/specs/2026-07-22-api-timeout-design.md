# Configurable Proxmox API Timeout Design

## Goal

Give every Proxmox API call a single, application-wide timeout that persists in
`config.json`. The default timeout is 5 seconds.

## User Interface

Users configure the timeout with:

```bash
proxmoxctl config set-timeout <seconds>
```

The command accepts a finite number greater than zero. Zero, negative values,
`NaN`, and infinite values are rejected without changing the config file.

On success, the command prints the timeout that was saved.

## Configuration

The config file gains an optional top-level JSON number:

```json
{
  "apiTimeoutSeconds": 10,
  "defaultHostAlias": "home1",
  "hosts": [],
  "version": 1
}
```

The timeout is global across all configured hosts. When the field is absent,
including in config files written by older versions, the effective timeout is
5 seconds. Saving an unrelated config change preserves an explicitly configured
timeout.

## Runtime Flow

`GlobalOptions` continues to select the config file. `Runtime.client(host:)`
loads that file, resolves the selected host and secret, and passes the effective
timeout to `ProxmoxClient`.

`ProxmoxClient` applies the timeout to every `URLRequest` it creates before the
request is sent through `ProxmoxTransport`. Central application at request
construction covers `doctor`, node and guest queries, inventory lookups,
endpoint probes, and lifecycle operations without command-specific timeout
logic.

Interactive commands use the same setting. The interactive runtime creates a
client for each command through the existing runtime path, so a timeout changed
by `config set-timeout` is used by subsequent API commands in that session.

## Validation And Errors

Timeout validation belongs in reusable core configuration logic rather than
only in the executable command. This keeps the persistence invariant testable
and prevents invalid values from being accepted by another caller.

Invalid values produce a concise user-facing validation error and do not write
the config file. Existing transport and API errors remain unchanged.

## Testing

Tests will establish:

- Config files without `apiTimeoutSeconds` use the 5-second effective default.
- A valid configured timeout survives a save/load round trip.
- Zero, negative, `NaN`, and infinite values are rejected.
- A configured timeout is assigned to requests observed by a recording
  `ProxmoxTransport`.
- Multiple API methods use the same timeout path, demonstrating that the
  behavior is centralized rather than specific to `doctor`.
- The built CLI accepts `config set-timeout` and writes the expected JSON value
  to a temporary config file.

Implementation will follow test-driven development: each behavior test must
fail for the expected missing behavior before the minimal production change is
added.

## Documentation

`README.md` will document the command, global scope, default, and JSON field.
`docs/ARCHITECTURE.md` will record how the runtime passes configuration to the
client. `docs/DECISIONS.md` will record why request-level timeout application
and backward-compatible defaulting were chosen. `docs/DEVELOPMENT.md` will
include timeout behavior in the test and smoke-test guidance.

## Verification

Before completion, run the repository-required verification:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/build_and_run.sh --verify
printf 'help\nexit\n' | .build/debug/proxmoxctl interactive
```

Also run the built `config set-timeout` command against a temporary config file
and inspect the resulting JSON without contacting a Proxmox host.
