## 1. Configuration Validation

- [x] 1.1 Add `Tests/ProxmoxCtlCoreTests/ConfigurationValidationTests.swift` cases for empty, whitespace-padded, control-character, and valid internal-space aliases; run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigurationValidationTests` and confirm the new cases fail.
- [x] 1.2 Add core alias validation in `Sources/ProxmoxCtlCore/ConfigurationValidation.swift`, expose actionable `ProxmoxCtlError` cases, and rerun `ConfigurationValidationTests` to green.
- [x] 1.3 Extend `ConfigurationValidationTests.swift` with canonical HTTPS, trailing slash, mixed-case scheme, missing host, user information, query, fragment, non-root path, and pre-appended `/api2/json` cases; confirm failures before implementation.
- [x] 1.4 Implement URL validation and canonicalization in `ConfigurationValidation.swift`, wire it into host creation, and rerun the focused validation tests.
- [x] 1.5 Extend `Tests/ProxmoxCtlCoreTests/ConfigStoreTests.swift` with decoded zero and negative timeout cases plus save-time invalid-config cases; confirm invalid JSON-loaded values currently bypass validation.
- [x] 1.6 Make `FileConfigStore.load()` and `save(_:)` validate `AppConfig`, preserve the missing-value five-second default, and rerun `ConfigStoreTests`.

## 2. Credential Identity and Redaction

- [x] 2.1 Extend `Tests/ProxmoxCtlCoreTests/HTTPDebugLoggingTests.swift` with secrets containing one and multiple `=` characters plus malformed Authorization formats; assert no supplied secret substring appears and confirm the delimiter cases fail first.
- [x] 2.2 Change `HTTPDebugFormatter` in `Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift` to preserve only a safely parsed token ID and redact everything after the first secret delimiter; rerun `HTTPDebugLoggingTests`.
- [x] 2.3 Add `Tests/ProxmoxCtlCoreTests/CredentialIdentityTests.swift` for canonical config-path hashing, equivalent path normalization, distinct custom-config scopes, opaque credential references, default legacy identity, and ambiguous custom legacy identity.
- [x] 2.4 Add `Sources/ProxmoxCtlCore/CredentialIdentity.swift` with config identity and secret identity value types, SHA-256 path scoping, and explicit legacy-resolution policy; rerun `CredentialIdentityTests`.
- [x] 2.5 Extend `HostRecord` with an optional Codable credential reference and add version-1 decode plus round-trip tests in `ConfigStoreTests.swift` proving token secrets never enter JSON.
- [x] 2.6 Update `SecretStore`, `CachingSecretStore`, `SessionCache`, and `KeychainSecretStore` to use secret identity rather than alias-only accounts; update their existing fake stores and rerun `AuthorizingSecretStoreTests`, `SessionCacheTests`, `ConfigStoreTests`, and `CredentialIdentityTests`.

## 3. Failure-Safe Host Changes

- [x] 3.1 Add `Tests/ProxmoxCtlCoreTests/HostCredentialCoordinatorTests.swift` with fake config and secret stores proving duplicate aliases fail without mutation unless replacement is explicit.
- [x] 3.2 Add config-store and staged-secret coordination abstractions in `Sources/ProxmoxCtlCore/HostCredentialCoordinator.swift`, implement new-host and replacement commit sequencing, and make the duplicate-alias tests pass.
- [x] 3.3 Add failure-injection tests for staged-secret save failure, config save failure, replacement commit, and superseded-secret cleanup failure; assert the active config always resolves its active secret.
- [x] 3.4 Implement rollback of uncommitted staged secrets and explicit post-commit cleanup results, then rerun `HostCredentialCoordinatorTests`.
- [x] 3.5 Add removal tests proving config commits before secret cleanup and that cleanup failure leaves the host removed with a precise warning result; implement the removal workflow in `HostCredentialCoordinator.swift`.
- [x] 3.6 Add `--replace` to `HostAdd`, route `HostAdd` and `HostRemove` through the coordinator in `Sources/proxmoxctl/main.swift`, and verify validation occurs before token input, LocalAuthentication, or persistent mutation.

## 4. Command-Line Experience

- [x] 4.1 Add `script/test_global_options.sh` to exercise `--config`, `--verbose`, and `-v` before the root subcommand, retain leaf placement, accept equivalent duplicate config paths, reject conflicting paths, and cover the same parsing forms inside piped interactive mode.
- [x] 4.2 Model root options and parent access with ArgumentParser `@ParentCommand`, add one effective-options resolver in `Sources/proxmoxctl/main.swift`, and run `script/test_global_options.sh .build/debug/proxmoxctl` after building.
- [x] 4.3 Add `Tests/ProxmoxCtlCoreTests/GuestListPlanningTests.swift` for no online nodes, online nodes with no guests, mixed node status, and explicit-node bypass.
- [x] 4.4 Add core guest-list planning logic and an actionable no-online-node error, wire `Guests.run()` to it, and rerun `GuestListPlanningTests` plus `ProxmoxClientTests`.
- [x] 4.5 Update command abstracts and option help in `Sources/proxmoxctl/main.swift` for URL and alias constraints, explicit replacement, inventory-first guest-type resolution, no-online-node behavior, and global option placement; verify the built `--help` output in the CLI integration scripts.

## 5. Guest Lifecycle Safety

- [x] 5.1 Update `Tests/ProxmoxCtlCoreTests/SafetyPolicyTests.swift` so start, shutdown, stop, reboot, reset, suspend, and resume all require confirmation without `--yes`, then run the focused suite and confirm start, shutdown, and resume fail under the old policy.
- [x] 5.2 Add focused lifecycle preflight tests using fake transports for unsupported LXC reset, target-resolution failure, declined confirmation, non-interactive input without `--yes`, and approved execution; assert that no lifecycle POST occurs before every gate succeeds.
- [x] 5.3 Change `ConfirmationPolicy` and reorder lifecycle execution to resolve node, resolve type, validate operation support, confirm, and then POST; rerun `SafetyPolicyTests` and the new lifecycle preflight tests.
- [x] 5.4 Add a piped built-CLI smoke test proving every lifecycle subcommand without `--yes` fails before attempting a live mutation; use an isolated config or earlier validation failure and do not contact a real Proxmox host.

## 6. Build Helper Process Ownership

- [x] 6.1 Add `script/test_build_helper_process_ownership.sh` with controlled process stubs proving helper invocation leaves an unrelated `proxmoxctl` PID alive and cleans up only its own background child.
- [x] 6.2 Remove the unconditional `pkill` from `script/build_and_run.sh`, track child PIDs in logs and telemetry modes, install targeted cleanup traps, and make the process-ownership script pass.
- [x] 6.3 Run foreground helper tests that assert `run` returns the child exit status and `--verify` does not terminate a separately running CLI process.

## 7. Documentation and Full Verification

- [x] 7.1 Update `README.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, and `docs/DEVELOPMENT.md` with credential references, custom-config re-enrollment, `--replace`, strict input validation, global option positions, truthful guest availability, all-operation lifecycle confirmation, and helper process ownership.
- [x] 7.2 Add the new shell integration scripts to `script/build_and_run.sh --verify` and the GitHub Actions verification path without adding live hosts, secrets, Keychain access, or lifecycle mutations.
- [x] 7.3 Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, `./script/build_and_run.sh --verify`, and `printf 'help\nexit\n' | .build/debug/proxmoxctl interactive`; require zero failures.
- [x] 7.4 Where a real TTY is available, run `./script/build_and_run.sh run interactive` and manually verify command history, Ctrl-R, global option parsing, confirmation input, and clean exit without persistent history. History recall, Ctrl-R, global parsing, clean exit, and absence of a persistent history file were verified during implementation; the user subsequently confirmed completing the live lifecycle confirmation check manually.
- [x] 7.5 Run `openspec validate harden-cli-integrity-and-ux --type change --strict` and resolve every validation error before declaring the implementation complete.
