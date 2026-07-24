import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class HTTPDebugLoggingTests: XCTestCase {
    func testRequestLogIncludesMethodURLHeadersAndRedactsApiTokenSecret() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test:8006/api2/json/nodes")))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PVEAPIToken=admin@pve!cli=secret-token", forHTTPHeaderField: "Authorization")

        let output = HTTPDebugFormatter.formatRequest(request)

        XCTAssertTrue(output.contains("> GET https://example.test:8006/api2/json/nodes"))
        XCTAssertTrue(output.contains("> Accept: application/json"))
        XCTAssertTrue(output.contains("> Authorization: PVEAPIToken=admin@pve!cli=<redacted>"))
        XCTAssertFalse(output.contains("secret-token"))
    }

    func testResponseLogIncludesStatusHeadersAndBody() throws {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.test:8006/api2/json/version")),
            statusCode: 401,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let output = HTTPDebugFormatter.formatResponse(
            response,
            data: Data(#"{"errors":"permission denied"}"#.utf8)
        )

        XCTAssertTrue(output.contains("< HTTP 401"))
        XCTAssertTrue(output.contains("< Content-Type: application/json"))
        XCTAssertTrue(output.contains(#"< Body: {"errors":"permission denied"}"#))
    }

    func testRequestLogRedactsSecretsContainingDelimiterCharacters() throws {
        for secret in ["part1=part2", "part1=part2=part3"] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test:8006/api2/json/nodes")))
            request.setValue(
                "PVEAPIToken=admin@pve!cli=\(secret)",
                forHTTPHeaderField: "Authorization"
            )

            let output = HTTPDebugFormatter.formatRequest(request)

            XCTAssertTrue(output.contains("> Authorization: PVEAPIToken=admin@pve!cli=<redacted>"))
            for component in secret.split(separator: "=") {
                XCTAssertFalse(output.contains(component))
            }
        }
    }

    func testRequestLogFullyRedactsUnrecognizedAuthorizationFormat() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test:8006/api2/json/nodes")))
        request.setValue("Bearer sensitive-value", forHTTPHeaderField: "Authorization")

        let output = HTTPDebugFormatter.formatRequest(request)

        XCTAssertTrue(output.contains("> Authorization: <redacted>"))
        XCTAssertFalse(output.contains("sensitive-value"))
    }

    func testClientLogsRequestAndUnauthorizedResponse() async throws {
        let transport = RecordingDebugTransport(data: #"{"errors":"permission denied"}"#, statusCode: 401)
        let logger = BufferingHTTPDebugLogger()
        let client = ProxmoxClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test:8006")),
            tokenID: "admin@pve!cli",
            tokenSecret: "secret-token",
            transport: transport,
            debugLogger: logger
        )

        do {
            _ = try await client.version()
            XCTFail("Expected authorization failure")
        } catch ProxmoxCtlError.unauthorizedToken("admin@pve!cli") {
            let output = logger.entries.joined(separator: "\n")
            XCTAssertTrue(output.contains("> GET https://example.test:8006/api2/json/version"))
            XCTAssertTrue(output.contains("> Authorization: PVEAPIToken=admin@pve!cli=<redacted>"))
            XCTAssertTrue(output.contains("< HTTP 401"))
            XCTAssertTrue(output.contains(#"< Body: {"errors":"permission denied"}"#))
            XCTAssertFalse(output.contains("secret-token"))
        }
    }
}

private final class RecordingDebugTransport: ProxmoxTransport {
    private let data: Data
    private let statusCode: Int

    init(data: String, statusCode: Int) {
        self.data = Data(data.utf8)
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
