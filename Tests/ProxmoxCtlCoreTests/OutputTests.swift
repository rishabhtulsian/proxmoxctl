import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class OutputTests: XCTestCase {
    func testTableRendererIncludesNodeAndGuestColumns() throws {
        let rows = [
            GuestSummary(
                vmid: 100,
                name: "router",
                status: "running",
                type: .qemu,
                mem: 1_073_741_824,
                maxmem: 2_147_483_648,
                uptime: 60
            )
        ]

        let table = TableRenderer.renderGuests(rows)

        XCTAssertTrue(table.contains("VMID"))
        XCTAssertTrue(table.contains("TYPE"))
        XCTAssertTrue(table.contains("router"))
        XCTAssertTrue(table.contains("1.0 GiB"))
    }

    func testJSONRendererProducesStableJSON() throws {
        let rows = [
            NodeSummary(node: "pve01", status: "online", cpu: 0.5, mem: 1024, maxmem: 2048, uptime: 10)
        ]

        let json = try JSONRenderer.render(rows)

        XCTAssertTrue(json.contains(#""node" : "pve01""#))
        XCTAssertTrue(json.contains(#""status" : "online""#))
    }
}
