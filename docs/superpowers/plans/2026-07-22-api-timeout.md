# Configurable Proxmox API Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist one global Proxmox API timeout, default it to 5 seconds, expose `proxmoxctl config set-timeout <seconds>`, and apply it to every API request.

**Architecture:** `AppConfig` owns the persisted optional value, its 5-second effective default, and validation. `Runtime` passes the effective value into `ProxmoxClient`, which assigns it to both GET and POST `URLRequest` instances before sending them through `ProxmoxTransport`. A focused CLI integration script verifies persistence, rejection without mutation, and interactive-session behavior without contacting a Proxmox host.

**Tech Stack:** Swift 6, SwiftPM, Foundation `URLRequest`, Apple `swift-argument-parser`, XCTest, Bash, macOS `plutil`.

## Global Constraints

- Preserve SwiftPM as the build system and macOS 26 as the package minimum.
- Keep reusable configuration and request behavior in `ProxmoxCtlCore`.
- Keep CLI parsing and command structs in `Sources/proxmoxctl`.
- Keep every Proxmox API call behind `ProxmoxTransport`.
- Never log or persist API token secrets outside the existing Keychain path.
- Do not run live lifecycle commands or contact a real Proxmox host during tests.
- Persist one top-level global `apiTimeoutSeconds` JSON number for all hosts.
- Use 5 seconds when `apiTimeoutSeconds` is absent.
- Accept only finite timeout values greater than zero.
- Follow red-green-refactor: observe each new test fail for the missing behavior before adding production code.

## File Structure

- Modify `Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift`: configuration storage, validation, defaulting, and request timeout application.
- Modify `Sources/proxmoxctl/main.swift`: runtime wiring, interactive config selection, and the `config set-timeout` command.
- Modify `Tests/ProxmoxCtlCoreTests/ConfigStoreTests.swift`: config default, persistence, and validation tests.
- Modify `Tests/ProxmoxCtlCoreTests/ProxmoxClientTests.swift`: GET and POST request timeout tests.
- Create `script/test_config_timeout.sh`: built-CLI persistence and interactive integration test.
- Modify `script/build_and_run.sh`: run the CLI integration test during `--verify`.
- Modify `README.md`: user-facing command, default, scope, and JSON field.
- Modify `docs/ARCHITECTURE.md`: config-to-client timeout data flow.
- Modify `docs/DECISIONS.md`: global request-level timeout decision.
- Modify `docs/DEVELOPMENT.md`: timeout test and smoke-test guidance.

---

### Task 1: Persisted Timeout Model And Validation

**Files:**
- Modify: `Tests/ProxmoxCtlCoreTests/ConfigStoreTests.swift`
- Modify: `Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift:5-50`
- Modify: `Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift:109-155`

**Interfaces:**
- Consumes: Existing `AppConfig: Codable, Equatable` and `FileConfigStore`.
- Produces: `ProxmoxCtlError.invalidAPITimeout`, `AppConfig.defaultAPITimeoutSeconds`, `AppConfig.apiTimeoutSeconds`, `AppConfig.effectiveAPITimeoutSeconds`, and `AppConfig.setAPITimeoutSeconds(_:)`.

- [ ] **Step 1: Add failing tests for the missing-field default and persistence**

Append these tests inside `ConfigStoreTests`:

```swift
func testMissingAPITimeoutUsesFiveSecondDefault() throws {
    let data = Data(#"{"version":1,"hosts":[]}"#.utf8)

    let config = try JSONDecoder().decode(AppConfig.self, from: data)

    XCTAssertNil(config.apiTimeoutSeconds)
    XCTAssertEqual(config.effectiveAPITimeoutSeconds, 5)
}

func testFileConfigStorePersistsConfiguredAPITimeout() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("config.json")
    let store = FileConfigStore(fileURL: fileURL)
    var config = AppConfig()
    try config.setAPITimeoutSeconds(12.5)

    try store.save(config)

    let loaded = try store.load()
    XCTAssertEqual(loaded.apiTimeoutSeconds, 12.5)
    XCTAssertEqual(loaded.effectiveAPITimeoutSeconds, 12.5)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigStoreTests
```

