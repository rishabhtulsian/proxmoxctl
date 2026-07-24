import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class LifecyclePreflightTests: XCTestCase {
    func testUnsupportedLXCResetFailsBeforeConfirmationOrPost() async throws {
        let transport = LifecycleRecordingTransport(data: #"{"data":"unused"}"#)
        let client = try makeClient(transport: transport)
        var didConfirm = false

        do {
            _ = try await LifecyclePreflight.execute(
                operation: .reset,
                resolveNode: { "pve01" },
                resolveType: { _ in .lxc },
                authorize: { _, _ in didConfirm = true },
                perform: { node, type in
                    try await client.lifecycle(
                        node: node,
                        type: type,
                        vmid: 100,
                        operation: .reset
                    )
                }
            )
            XCTFail("Expected unsupported LXC reset to fail")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(error, .unsupportedOperation(.reset, .lxc))
        }

        XCTAssertFalse(didConfirm)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTargetResolutionFailureStopsBeforeTypeConfirmationAndPost() async throws {
        let transport = LifecycleRecordingTransport(
            data: #"{"data":[{"node":"pve01","status":"online"},{"node":"pve02","status":"online"}]}"#
        )
        let client = try makeClient(transport: transport)
        var didResolveType = false
        var didConfirm = false

        do {
            _ = try await LifecyclePreflight.execute(
                operation: .start,
                resolveNode: { try await client.singleNodeName() },
                resolveType: { _ in
                    didResolveType = true
                    return .qemu
                },
                authorize: { _, _ in didConfirm = true },
                perform: { _, _ in TaskID(value: "unused") }
            )
            XCTFail("Expected target resolution to fail")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(error, .nodeRequired(["pve01", "pve02"]))
        }

        XCTAssertFalse(didResolveType)
        XCTAssertFalse(didConfirm)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["GET"])
    }

    func testDeclinedConfirmationStopsBeforePost() async throws {
        let transport = LifecycleRecordingTransport(data: #"{"data":"unused"}"#)
        let client = try makeClient(transport: transport)

        do {
            _ = try await LifecyclePreflight.execute(
                operation: .shutdown,
                resolveNode: { "pve01" },
                resolveType: { _ in .qemu },
                authorize: { _, _ in throw ProxmoxCtlError.confirmationDeclined },
                perform: { node, type in
                    try await client.lifecycle(
                        node: node,
                        type: type,
                        vmid: 100,
                        operation: .shutdown
                    )
                }
            )
            XCTFail("Expected confirmation to be declined")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(error, .confirmationDeclined)
        }

        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNonInteractiveInputWithoutYesStopsBeforePromptAndPost() async throws {
        let transport = LifecycleRecordingTransport(data: #"{"data":"unused"}"#)
        let client = try makeClient(transport: transport)
        var didPrompt = false

        do {
            _ = try await LifecyclePreflight.execute(
                operation: .resume,
                resolveNode: { "pve01" },
                resolveType: { _ in .qemu },
                authorize: { _, _ in
                    try ConfirmationPolicy.authorize(
                        operation: .resume,
                        assumeYes: false,
                        isInteractive: false,
                        prompt: {
                            didPrompt = true
                            return true
                        }
                    )
                },
                perform: { node, type in
                    try await client.lifecycle(
                        node: node,
                        type: type,
                        vmid: 100,
                        operation: .resume
                    )
                }
            )
            XCTFail("Expected --yes requirement")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(error, .nonInteractiveConfirmationRequired(.resume))
        }

        XCTAssertFalse(didPrompt)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testApprovedExecutionPostsOnlyAfterAllGatesSucceed() async throws {
        let transport = LifecycleRecordingTransport(data: #"{"data":"UPID:pve01:123"}"#)
        let client = try makeClient(transport: transport)

        let task = try await LifecyclePreflight.execute(
            operation: .start,
            resolveNode: { "pve01" },
            resolveType: { _ in .qemu },
            authorize: { _, _ in
                try ConfirmationPolicy.authorize(
                    operation: .start,
                    assumeYes: true,
                    isInteractive: false,
                    prompt: { false }
                )
            },
            perform: { node, type in
                try await client.lifecycle(
                    node: node,
                    type: type,
                    vmid: 100,
                    operation: .start
                )
            }
        )

        XCTAssertEqual(task.value, "UPID:pve01:123")
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST"])
    }

    private func makeClient(transport: ProxmoxTransport) throws -> ProxmoxClient {
        ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )
    }
}

private final class LifecycleRecordingTransport: ProxmoxTransport {
    var requests: [URLRequest] = []
    private let data: Data

    init(data: String) {
        self.data = Data(data.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}
