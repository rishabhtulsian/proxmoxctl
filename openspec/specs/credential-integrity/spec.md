# Credential Integrity Specification

## Purpose

Define secret redaction, config-scoped credential identity, explicit replacement, and failure-safe persistence behavior.

## Requirements

### Requirement: Complete API token secret redaction
Verbose HTTP logging SHALL preserve the API token ID when it can be identified and SHALL redact the entire token secret for every accepted secret value. No substring derived from the secret may appear in the formatted Authorization header.

#### Scenario: Secret without delimiter characters
- **WHEN** a request uses token ID `admin@pve!cli` and a token secret without `=` characters
- **THEN** verbose output shows `PVEAPIToken=admin@pve!cli=<redacted>` and does not contain the token secret value

#### Scenario: Secret containing delimiter characters
- **WHEN** a request uses token ID `admin@pve!cli` and token secret `part1=part2`
- **THEN** verbose output shows `PVEAPIToken=admin@pve!cli=<redacted>` and contains neither `part1` nor `part2`

#### Scenario: Unrecognized Authorization format
- **WHEN** an Authorization header cannot be safely parsed as a Proxmox API token
- **THEN** verbose output replaces the complete header value with `<redacted>`

### Requirement: Config-scoped Keychain identity
Keychain items created by the CLI SHALL be scoped by the standardized config-file identity and by an opaque credential reference, so independently managed config files cannot overwrite or delete one another's secrets when they contain the same host alias.

#### Scenario: Same alias in two custom configs
- **WHEN** two different `--config` paths each configure alias `home`
- **THEN** each config resolves, replaces, and removes only its own Keychain item

#### Scenario: Equivalent config paths
- **WHEN** relative, absolute, or normalized paths resolve to the same config file
- **THEN** they resolve to the same Keychain scope

#### Scenario: Existing default-config credential
- **WHEN** a default-config host has no opaque credential reference because it predates this change
- **THEN** the CLI continues to resolve its legacy alias-based Keychain item

#### Scenario: Ambiguous legacy custom-config credential
- **WHEN** a custom-config host predates this change and has only an alias-based legacy credential
- **THEN** the CLI does not silently claim the shared legacy item and returns instructions to re-enroll the host credential explicitly

### Requirement: Explicit host replacement
`host add` SHALL reject an alias that already exists unless the caller supplies an explicit replacement flag. Rejection SHALL occur before any config or Keychain mutation.

#### Scenario: Duplicate alias without replacement approval
- **WHEN** `host add home` targets an existing alias without the replacement flag
- **THEN** the command fails with an actionable message and leaves the host record and secret unchanged

#### Scenario: Duplicate alias with replacement approval
- **WHEN** `host add home --replace` supplies valid replacement configuration and a valid secret
- **THEN** the command atomically switches the active host record to a new credential reference

### Requirement: Failure-safe host credential changes
Host add, replace, and remove workflows SHALL order config and Keychain mutations so an active persisted host record never points to a secret that was deleted or replaced by a failed operation. Cleanup failures SHALL be reported without misrepresenting the committed active state.

#### Scenario: New-host config save fails
- **WHEN** a new secret is staged successfully but saving the new host record fails
- **THEN** the original config remains active and the CLI attempts to delete the staged secret

#### Scenario: Replacement config save fails
- **WHEN** a replacement secret is staged successfully but saving the replacement host record fails
- **THEN** the original host record and its original credential reference remain active

#### Scenario: Replacement cleanup fails after commit
- **WHEN** the replacement config is committed but deleting the superseded Keychain item fails
- **THEN** the new host and secret remain active and the CLI reports that only old-secret cleanup failed

#### Scenario: Host removal secret cleanup fails
- **WHEN** the host removal is committed but deleting its no-longer-referenced Keychain item fails
- **THEN** the host remains removed and the CLI reports the orphaned-item cleanup failure
