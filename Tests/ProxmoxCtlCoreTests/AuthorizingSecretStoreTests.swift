@testable import ProxmoxCtlCore
import XCTest

final class AuthorizingSecretStoreTests: XCTestCase {
    func testLoadAuthorizesBeforeReadingSecret() throws {
        let identity = SecretIdentity(account: "v2:scope:ref", alias: "home")
        let base = RecordingSecretStore(secret: "secret-token")
        let authorizer = RecordingAuthorizer()
        let store = AuthorizingSecretStore(base: base, authorizer: authorizer)

        let secret = try store.loadSecret(for: identity, reason: "Access token")

        XCTAssertEqual(secret, "secret-token")
        XCTAssertEqual(authorizer.reasons, ["Access token"])
        XCTAssertEqual(base.events, [.load(identity)])
    }

    func testSaveAuthorizesBeforeWritingSecret() throws {
        let identity = SecretIdentity(account: "v2:scope:ref", alias: "home")
        let base = RecordingSecretStore(secret: nil)
        let authorizer = RecordingAuthorizer()
        let store = AuthorizingSecretStore(base: base, authorizer: authorizer)

        try store.saveSecret("secret-token", for: identity)

        XCTAssertEqual(authorizer.reasons, ["Authorize storing the Proxmox API token for home"])
        XCTAssertEqual(base.events, [.save(identity, "secret-token")])
    }
}

private final class RecordingAuthorizer: LocalAuthorizer {
    var reasons: [String] = []

    func authorize(reason: String) throws {
        reasons.append(reason)
    }
}

private final class RecordingSecretStore: SecretStore {
    enum Event: Equatable {
        case save(SecretIdentity, String)
        case load(SecretIdentity)
        case delete(SecretIdentity)
    }

    var events: [Event] = []
    let secret: String?

    init(secret: String?) {
        self.secret = secret
    }

    func saveSecret(_ secret: String, for identity: SecretIdentity) throws {
        events.append(.save(identity, secret))
    }

    func loadSecret(for identity: SecretIdentity, reason: String) throws -> String {
        events.append(.load(identity))
        guard let secret else {
            throw ProxmoxCtlError.secretMissing(identity.alias)
        }
        return secret
    }

    func deleteSecret(for identity: SecretIdentity) throws {
        events.append(.delete(identity))
    }
}
