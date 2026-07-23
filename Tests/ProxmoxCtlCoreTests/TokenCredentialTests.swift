@testable import ProxmoxCtlCore
import XCTest

final class TokenCredentialTests: XCTestCase {
    func testRawSecretIsAcceptedAsSecret() throws {
        let credential = try TokenCredential(tokenID: "admin@pve!cli", inputSecret: "uuid-secret")

        XCTAssertEqual(credential.tokenID, "admin@pve!cli")
        XCTAssertEqual(credential.secret, "uuid-secret")
    }

    func testFullAuthorizationValueIsNormalized() throws {
        let credential = try TokenCredential(
            tokenID: "admin@pve!cli",
            inputSecret: "PVEAPIToken=admin@pve!cli=uuid-secret"
        )

        XCTAssertEqual(credential.tokenID, "admin@pve!cli")
        XCTAssertEqual(credential.secret, "uuid-secret")
    }

    func testTokenIDPrefixedSecretIsNormalized() throws {
        let credential = try TokenCredential(tokenID: "admin@pve!cli", inputSecret: "admin@pve!cli=uuid-secret")

        XCTAssertEqual(credential.secret, "uuid-secret")
    }

    func testMismatchedFullAuthorizationValueIsRejected() throws {
        XCTAssertThrowsError(
            try TokenCredential(tokenID: "admin@pve!cli", inputSecret: "PVEAPIToken=root@pam!cli=uuid-secret")
        ) { error in
            XCTAssertEqual(
                (error as? ProxmoxCtlError)?.errorDescription,
                "The pasted API token belongs to root@pam!cli, but this host is configured for admin@pve!cli."
            )
        }
    }
}