Expected: compilation fails because `apiTimeoutSeconds`, `effectiveAPITimeoutSeconds`, and `setAPITimeoutSeconds(_:)` do not exist.

- [ ] **Step 3: Add failing tests for validation and non-mutation**

Append:

```swift
func testAPITimeoutRejectsNonPositiveAndNonFiniteValues() throws {
    for value in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
        var config = AppConfig()

        XCTAssertThrowsError(try config.setAPITimeoutSeconds(value)) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .invalidAPITimeout)
        }
        XCTAssertNil(config.apiTimeoutSeconds)
        XCTAssertEqual(config.effectiveAPITimeoutSeconds, 5)
    }
}
```

- [ ] **Step 4: Implement the minimal configuration model**

Add `case invalidAPITimeout` to `ProxmoxCtlError`, and add this switch branch:

```swift
case .invalidAPITimeout:
    return "API timeout must be a finite number greater than zero."
```

Replace the opening of `AppConfig` and its initializer with:

```swift
public struct AppConfig: Codable, Equatable {
    public static let defaultAPITimeoutSeconds: TimeInterval = 5

    public var version: Int
    public var defaultHostAlias: String?
    public var hosts: [HostRecord]
    public private(set) var apiTimeoutSeconds: TimeInterval?

    public var effectiveAPITimeoutSeconds: TimeInterval {
        apiTimeoutSeconds ?? Self.defaultAPITimeoutSeconds
    }

    public init(
        version: Int = 1,
        defaultHostAlias: String? = nil,
        hosts: [HostRecord] = []
    ) {
        self.version = version
        self.defaultHostAlias = defaultHostAlias
        self.hosts = hosts
        self.apiTimeoutSeconds = nil
    }

    public mutating func setAPITimeoutSeconds(_ seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0 else {
            throw ProxmoxCtlError.invalidAPITimeout
        }
        apiTimeoutSeconds = seconds
    }
```

