import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class ProxmoxClientTests: XCTestCase {
    func testNodesUsesApiTokenAuthorizationAndNodesEndpoint() async throws {
        let transport = RecordingTransport(
            data: #"{"data":[{"node":"pve01","status":"online","cpu":0.25,"mem":2048,"maxmem":4096,"uptime":120}]}"#
        )
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let nodes = try await client.nodes()

        XCTAssertEqual(nodes.map(\.node), ["pve01"])
        XCTAssertEqual(transport.requests.first?.url?.path, "/api2/json/nodes")
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "PVEAPIToken=root@pam!cli=secret-token"
        )
    }

    func testSingleNodeNameReturnsTheOnlyNode() async throws {
        let transport = RecordingTransport(
            data: #"{"data":[{"node":"pve01","status":"online"}]}"#
        )
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let nodeName = try await client.singleNodeName()

        XCTAssertEqual(nodeName, "pve01")
        XCTAssertEqual(transport.requests.first?.url?.path, "/api2/json/nodes")
    }

    func testSingleNodeNameRequiresExplicitNodeWhenMultipleNodesExist() async throws {
        let transport = RecordingTransport(
            data: #"{"data":[{"node":"pve01","status":"online"},{"node":"pve02","status":"online"}]}"#
        )
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        do {
            _ = try await client.singleNodeName()
            XCTFail("Expected multiple nodes to require --node")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(error, .nodeRequired(["pve01", "pve02"]))
            XCTAssertEqual(error.errorDescription, "Cluster has multiple nodes (pve01, pve02). Pass --node.")
        }
    }

    func testNodesUsesSessionCacheForSameHostAlias() async throws {
        let transport = SequencedTransport(responses: [
            .init(data: #"{"data":[{"node":"pve01","status":"online"}]}"#)
        ])
        let cache = SessionCache()
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport,
            hostAlias: "home1",
            sessionCache: cache
        )

        let first = try await client.nodes()
        let second = try await client.nodes()
        let singleNodeName = try await client.singleNodeName()

        XCTAssertEqual(first.map(\.node), ["pve01"])
        XCTAssertEqual(second.map(\.node), ["pve01"])
        XCTAssertEqual(singleNodeName, "pve01")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNodesSessionCacheKeepsHostAliasesIndependent() async throws {
        let transport = SequencedTransport(responses: [
            .init(data: #"{"data":[{"node":"pve01","status":"online"}]}"#),
            .init(data: #"{"data":[{"node":"pve02","status":"online"}]}"#)
        ])
        let cache = SessionCache()
        let home1 = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://one.example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport,
            hostAlias: "home1",
            sessionCache: cache
        )
        let home2 = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://two.example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport,
            hostAlias: "home2",
            sessionCache: cache
        )

        let home1FirstNodes = try await home1.nodes().map(\.node)
        let home2Nodes = try await home2.nodes().map(\.node)
        let home1SecondNodes = try await home1.nodes().map(\.node)

        XCTAssertEqual(home1FirstNodes, ["pve01"])
        XCTAssertEqual(home2Nodes, ["pve02"])
        XCTAssertEqual(home1SecondNodes, ["pve01"])

        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSessionCacheClearInvalidatesNodes() async throws {
        let transport = SequencedTransport(responses: [
            .init(data: #"{"data":[{"node":"pve01","status":"online"}]}"#),
            .init(data: #"{"data":[{"node":"pve01","status":"online"},{"node":"pve02","status":"online"}]}"#)
        ])
        let cache = SessionCache()
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport,
            hostAlias: "home1",
            sessionCache: cache
        )

        let firstNodes = try await client.nodes().map(\.node)
        cache.clearAll()
        let secondNodes = try await client.nodes().map(\.node)

        XCTAssertEqual(firstNodes, ["pve01"])
        XCTAssertEqual(secondNodes, ["pve01", "pve02"])

        XCTAssertEqual(transport.requests.count, 2)
    }

    func testGuestsUsesQemuAndLxcEndpoints() async throws {
        let transport = RecordingTransport(
            data: #"{"data":[{"vmid":100,"name":"router","status":"running","mem":1024,"maxmem":2048,"uptime":300}]}"#
        )
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let guests = try await client.guests(node: "pve01", type: .qemu)

        XCTAssertEqual(guests.first?.vmid, 100)
        XCTAssertEqual(guests.first?.type, .qemu)
        XCTAssertEqual(transport.requests.first?.url?.path, "/api2/json/nodes/pve01/qemu")
    }

    func testLifecyclePostsOperationAndReturnsTaskID() async throws {
        let transport = RecordingTransport(data: #"{"data":"UPID:pve01:123"}"#)
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let taskID = try await client.lifecycle(node: "pve01", type: .qemu, vmid: 100, operation: .shutdown)

        XCTAssertEqual(taskID.value, "UPID:pve01:123")
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")
        XCTAssertEqual(
            transport.requests.first?.url?.path,
            "/api2/json/nodes/pve01/qemu/100/status/shutdown"
        )
    }

    func testGuestStatusWithoutTypeUsesClusterInventoryBeforeSpecificStatusEndpoint() async throws {
        let transport = SequencedTransport(responses: [
            .init(data: #"{"data":[{"vmid":200,"name":"db","status":"running","type":"lxc","node":"pve01"}]}"#),
            .init(data: #"{"data":{"vmid":200,"name":"db","status":"running"}}"#)
        ])
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let guest = try await client.guestStatus(node: "pve01", vmid: 200)

        XCTAssertEqual(guest.type, .lxc)
        XCTAssertEqual(guest.name, "db")
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/api2/json/cluster/resources",
            "/api2/json/nodes/pve01/lxc/200/status/current"
        ])
        XCTAssertEqual(transport.requests.first?.url?.query, "type=vm")
    }

    func testResolveGuestTypeUsesClusterInventoryBeforeLifecyclePost() async throws {
        let transport = SequencedTransport(responses: [
            .init(data: #"{"data":[{"vmid":200,"name":"db","status":"stopped","type":"lxc","node":"pve01"}]}"#),
            .init(data: #"{"data":"UPID:pve01:123"}"#)
        ])
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let type = try await client.resolveGuestType(node: "pve01", vmid: 200)
        let taskID = try await client.lifecycle(node: "pve01", type: type, vmid: 200, operation: .start)

        XCTAssertEqual(type, .lxc)
        XCTAssertEqual(taskID.value, "UPID:pve01:123")
        XCTAssertEqual(transport.requests.map { $0.httpMethod }, ["GET", "POST"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/api2/json/cluster/resources",
            "/api2/json/nodes/pve01/lxc/200/status/start"
        ])
        XCTAssertEqual(transport.requests.first?.url?.query, "type=vm")
    }

    func testGuestStatusFallsBackToEndpointProbeWhenInventoryDoesNotReturnVmid() async throws {
        let transport = SequencedTransport(responses: [
            .init(data: #"{"data":[]}"#),
            .init(
                data: #"{"message":"Configuration file 'nodes/pve01/qemu-server/200.conf' does not exist\n","data":null}"#,
                statusCode: 500
            ),
            .init(data: #"{"data":{"vmid":200,"name":"db","status":"running"}}"#)
        ])
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        let guest = try await client.guestStatus(node: "pve01", vmid: 200)

        XCTAssertEqual(guest.type, .lxc)
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/api2/json/cluster/resources",
            "/api2/json/nodes/pve01/qemu/200/status/current",
            "/api2/json/nodes/pve01/lxc/200/status/current"
        ])
    }

    func testUnsupportedLifecycleCombinationFailsBeforeNetworkRequest() async throws {
        let transport = RecordingTransport(data: #"{"data":"unused"}"#)
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "root@pam!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        do {
            _ = try await client.lifecycle(node: "pve01", type: .lxc, vmid: 100, operation: .reset)
            XCTFail("Expected reset to be rejected for LXC guests")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(error.errorDescription, "Operation reset is not supported for lxc guests.")
            XCTAssertEqual(transport.requests.count, 0)
        }
    }

    func testUnauthorizedResponseIncludesTokenIDWithoutSecret() async throws {
        let transport = RecordingTransport(data: "", statusCode: 401)
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "admin@pve!cli",
            tokenSecret: "secret-token",
            transport: transport
        )

        do {
            _ = try await client.version()
            XCTFail("Expected authorization failure")
        } catch let error as ProxmoxCtlError {
            XCTAssertEqual(
                error.errorDescription,
                "Proxmox rejected API token admin@pve!cli with HTTP 401. Check that the token ID uses the exact user realm and token name, and that the stored token secret is the UUID/secret value, not a password."
            )
        }
    }
}

private final class RecordingTransport: ProxmoxTransport {
    var requests: [URLRequest] = []
    private let data: Data
    private let statusCode: Int

    init(data: String, statusCode: Int = 200) {
        self.data = Data(data.utf8)
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private struct SequencedResponse {
    let data: Data
    let statusCode: Int

    init(data: String, statusCode: Int = 200) {
        self.data = Data(data.utf8)
        self.statusCode = statusCode
    }
}

private final class SequencedTransport: ProxmoxTransport {
    var requests: [URLRequest] = []
    private var responses: [SequencedResponse]

    init(responses: [SequencedResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, httpResponse)
    }
}
