@testable import ProxmoxCtlCore
import XCTest

final class KeychainErrorTests: XCTestCase {
    func testMissingEntitlementErrorIsActionable() {
        let error = KeychainError(status: errSecMissingEntitlement, operation: "save API token")

        XCTAssertEqual(
            error.errorDescription,
            "Keychain failed to save API token: missing required entitlement (-34018). The current storage path uses standard local Keychain items; rebuild with ./script/build_and_run.sh to replace any stale custom-signed binary."
        )
    }
}