Keep the existing `resolveHost`, `upsertHost`, and `removeHost` methods below this block unchanged. Synthesized `Codable` omits `nil` and decodes a missing optional field as `nil`, preserving old config compatibility.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigStoreTests
```

Expected: all `ConfigStoreTests` pass, including the default, round-trip, and invalid-value tests.

- [ ] **Step 6: Commit the config model**

```bash
git add Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift Tests/ProxmoxCtlCoreTests/ConfigStoreTests.swift
git commit -m "feat: persist global API timeout"
```

---

### Task 2: Apply The Timeout To Every API Request

**Files:**
- Modify: `Tests/ProxmoxCtlCoreTests/ProxmoxClientTests.swift`
- Modify: `Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift:465-642`
- Modify: `Sources/proxmoxctl/main.swift:96-130`

**Interfaces:**
- Consumes: `AppConfig.effectiveAPITimeoutSeconds` from Task 1.
- Produces: `ProxmoxClient.init(..., apiTimeoutSeconds: TimeInterval = 5, ...)`; all GET and POST requests carry that interval.

- [ ] **Step 1: Add failing tests for default and configured request timeouts**

Add these tests to `ProxmoxClientTests`:

```swift
func testClientDefaultsRequestsToFiveSecondTimeout() async throws {
    let transport = RecordingTransport(data: #"{"data":{"version":"8.4"}}"#)
    let client = ProxmoxClient(
        baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
        tokenID: "root@pam!cli",
        tokenSecret: "secret-token",
        transport: transport
    )

    _ = try await client.version()

    XCTAssertEqual(transport.requests.map(\.timeoutInterval), [5])
}

func testClientAppliesConfiguredTimeoutToGetAndPostRequests() async throws {
    let transport = SequencedTransport(responses: [
        .init(data: #"{"data":{"version":"8.4"}}"#),
        .init(data: #"{"data":"UPID:pve01:123"}"#)
    ])
    let client = ProxmoxClient(
        baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
        tokenID: "root@pam!cli",
        tokenSecret: "secret-token",
        apiTimeoutSeconds: 12.5,
        transport: transport
    )

    _ = try await client.version()
    _ = try await client.lifecycle(
        node: "pve01",
        type: .qemu,
        vmid: 200,
        operation: .start
    )

    XCTAssertEqual(transport.requests.map(\.timeoutInterval), [12.5, 12.5])
}
```

- [ ] **Step 2: Run the focused client tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProxmoxClientTests
```

Expected: the configured-timeout test fails to compile because the initializer does not accept `apiTimeoutSeconds`; the default-timeout assertion would observe Foundation's non-5-second default without the implementation.

- [ ] **Step 3: Implement centralized request timeout assignment**

Add a stored property and initializer argument:

```swift
private let apiTimeoutSeconds: TimeInterval
```

```swift
public init(
    baseURL: URL,
    tokenID: String,
    tokenSecret: String,
    apiTimeoutSeconds: TimeInterval = AppConfig.defaultAPITimeoutSeconds,
    transport: ProxmoxTransport = URLSessionProxmoxTransport(),
    debugLogger: HTTPDebugLogger? = nil,
    hostAlias: String? = nil,
    sessionCache: SessionCache? = nil
) {
    self.baseURL = baseURL
    self.tokenID = tokenID
    self.tokenSecret = tokenSecret
    self.apiTimeoutSeconds = apiTimeoutSeconds
    self.transport = transport
    self.debugLogger = debugLogger
    self.hostAlias = hostAlias
    self.sessionCache = sessionCache
}
```

Add one request factory:

```swift
private func request(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = apiTimeoutSeconds
    return request
}
```

Change the first lines of `get` and `post` to:

```swift
var request = request(url: endpoint(path, queryItems: queryItems))
```

```swift
var request = request(url: endpoint(path))
```

This leaves method, body, headers, authorization, logging, transport, and decoding behavior unchanged.

- [ ] **Step 4: Wire persisted config into runtime client creation**

In `Runtime.client(host:)`, pass:

```swift
apiTimeoutSeconds: config.effectiveAPITimeoutSeconds,
```

between `tokenSecret:` and `debugLogger:`. The complete client construction becomes:

```swift
return ProxmoxClient(
    baseURL: host.url,
    tokenID: host.tokenID,
    tokenSecret: secret,
    apiTimeoutSeconds: config.effectiveAPITimeoutSeconds,
    debugLogger: debugLogger,
    hostAlias: host.alias,
    sessionCache: sessionCache
)
```

- [ ] **Step 5: Run client tests and the full suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProxmoxClientTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: focused tests pass with `[5]` and `[12.5, 12.5]`; the full suite reports zero failures.

- [ ] **Step 6: Commit request timeout behavior**

```bash
git add Sources/ProxmoxCtlCore/ProxmoxCtlCore.swift Sources/proxmoxctl/main.swift Tests/ProxmoxCtlCoreTests/ProxmoxClientTests.swift
git commit -m "feat: apply timeout to API requests"
```

---

### Task 3: Add The CLI Command And Integration Verification

**Files:**
- Create: `script/test_config_timeout.sh`
- Modify: `script/build_and_run.sh:34-37`
- Modify: `Sources/proxmoxctl/main.swift:57-160`

**Interfaces:**
- Consumes: `AppConfig.setAPITimeoutSeconds(_:)`, `FileConfigStore`, and `GlobalOptions.runtime()`.
- Produces: `proxmoxctl config set-timeout <seconds>` and a local integration test callable as `script/test_config_timeout.sh <binary>`.

- [ ] **Step 1: Write the failing built-CLI integration test**

Create `script/test_config_timeout.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_BINARY="${1:?usage: $0 /path/to/proxmoxctl}"
TEST_ROOT="${TMPDIR:-/tmp}"
TEST_ROOT="${TEST_ROOT%/}"
TEST_DIR="$(mktemp -d "$TEST_ROOT/proxmoxctl-timeout-test.XXXXXX")"

cleanup() {
  case "$TEST_DIR" in
    "$TEST_ROOT"/proxmoxctl-timeout-test.*)
      /bin/rm -rf -- "$TEST_DIR"
      ;;
    *)
      echo "Refusing to remove unexpected test directory: $TEST_DIR" >&2
      ;;
  esac
}
trap cleanup EXIT

CONFIG_PATH="$TEST_DIR/config.json"
OUTPUT="$("$APP_BINARY" config set-timeout 7.5 --config "$CONFIG_PATH")"
test "$OUTPUT" = "API timeout is now 7.5 seconds"
test "$(/usr/bin/plutil -extract apiTimeoutSeconds raw -o - "$CONFIG_PATH")" = "7.5"

BEFORE_HASH="$(/usr/bin/shasum -a 256 "$CONFIG_PATH")"
if "$APP_BINARY" config set-timeout 0 --config "$CONFIG_PATH" >/dev/null 2>&1; then
  echo "Expected zero timeout to fail" >&2
  exit 1
fi
AFTER_HASH="$(/usr/bin/shasum -a 256 "$CONFIG_PATH")"
test "$BEFORE_HASH" = "$AFTER_HASH"

printf 'config set-timeout 9\nexit\n' |
  "$APP_BINARY" interactive --config "$CONFIG_PATH" >/dev/null
test "$(/usr/bin/plutil -extract apiTimeoutSeconds raw -o - "$CONFIG_PATH")" = "9"

echo "Verified config set-timeout"
```

Make it executable:

```bash
chmod +x script/test_config_timeout.sh
```

- [ ] **Step 2: Build and verify the CLI test is RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
script/test_config_timeout.sh .build/debug/proxmoxctl
```

Expected: FAIL because `config` is not yet a recognized subcommand.

- [ ] **Step 3: Add the `config set-timeout` command**

Add `Config.self` to the root `subcommands` list.

Add these command types near the existing `Host` commands:

```swift
struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage proxmoxctl configuration.",
        subcommands: [ConfigSetTimeout.self]
    )
}

struct ConfigSetTimeout: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-timeout",
        abstract: "Set the global Proxmox API timeout."
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Timeout in seconds. Must be finite and greater than zero.")
    var seconds: Double

    func run() throws {
        let runtime = options.runtime()
        var config = try runtime.config()
        try config.setAPITimeoutSeconds(seconds)
        try runtime.configStore.save(config)
        print("API timeout is now \(seconds) seconds")
    }
}
```

The setter runs before `save`, so invalid input cannot mutate the config file.

- [ ] **Step 4: Make unqualified interactive commands use the session config**

Replace `GlobalOptions.runtime()` with:

```swift
func runtime() -> Runtime {
    if let session = InteractiveRuntimeContext.current,
       config == nil || session.usesConfig(fileURL) {
        return session.runtime(commandVerbose: verbose)
    }
    return Runtime.standard(fileURL: fileURL, verbose: verbose)
}
```

This preserves an explicitly supplied inner-command `--config` path while making
`config set-timeout 9` inside `interactive --config <path>` update the selected
session file.

- [ ] **Step 5: Add the integration test to repository verification**

In the `--verify|verify)` branch of `script/build_and_run.sh`, add:

```bash
"$ROOT_DIR/script/test_config_timeout.sh" "$APP_BINARY"
```

after the help check and before the branch returns.

- [ ] **Step 6: Run integration and full tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
script/test_config_timeout.sh .build/debug/proxmoxctl
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/build_and_run.sh --verify
```

