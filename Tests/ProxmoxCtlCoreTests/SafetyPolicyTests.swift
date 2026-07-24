@testable import ProxmoxCtlCore
import XCTest

final class SafetyPolicyTests: XCTestCase {
    func testEveryLifecycleOperationRequiresConfirmationUnlessYesIsSet() {
        for operation in LifecycleOperation.allCases {
            XCTAssertTrue(
                ConfirmationPolicy.requiresPrompt(for: operation, assumeYes: false),
                "\(operation.rawValue) should require confirmation"
            )
            XCTAssertFalse(
                ConfirmationPolicy.requiresPrompt(for: operation, assumeYes: true),
                "\(operation.rawValue) should honor explicit --yes"
            )
        }
    }
}
