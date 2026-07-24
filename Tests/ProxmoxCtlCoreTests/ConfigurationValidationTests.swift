import Foundation
@testable import ProxmoxCtlCore
import XCTest

final class ConfigurationValidationTests: XCTestCase {
    func testAliasRejectsEmptyAndWhitespaceOnlyValues() {
        for alias in ["", " ", "\t\n"] {
            XCTAssertThrowsError(try ConfigurationValidator.validateAlias(alias)) { error in
                XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostAlias)
            }
        }
    }

    func testAliasRejectsLeadingAndTrailingWhitespace() {
        for alias in [" home", "home ", "\thome", "home\n"] {
            XCTAssertThrowsError(try ConfigurationValidator.validateAlias(alias)) { error in
                XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostAlias)
            }
        }
    }

    func testAliasRejectsControlCharacters() {
        XCTAssertThrowsError(try ConfigurationValidator.validateAlias("home\u{0000}lab")) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostAlias)
        }
    }

    func testAliasAcceptsInternalSpacesWithoutChangingValue() throws {
        XCTAssertEqual(try ConfigurationValidator.validateAlias("home lab"), "home lab")
    }

    func testBaseURLAcceptsCanonicalAndTrailingSlashForms() throws {
        let expected = try XCTUnwrap(URL(string: "https://pve.example.test:8006"))

        XCTAssertEqual(
            try ConfigurationValidator.validateAndCanonicalizeBaseURL("https://pve.example.test:8006"),
            expected
        )
        XCTAssertEqual(
            try ConfigurationValidator.validateAndCanonicalizeBaseURL("https://pve.example.test:8006/"),
            expected
        )
    }

    func testBaseURLAcceptsMixedCaseHTTPSAndCanonicalizesScheme() throws {
        XCTAssertEqual(
            try ConfigurationValidator.validateAndCanonicalizeBaseURL("HTTPS://pve.example.test:8006"),
            try XCTUnwrap(URL(string: "https://pve.example.test:8006"))
        )
    }

    func testBaseURLRejectsMissingHost() {
        for value in ["https:example.test", "https:///path"] {
            XCTAssertThrowsError(try ConfigurationValidator.validateAndCanonicalizeBaseURL(value)) { error in
                XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostURL)
            }
        }
    }

    func testBaseURLRejectsUserInformation() {
        XCTAssertThrowsError(
            try ConfigurationValidator.validateAndCanonicalizeBaseURL("https://user:pass@pve.example.test:8006")
        ) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostURL)
        }
    }

    func testBaseURLRejectsUnsupportedComponents() {
        let values = [
            "https://pve.example.test:8006?debug=1",
            "https://pve.example.test:8006#fragment",
            "https://pve.example.test:8006/proxy",
            "https://pve.example.test:8006/api2/json"
        ]

        for value in values {
            XCTAssertThrowsError(try ConfigurationValidator.validateAndCanonicalizeBaseURL(value)) { error in
                XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostURL)
            }
        }
    }

    func testBaseURLRejectsNonHTTPSURL() {
        XCTAssertThrowsError(
            try ConfigurationValidator.validateAndCanonicalizeBaseURL("http://pve.example.test:8006")
        ) { error in
            XCTAssertEqual(error as? ProxmoxCtlError, .invalidHostURL)
        }
    }
}
