@testable import ProxmoxCtlCore
import XCTest

final class InteractiveLoopTests: XCTestCase {
    func testBlankLinesAreIgnoredAndCommandsAreDispatched() async {
        let reader = FakeInteractiveLineReader(lines: ["", "   ", "nodes", "exit"])
        let loop = InteractiveLoop(lineReader: reader)
        var handled: [InteractiveInput] = []

        await loop.run(
            handle: { input in
                handled.append(input)
            },
            handleError: { _ in
                XCTFail("Unexpected parse error")
            }
        )

        XCTAssertEqual(handled, [.command(["nodes"])])
        XCTAssertEqual(reader.prompts, Array(repeating: "proxmoxctl> ", count: 4))
    }

    func testExitStopsWithoutDispatchingLaterCommands() async {
        let reader = FakeInteractiveLineReader(lines: ["exit", "nodes"])
        let loop = InteractiveLoop(lineReader: reader)
        var handled: [InteractiveInput] = []

        await loop.run(
            handle: { input in
                handled.append(input)
            },
            handleError: { _ in
                XCTFail("Unexpected parse error")
            }
        )

        XCTAssertEqual(handled, [])
        XCTAssertEqual(reader.prompts, ["proxmoxctl> "])
    }

    func testParseErrorsAreReportedAndLoopContinues() async {
        let reader = FakeInteractiveLineReader(lines: ["interactive", "nodes", "exit"])
        let loop = InteractiveLoop(lineReader: reader)
        var handled: [InteractiveInput] = []
        var errors: [InteractiveInputError] = []

        await loop.run(
            handle: { input in
                handled.append(input)
            },
            handleError: { error in
                if let inputError = error as? InteractiveInputError {
                    errors.append(inputError)
                }
            }
        )

        XCTAssertEqual(errors, [.nestedInteractive])
        XCTAssertEqual(handled, [.command(["nodes"])])
    }
}

final class InteractiveHistoryPolicyTests: XCTestCase {
    func testOnlyNonblankLinesAreRecorded() {
        XCTAssertFalse(InteractiveHistoryPolicy.shouldRecord(""))
        XCTAssertFalse(InteractiveHistoryPolicy.shouldRecord("   \t"))
        XCTAssertTrue(InteractiveHistoryPolicy.shouldRecord("help"))
        XCTAssertTrue(InteractiveHistoryPolicy.shouldRecord("cache clear"))
    }
}

private final class FakeInteractiveLineReader: InteractiveLineReader {
    private var lines: [String]
    private(set) var prompts: [String] = []

    init(lines: [String]) {
        self.lines = lines
    }

    func readLine(prompt: String) -> String? {
        prompts.append(prompt)
        guard !lines.isEmpty else {
            return nil
        }
        return lines.removeFirst()
    }
}
