@testable import ProxmoxCtlCore
import XCTest

final class SessionCacheTests: XCTestCase {
    func testCachingSecretStoreLoadsSecretOncePerIdentity() throws {
        let identity = SecretIdentity(account: "v2:scope:one", alias: "home")
        let base = RecordingSessionSecretStore(secrets: [identity: "secret-token"])
        let cache = SessionCache()
        let store = CachingSecretStore(base: base, cache: cache)

        let first = try store.loadSecret(for: identity, reason: "Access token")
        let second = try store.loadSecret(for: identity, reason: "Access token")

        XCTAssertEqual(first, "secret-token")
        XCTAssertEqual(second, "secret-token")
        XCTAssertEqual(base.events, [.load(identity)])
    }

    func testCachingSecretStoreKeepsSameAliasInDifferentConfigScopesIndependent() throws {
        let firstIdentity = SecretIdentity(account: "v2:scope-one:ref", alias: "home")
        let secondIdentity = SecretIdentity(account: "v2:scope-two:ref", alias: "home")
        let base = RecordingSessionSecretStore(secrets: [
            firstIdentity: "secret-one",
            secondIdentity: "secret-two"
        ])
        let cache = SessionCache()
        let store = CachingSecretStore(base: base, cache: cache)

        XCTAssertEqual(try store.loadSecret(for: firstIdentity, reason: "Access token"), "secret-one")
        XCTAssertEqual(try store.loadSecret(for: secondIdentity, reason: "Access token"), "secret-two")
        XCTAssertEqual(try store.loadSecret(for: firstIdentity, reason: "Access token"), "secret-one")

        XCTAssertEqual(base.events, [.load(firstIdentity), .load(secondIdentity)])
    }

    func testCachingSecretStoreSaveAndDeleteUpdateCache() throws {
        let identity = SecretIdentity(account: "v2:scope:ref", alias: "home")
        let base = RecordingSessionSecretStore(secrets: [identity: "old-secret"])
        let cache = SessionCache()
        let store = CachingSecretStore(base: base, cache: cache)

        XCTAssertEqual(try store.loadSecret(for: identity, reason: "Access token"), "old-secret")
        try store.saveSecret("new-secret", for: identity)
        XCTAssertEqual(try store.loadSecret(for: identity, reason: "Access token"), "new-secret")
        try store.deleteSecret(for: identity)

        XCTAssertNil(cache.secret(for: identity))
        XCTAssertEqual(base.events, [.load(identity), .save(identity, "new-secret"), .delete(identity)])
    }
}

private final class RecordingSessionSecretStore: SecretStore {
    enum Event: Equatable {
        case save(SecretIdentity, String)
        case load(SecretIdentity)
        case delete(SecretIdentity)
    }

    var events: [Event] = []
    private var secrets: [SecretIdentity: String]

    init(secrets: [SecretIdentity: String]) {
        self.secrets = secrets
    }

    func saveSecret(_ secret: String, for identity: SecretIdentity) throws {
        events.append(.save(identity, secret))
        secrets[identity] = secret
    }

    func loadSecret(for identity: SecretIdentity, reason: String) throws -> String {
        events.append(.load(identity))
        guard let secret = secrets[identity] else {
            throw ProxmoxCtlError.secretMissing(identity.alias)
        }
        return secret
    }

    func deleteSecret(for identity: SecretIdentity) throws {
        events.append(.delete(identity))
        secrets.removeValue(forKey: identity)
    }
}
