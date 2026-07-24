## ADDED Requirements

### Requirement: Valid host aliases
The CLI SHALL accept only host aliases that are non-empty after trimming, contain no control characters, and contain no leading or trailing whitespace. Invalid aliases SHALL be rejected before config or Keychain access.

#### Scenario: Empty alias
- **WHEN** the user supplies an empty or whitespace-only host alias
- **THEN** the command fails before authorization or persistent mutation

#### Scenario: Alias with surrounding whitespace
- **WHEN** the user supplies an alias with leading or trailing whitespace
- **THEN** the command rejects the alias rather than silently normalizing it to a different Keychain identity

#### Scenario: Alias with internal spaces
- **WHEN** the user supplies a quoted non-empty alias containing internal spaces and no control characters
- **THEN** the alias is accepted unchanged

### Requirement: Valid Proxmox base URLs
The CLI SHALL require an absolute HTTPS URL with a non-empty host and no user information, query, fragment, or pre-appended `/api2/json` suffix. Scheme matching SHALL be case-insensitive, and a trailing root slash SHALL normalize to the canonical base URL.

#### Scenario: Canonical HTTPS URL
- **WHEN** the user supplies `https://pve.example.test:8006` or the same URL with a trailing slash
- **THEN** the CLI stores one canonical base URL that produces `/api2/json/...` endpoints

#### Scenario: Uppercase HTTPS scheme
- **WHEN** the user supplies an otherwise valid URL using an uppercase or mixed-case HTTPS scheme
- **THEN** the CLI accepts it and stores the canonical lowercase scheme

#### Scenario: HTTPS value without a host
- **WHEN** the user supplies a value such as `https:example.test` or `https:///path`
- **THEN** the command fails before authorization or persistent mutation

#### Scenario: URL containing user information
- **WHEN** the user supplies an HTTPS URL containing a username or password
- **THEN** the command rejects it so credentials cannot be persisted, displayed, or logged as part of the URL

#### Scenario: URL containing unsupported components
- **WHEN** the user supplies a URL with a query, fragment, non-root path, or existing `/api2/json` suffix
- **THEN** the command fails with an error describing the required Proxmox base-URL shape

### Requirement: Loaded timeout validation
Every config load SHALL validate that a present `apiTimeoutSeconds` value is finite and greater than zero before any command uses the config. Values written through the CLI and values decoded from JSON SHALL obey the same rule.

#### Scenario: Valid decoded timeout
- **WHEN** a config file contains a finite positive timeout
- **THEN** every API request uses that timeout

#### Scenario: Non-positive decoded timeout
- **WHEN** a config file contains zero or a negative timeout
- **THEN** config loading fails with the documented timeout-validation error before a client or request is created

#### Scenario: Missing decoded timeout
- **WHEN** a config file omits `apiTimeoutSeconds`
- **THEN** the effective timeout remains five seconds

### Requirement: Actionable validation failures
Validation errors SHALL identify the invalid field and the accepted form without exposing secrets or performing partial persistent changes.

#### Scenario: Multiple persistent stores are available
- **WHEN** host input validation fails during an add or replacement request
- **THEN** neither the config file nor any Keychain item is changed