Expected: the integration script prints `Verified config set-timeout`; Swift tests report zero failures; `--verify` prints both help and timeout verification messages.

- [ ] **Step 7: Commit the CLI and integration test**

```bash
git add Sources/proxmoxctl/main.swift script/build_and_run.sh script/test_config_timeout.sh
git commit -m "feat: add API timeout config command"
```

---

### Task 4: Document Behavior And Run Final Verification

**Files:**
- Modify: `README.md:86-103`
- Modify: `docs/ARCHITECTURE.md:18-64`
- Modify: `docs/DECISIONS.md:32-38`
- Modify: `docs/DEVELOPMENT.md:43-82`

**Interfaces:**
- Consumes: Completed behavior from Tasks 1-3.
- Produces: User and maintainer documentation matching the shipped command and config flow.

- [ ] **Step 1: Update user-facing README**

After the config-file description in `README.md`, add:

````markdown
Set the application-wide Proxmox API timeout with:

```bash
proxmoxctl config set-timeout 10
```

The timeout applies to every configured host and every API-backed command,
including `doctor`. It defaults to 5 seconds when `apiTimeoutSeconds` is absent
from `config.json`. The value must be a finite number greater than zero.
````

Update the preceding config summary to list `apiTimeoutSeconds` alongside aliases,
URLs, token IDs, and the default host.

