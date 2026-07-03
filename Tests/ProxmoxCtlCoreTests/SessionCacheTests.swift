@testable import ProxmoxCtlCore
import XCTest

final class SessionCacheTests: XCTestCase {
    func testCachingSecretStoreLoadsSecretOncePerAlias() throws {
        let base = RecordingSessionSecretStore(secrets: ["home": "secret-token"])
        let cache = SessionCache()
        let store = CachingSecretStore(base: base, cache: cache)

        let first = try store.loadSecret(for: "home", reason: "Access token")
        let second = try store.loadSecret(for: "home", reason: "Access token")

        XCTAssertEqual(first, "secret-token")
        XCTAssertEqual(second, "secret-token")
        XCTAssertEqual(base.events, [.load("home")])
    }

    func testCachingSecretStoreKeepsAliasesIndependent() throws {
        let base = RecordingSessionSecretStore(secrets: [
            "home1": "secret-one",
            "home2": "secret-two"
        ])
        let cache = SessionCache()
        let store = CachingSecretStore(base: base, cache: cache)

        XCTAssertEqual(try store.loadSecret(for: "home1", reason: "Access token"), "secret-one")
        XCTAssertEqual(try store.loadSecret(for: "home2", reason: "Access token"), "secret-two")
        XCTAssertEqual(try store.loadSecret(for: "home1", reason: "Access token"), "secret-one")

        XCTAssertEqual(base.events, [.load("home1"), .load("home2")])
    }

    func testCachingSecretStoreSaveAndDeleteUpdateCache() throws {
        let base = RecordingSessionSecretStore(secrets: ["home": "old-secret"])
        let cache = SessionCache()
        let store = CachingSecretStore(base: base, cache: cache)

        XCTAssertEqual(try store.loadSecret(for: "home", reason: "Access token"), "old-secret")
        try store.saveSecret("new-secret", for: "home")
        XCTAssertEqual(try store.loadSecret(for: "home", reason: "Access token"), "new-secret")
        try store.deleteSecret(for: "home")

        XCTAssertNil(cache.secret(for: "home"))
        XCTAssertEqual(base.events, [.load("home"), .save("home", "new-secret"), .delete("home")])
    }
}

private final class RecordingSessionSecretStore: SecretStore {
    enum Event: Equatable {
        case save(String, String)
        case load(String)
        case delete(String)
    }

    var events: [Event] = []
    private var secrets: [String: String]

    init(secrets: [String: String]) {
        self.secrets = secrets
    }

    func saveSecret(_ secret: String, for alias: String) throws {
        events.append(.save(alias, secret))
        secrets[alias] = secret
    }

    func loadSecret(for alias: String, reason: String) throws -> String {
        events.append(.load(alias))
        guard let secret = secrets[alias] else {
            throw ProxmoxCtlError.secretMissing(alias)
        }
        return secret
    }

    func deleteSecret(for alias: String) throws {
        events.append(.delete(alias))
        secrets.removeValue(forKey: alias)
    }
}
