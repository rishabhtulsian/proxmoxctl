## ADDED Requirements

### Requirement: Confirmation for every lifecycle mutation
Every guest lifecycle operation—start, shutdown, stop, reboot, reset, suspend, and resume—SHALL require either an affirmative interactive confirmation or an explicit `--yes` flag.

#### Scenario: Interactive lifecycle command without yes
- **WHEN** a lifecycle command is run with interactive standard input and without `--yes`
- **THEN** the CLI names the operation, guest type, VMID, and node and performs no POST unless the user types `yes`

#### Scenario: Interactive confirmation declined
- **WHEN** the user responds with anything other than case-insensitive `yes`
- **THEN** the command reports cancellation and performs no lifecycle POST

#### Scenario: Non-interactive lifecycle command without yes
- **WHEN** any lifecycle command is run with non-interactive standard input and without `--yes`
- **THEN** the command fails with instructions to pass `--yes` and performs no lifecycle POST

#### Scenario: Lifecycle command with yes
- **WHEN** a supported lifecycle command includes `--yes`
- **THEN** the CLI skips the prompt and submits exactly one corresponding lifecycle POST

### Requirement: Validate before confirmation and mutation
The CLI SHALL resolve the target and reject unsupported operation and guest-type combinations before asking for confirmation, and SHALL perform the lifecycle POST only after all validation and confirmation requirements succeed.

#### Scenario: Unsupported LXC reset
- **WHEN** reset is requested for an LXC guest
- **THEN** the CLI reports that the operation is unsupported without prompting and without sending a POST

#### Scenario: Target resolution fails
- **WHEN** node or guest-type resolution fails
- **THEN** the CLI reports the resolution failure without prompting and without sending a POST

#### Scenario: Valid target requires confirmation
- **WHEN** node and guest type resolve and the operation is supported
- **THEN** confirmation is the final gate before the lifecycle POST

