@testable import ProxmoxCtlCore
import XCTest

final class AuthorizingSecretStoreTests: XCTestCase {
    func testLoadAuthorizesBeforeReadingSecret() throws {
        let base = RecordingSecretStore(secret: "secret-token")
        let authorizer = RecordingAuthorizer()
        let store = AuthorizingSecretStore(base: base, authorizer: authorizer)

        let secret = try store.loadSecret(for: "home", reason: "Access token")

        XCTAssertEqual(secret, "secret-token")
        XCTAssertEqual(authorizer.reasons, ["Access token"])
        XCTAssertEqual(base.events, [.load("home")])
    }

    func testSaveAuthorizesBeforeWritingSecret() throws {
        let base = RecordingSecretStore(secret: nil)
        let authorizer = RecordingAuthorizer()
        let store = AuthorizingSecretStore(base: base, authorizer: authorizer)

        try store.saveSecret("secret-token", for: "home")

        XCTAssertEqual(authorizer.reasons, ["Authorize storing the Proxmox API token for home"])
        XCTAssertEqual(base.events, [.save("home", "secret-token")])
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
        case save(String, String)
        case load(String)
        case delete(String)
    }

    var events: [Event] = []
    let secret: String?

    init(secret: String?) {
        self.secret = secret
    }

    func saveSecret(_ secret: String, for alias: String) throws {
        events.append(.save(alias, secret))
    }

    func loadSecret(for alias: String, reason: String) throws -> String {
        events.append(.load(alias))
        guard let secret else {
            throw ProxmoxCtlError.secretMissing(alias)
        }
        return secret
    }

    func deleteSecret(for alias: String) throws {
        events.append(.delete(alias))
    }
}
