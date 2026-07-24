@testable import ProxmoxCtlCore
import XCTest

final class GuestListPlanningTests: XCTestCase {
    func testNoOnlineNodesIsAnAvailabilityError() {
        let nodes = [
            NodeSummary(node: "pve01", status: "offline"),
            NodeSummary(node: "pve02", status: "unknown")
        ]

        XCTAssertThrowsError(
            try GuestListPlanner.nodeNames(explicitNode: nil, inventory: nodes)
        ) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .noOnlineNodes)
        }
    }

    func testOnlineNodesWithNoGuestsStillProduceAValidQueryPlan() throws {
        let nodes = [NodeSummary(node: "pve01", status: "online")]

        XCTAssertEqual(
            try GuestListPlanner.nodeNames(explicitNode: nil, inventory: nodes),
            ["pve01"]
        )
    }

    func testMixedNodeStatusSelectsOnlyOnlineNodesInInventoryOrder() throws {
        let nodes = [
            NodeSummary(node: "pve01", status: "offline"),
            NodeSummary(node: "pve02", status: "online"),
            NodeSummary(node: "pve03", status: "online")
        ]

        XCTAssertEqual(
            try GuestListPlanner.nodeNames(explicitNode: nil, inventory: nodes),
            ["pve02", "pve03"]
        )
    }

    func testExplicitNodeBypassesInventoryAvailability() throws {
        XCTAssertEqual(
            try GuestListPlanner.nodeNames(explicitNode: "pve99", inventory: nil),
            ["pve99"]
        )
    }
}
