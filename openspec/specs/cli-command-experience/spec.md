# CLI Command Experience Specification

## Purpose

Define consistent command parsing, guest availability reporting, helper process ownership, and user-facing CLI guidance.

## Requirements

### Requirement: Conventional global option placement
The CLI SHALL accept `--config`, `--verbose`, and `-v` before the root subcommand as well as in their documented leaf-command positions. Both placements SHALL produce the same effective runtime settings.

#### Scenario: Config option before subcommand
- **WHEN** the user runs `proxmoxctl --config custom.json host list`
- **THEN** the command reads `custom.json`

#### Scenario: Verbose flag before subcommand
- **WHEN** the user runs `proxmoxctl --verbose nodes`
- **THEN** the nodes command enables secret-redacted HTTP logging

#### Scenario: Existing leaf placement
- **WHEN** the user runs `proxmoxctl nodes --config custom.json --verbose`
- **THEN** the command retains the same behavior as before this change

#### Scenario: Conflicting config values
- **WHEN** different config paths are supplied in global and leaf positions
- **THEN** parsing fails with an error that identifies the conflicting values

### Requirement: Truthful guest-list availability
When `guests` is used without an explicit node, the CLI SHALL distinguish an empty guest inventory from the absence of online nodes.

#### Scenario: No online nodes
- **WHEN** the node inventory contains no node whose status is `online`
- **THEN** `guests` exits nonzero with an actionable availability error instead of rendering a successful empty table or JSON array

#### Scenario: Online nodes with no guests
- **WHEN** at least one online node is queried successfully and no QEMU or LXC guests are returned
- **THEN** `guests` exits successfully and renders an empty table or JSON array

#### Scenario: Explicit node
- **WHEN** the user supplies `--node`
- **THEN** the CLI attempts that node directly and reports the resulting API success or failure

### Requirement: Non-destructive build and run helper
The project build/run helper SHALL manage only child processes it starts and SHALL NOT terminate unrelated processes by executable name.

#### Scenario: Existing interactive session
- **WHEN** one `proxmoxctl` process is already running and the helper is invoked in another terminal
- **THEN** the existing process remains running

#### Scenario: Foreground run mode
- **WHEN** the helper runs the CLI in foreground mode
- **THEN** it waits for and returns the child command's exit status

#### Scenario: Background diagnostic mode exits
- **WHEN** a logs or telemetry helper mode is interrupted
- **THEN** the helper cleans up only the child process it started

### Requirement: Accurate CLI guidance
Built-in help and user documentation SHALL describe the actual option placement, explicit host replacement, config-scoped credential behavior, inventory-first guest-type resolution, no-online-node error, and lifecycle confirmation policy.

#### Scenario: Guest status help
- **WHEN** the user requests help for guest status or lifecycle commands
- **THEN** help states that omitted guest type uses cluster inventory first and endpoint probing only as fallback

#### Scenario: Host add help
- **WHEN** the user requests help for `host add`
- **THEN** help explains the replacement flag and the accepted alias and URL forms
