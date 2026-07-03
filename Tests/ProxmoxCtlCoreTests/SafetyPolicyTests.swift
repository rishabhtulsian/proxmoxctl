@testable import ProxmoxCtlCore
import XCTest

final class SafetyPolicyTests: XCTestCase {
    func testDisruptiveOperationsRequireConfirmationUnlessYesIsSet() {
        XCTAssertFalse(ConfirmationPolicy.requiresPrompt(for: .start, assumeYes: false))
        XCTAssertFalse(ConfirmationPolicy.requiresPrompt(for: .shutdown, assumeYes: false))
        XCTAssertFalse(ConfirmationPolicy.requiresPrompt(for: .resume, assumeYes: false))

        XCTAssertTrue(ConfirmationPolicy.requiresPrompt(for: .stop, assumeYes: false))
        XCTAssertTrue(ConfirmationPolicy.requiresPrompt(for: .reboot, assumeYes: false))
        XCTAssertTrue(ConfirmationPolicy.requiresPrompt(for: .reset, assumeYes: false))
        XCTAssertTrue(ConfirmationPolicy.requiresPrompt(for: .suspend, assumeYes: false))

        XCTAssertFalse(ConfirmationPolicy.requiresPrompt(for: .stop, assumeYes: true))
    }
}