- [ ] **Step 2: Update architecture and durable decisions**

Add `Global API timeout in seconds` to the config contents list in
`docs/ARCHITECTURE.md`. In Runtime Flow, state:

```markdown
6. The runtime passes the effective global API timeout to `ProxmoxClient`;
   missing values use the 5-second default.
7. `ProxmoxClient` assigns that interval to every `URLRequest`, injects the
   `PVEAPIToken=<tokenID>=<secret>` Authorization header, sends through
   `ProxmoxTransport`, and decodes Proxmox `data` envelopes.
```

Renumber the subsequent step.

Append to `docs/DECISIONS.md`:

```markdown
## One Global Request-Level API Timeout

`apiTimeoutSeconds` is global across configured hosts because timeout behavior is
a CLI transport policy rather than host identity. Missing values default to 5
seconds for backward compatibility. `ProxmoxClient` assigns the effective value
to every `URLRequest`, covering all GET and POST API operations through one
central request-construction path.
```

- [ ] **Step 3: Update developer test guidance**

Add these bullets under Test Categories in `docs/DEVELOPMENT.md`:

```markdown
- API timeout defaulting, validation, persistence, and request propagation.
- Built-CLI `config set-timeout` behavior through
  `script/test_config_timeout.sh`.
```

Add this safe local smoke test near the script examples:

```bash
TEMP_DIR="$(mktemp -d)"
TEMP_CONFIG="$TEMP_DIR/config.json"
.build/debug/proxmoxctl config set-timeout 10 --config "$TEMP_CONFIG"
/usr/bin/plutil -p "$TEMP_CONFIG"
```

State that this command is local-only and does not contact a Proxmox host.

- [ ] **Step 4: Check documentation and diff consistency**

Run:

```bash
rg -n "apiTimeoutSeconds|set-timeout|5 seconds" README.md docs script
git diff --check
git status --short
```

Expected: each documented term appears in the relevant files, `git diff --check`
prints no errors, and status lists only the intended documentation changes.

- [ ] **Step 5: Run all repository-required and feature-specific verification**

Run exactly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/build_and_run.sh --verify
printf 'help\nexit\n' | .build/debug/proxmoxctl interactive
script/test_config_timeout.sh .build/debug/proxmoxctl
```

Expected:

- `swift test` exits 0 with zero failures.
- `build_and_run.sh --verify` exits 0 after help and timeout checks.
- The piped interactive command prints its prompt/help and exits 0.
- The feature integration script prints `Verified config set-timeout`.

Do not run `doctor`, node/guest API calls, or lifecycle operations against a real
host as part of this verification.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md docs/ARCHITECTURE.md docs/DECISIONS.md docs/DEVELOPMENT.md
git commit -m "docs: explain API timeout configuration"
```

- [ ] **Step 7: Inspect final history and working tree**

Run:

```bash
git log -5 --oneline
git status --short
```

Expected: the design commit plus the three implementation commits are visible,
and the working tree is clean.
