@testable import ProxmoxCtlCore
import XCTest

final class InteractiveInputParserTests: XCTestCase {
    func testBlankLineIsIgnored() throws {
        XCTAssertEqual(try InteractiveInputParser.parse("   "), .empty)
    }

    func testExitCommandsLeaveInteractiveMode() throws {
        XCTAssertEqual(try InteractiveInputParser.parse("exit"), .exit)
        XCTAssertEqual(try InteractiveInputParser.parse("quit"), .exit)
    }

    func testOptionalLeadingProgramNameIsRemoved() throws {
        XCTAssertEqual(try InteractiveInputParser.parse("proxmoxctl nodes"), .command(["nodes"]))
    }

    func testQuotesAndEscapesAreTokenizedLikeShellArguments() throws {
        let parsed = try InteractiveInputParser.parse(#"host add "home lab" --token-id 'root@pam!cli' --url https://example.test/\ path"#)

        XCTAssertEqual(
            parsed,
            .command([
                "host",
                "add",
                "home lab",
                "--token-id",
                "root@pam!cli",
                "--url",
                "https://example.test/ path"
            ])
        )
    }

    func testHelpAndCacheClearAreBuiltIns() throws {
        XCTAssertEqual(try InteractiveInputParser.parse("help"), .help)
        XCTAssertEqual(try InteractiveInputParser.parse("cache clear"), .cacheClear)
        XCTAssertEqual(try InteractiveInputParser.parse("proxmoxctl cache clear"), .cacheClear)
    }

    func testNestedInteractiveIsRejected() {
        XCTAssertThrowsError(try InteractiveInputParser.parse("interactive")) { error in
            XCTAssertEqual(error as? InteractiveInputError, .nestedInteractive)
        }
        XCTAssertThrowsError(try InteractiveInputParser.parse("proxmoxctl interactive")) { error in
            XCTAssertEqual(error as? InteractiveInputError, .nestedInteractive)
        }
    }

    func testUnterminatedQuoteIsRejected() {
        XCTAssertThrowsError(try InteractiveInputParser.parse(#"nodes "unterminated"#)) { error in
            XCTAssertEqual(error as? InteractiveInputError, .unterminatedQuote)
        }
    }
}
