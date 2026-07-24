## Context

The CLI currently treats a host alias as all of the following: a config key, a Keychain account, and an interactive-cache key. That is sufficient for one config file, but `--config` makes aliases ambiguous across independently managed files. Host add and remove also mutate the config file and Keychain sequentially without a durable reference that permits safe staging.

Other findings are concentrated at executable boundaries: URL and alias validation is weaker than the behavior implied by help, decoded timeout values bypass setter validation, options called “global” are defined only on leaf commands, `guests` treats the absence of online nodes as an empty inventory, lifecycle confirmation covers only a subset of state-changing operations, and the build helper kills processes it did not start.

The implementation must preserve SwiftPM, keep reusable policy in `ProxmoxCtlCore`, keep terminal and ArgumentParser wiring in the executable, avoid live lifecycle tests, and retain memory-only interactive caches.

## Goals / Non-Goals

**Goals:**

- Make secret redaction independent of token-secret contents.
- Give every newly stored secret a config-scoped, opaque identity.
- Keep the active config-to-secret reference valid across add, replace, remove, and cleanup failures.
- Reject invalid host and timeout data before authorization, persistence, or request creation.
- Support conventional and existing global-option positions with deterministic conflict handling.
- Make guest availability and lifecycle confirmation behavior truthful and safe.
- Ensure project helper scripts manage only processes they create.
- Cover every requirement with fake-store, fake-transport, parser, renderer, and shell integration tests.

**Non-Goals:**

- Adding password or session-cookie authentication.
- Persisting interactive history, secrets, or node caches.
- Introducing a database or daemon to coordinate config changes.
- Automatically claiming an ambiguous legacy Keychain item for a custom config.
- Waiting for Proxmox lifecycle tasks to complete after the API accepts them.
- Changing Proxmox endpoint coverage beyond behavior needed for these fixes.

## Decisions

### 1. Store opaque credential references in host records

`HostRecord` will gain an optional, non-secret credential reference. Newly added or replaced hosts receive a random UUID reference. The Keychain account for such a secret will be derived from:

```text
v2:<sha256(canonical-config-path)>:<credential-reference>
```

The canonical config path will use an absolute standardized file URL with symlinks resolved where possible. SHA-256 can come from the system CryptoKit framework; this adds no package dependency. The config continues to contain only URL, alias, token ID, and a non-secret reference.

`SecretStore` operations will accept a value object representing the resolved secret identity instead of assuming that the host alias is the account. Cache keys will use the same identity. `KeychainSecretStore` remains responsible only for Keychain operations; config-path policy stays in core coordination logic.

For backward compatibility, a record without a credential reference in the default config resolves to the existing alias-based Keychain account. A record without a reference in a custom config is ambiguous and fails with instructions to run `host add <alias> --replace` with the intended credential.

**Alternatives considered:**

- Continue using aliases and vary only the Keychain service. This separates config files but does not support failure-safe replacement without overwriting the active secret.
- Automatically copy a legacy alias secret into every custom-config scope. This can silently copy the credential belonging to another config and is therefore rejected.
- Store the config path directly in the Keychain account. This leaks unnecessary local path information and can create unwieldy account names; a stable hash avoids both.

### 2. Use staged references instead of pretending two stores are transactional

A reusable `HostCredentialCoordinator` in `ProxmoxCtlCore` will own add, replace, and remove sequencing through config-store and secret-store protocols.

Add or replace will:

1. Validate all non-secret input and replacement intent.
2. Generate a new credential reference and save the new secret under that unused identity.
3. Atomically save a config that points to the new reference.
4. If config save fails, attempt to delete the staged secret; the original config and active secret remain untouched.
5. After a successful replacement commit, attempt to delete the superseded Keychain item.

Remove will:

1. Atomically save a config without the host.
2. Delete the now-unreferenced Keychain item.

A cleanup failure after config commit does not invalidate the committed operation: the active config never points to the orphan. The command will report a specific cleanup warning that states whether add, replacement, or removal committed successfully. Tests will distinguish primary-operation failure from post-commit cleanup failure.

**Alternatives considered:**

- Roll back overwritten alias secrets. Rollback itself can fail and there is an unavoidable window where the active alias points at the wrong value.
- Save config first while continuing to use alias-based secrets. This creates the inverse broken window and cannot make replacement crash-safe.
- Add a general transaction log. That is disproportionate for a local CLI and introduces recovery state that must itself be secured and maintained.

### 3. Centralize config and host-input validation in core

Core validation will define:

- Alias rules: non-empty after trimming, no surrounding whitespace, and no control characters.
- Base URL rules: absolute HTTPS with case-insensitive scheme matching, a host, optional port, and no user information, query, fragment, or non-root path. A trailing slash normalizes away.
- Timeout rules: absent means five seconds; present means finite and greater than zero.

`FileConfigStore.load()` will decode and then validate the complete config before returning it. CLI add and replacement flows will validate arguments before reading a secret or requesting LocalAuthentication. Config writes will validate again as defense against programmatic callers.

Errors will identify the invalid field and accepted shape without echoing secrets.

**Alternatives considered:**

- Validate only ArgumentParser input. This leaves hand-edited and older malformed JSON able to bypass invariants.
- Make every public model initializer throwing. This would force broad source changes and still would not protect synthesized decoding without custom handling.

### 4. Redact from the first secret delimiter

For a recognized `PVEAPIToken=` value, the formatter will preserve only the token ID segment before the first delimiter that separates token ID from secret and replace everything after it with `<redacted>`. If the value lacks a safely recognizable token ID and delimiter, the complete Authorization value is redacted.

Focused tests will use secrets with zero, one, and multiple `=` characters and assert that no supplied secret substring occurs in output.

**Alternative considered:** continue splitting at the last `=`. That preserves too much when the secret itself contains `=` and violates the unconditional redaction invariant.

### 5. Model root and leaf options explicitly

The root command will own optional global `--config` and verbosity values. Subcommands will access parent state through Swift ArgumentParser 1.8.2's `@ParentCommand` support. Leaf commands will retain compatibility options so the documented post-subcommand forms continue to parse.

An executable-layer resolver will merge root and leaf values:

- One supplied config value becomes effective.
- The same config supplied twice is accepted after canonicalization.
- Different config values fail before runtime construction.
- Verbosity is enabled if either position supplies `--verbose` or `-v`.

Nested command groups will expose their parent chain without moving runtime logic out of the executable. The interactive parser continues to invoke the same root parser, so both option placements work inside interactive mode as well.

**Alternative considered:** preprocess and reorder `CommandLine.arguments`. That duplicates parser behavior, is fragile around option values, and would need a separate path for interactive tokens.

### 6. Represent unavailable guest inventory as an error

When `guests` has no explicit node, it will fetch nodes once and partition them by online status. An empty online set returns a dedicated actionable error. At least one successfully queried online node with no returned guests remains a valid empty result.

An explicit `--node` continues to bypass node-status filtering and lets the API response determine success.

### 7. Treat every lifecycle operation as confirmation-gated

`ConfirmationPolicy` will classify start, shutdown, stop, reboot, reset, suspend, and resume as confirmation-gated. Non-interactive input requires `--yes` for all seven operations.

The lifecycle flow will be ordered as:

```text
resolve node → resolve type → validate support → confirm/--yes → POST
```

This prevents prompting for unsupported LXC reset and ensures confirmation is the last gate before mutation. Read-only resolution calls may occur before confirmation; no lifecycle POST may occur before it.

This deliberately changes current start, shutdown, and resume automation. Documentation will call out `--yes` as explicit non-interactive approval.

### 8. Remove process-name-wide cleanup from the helper

`script/build_and_run.sh` will remove the unconditional `pkill`. Foreground modes naturally wait on their child. Background logs and telemetry modes will retain the spawned PID and install a trap that terminates and waits for only that PID on exit or interruption.

Shell integration coverage will start an unrelated harmless process with the target executable name or use a controlled process stub, run helper behavior, and prove the unrelated PID remains alive.

### 9. Verify behavior at the owning boundary

Tests will be organized around existing seams and small new abstractions:

- Formatter tests for delimiter-bearing secrets and malformed Authorization values.
- Fake config and secret stores for coordinator sequencing, staged cleanup, replacement intent, and failure injection.
- Config tests for decoded invalid timeouts, alias rules, URL canonicalization, and custom-config legacy behavior.
- ArgumentParser tests or built-CLI integration tests for both global-option positions and conflicts.
- Command-level fake-client logic for no-online-node versus true empty inventory.
- Safety-policy and lifecycle-order tests proving no POST before confirmation.
- Shell tests proving the helper does not kill unrelated processes.

The required repository verification remains:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/build_and_run.sh --verify
printf 'help\nexit\n' | .build/debug/proxmoxctl interactive
```

No live lifecycle command is part of verification.

## Risks / Trade-offs

- **Custom configs lose implicit access to ambiguous legacy alias secrets** → Fail with explicit re-enrollment instructions; never guess ownership.
- **Credential-reference cleanup can leave an orphaned Keychain item** → Keep the active config valid, report the cleanup failure precisely, and make the orphan identifiable without exposing its value.
- **Canonical path changes can change custom-config scope** → Document that moving a custom config requires credential re-enrollment; equivalent normalized paths remain stable.
- **Root and leaf copies of options can diverge** → Merge through one resolver and test duplicates, conflicts, nesting, and interactive parsing.
- **Confirmation tightening breaks unattended start, shutdown, and resume commands** → Mark the behavior as breaking and require callers to add `--yes`.
- **Stricter URL validation rejects previously stored unusual base paths** → Fail before requests with a message showing the accepted base-URL form; do not silently rewrite non-root paths.
- **Post-commit cleanup warnings complicate exit semantics** → Treat the requested state change as committed and clearly label cleanup as the only failed part, avoiding retries that repeat the mutation.
- **An older binary does not understand opaque credential references and may find a stale legacy alias item** → Do not support binary-only rollback after credential migration; require restoration of the matching pre-change config and legacy Keychain state or explicit credential re-enrollment.

## Migration Plan

1. Decode version-1 host records with an absent credential reference and continue supporting the existing default-config alias lookup.
2. Write the extended host record shape only when a host is newly added or explicitly replaced; keep token secrets out of JSON.
3. For a legacy custom config, reject secret access with a re-enrollment message. The user runs `host add <alias> --replace` with the existing URL, token ID, and intended secret to create an unambiguous reference.
4. On default-config replacement, switch to the new reference and clean up the legacy alias item only after config commit.
5. Update scripts using start, shutdown, or resume to pass `--yes` before deploying the new binary.
6. Before deployment, retain a recoverable copy of the pre-change config. Rolling back to an older binary requires restoring that matching config and its legacy alias credentials; binary-only rollback after a host has migrated to an opaque reference is unsupported.

## Open Questions

None blocking. The design intentionally chooses explicit custom-config credential re-enrollment and confirmation for all lifecycle mutations rather than leaving those safety decisions to implementation.
