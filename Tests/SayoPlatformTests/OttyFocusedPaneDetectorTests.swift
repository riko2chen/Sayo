import XCTest
@testable import SayoPlatform

final class OttyFocusedPaneDetectorTests: XCTestCase {
    func testReadsFocusedAgentWithoutDependingOnTaskTitleOrOtherMetadata() {
        let data = Data(#"{"ok":true,"data":{"active":true,"agent":"Claude Code","process":"Custom task","cwd":"/private/project","agent_session_id":"private-session"}}"#.utf8)
        XCTAssertEqual(OttyFocusedPaneDetector.parse(data), .supported(.claude))
    }

    func testRecognizesSupportedAgentNamesAndRejectsOtherAgents() {
        for (name, expected) in [("claude", TerminalFocusedAgent.supported(.claude)),
                                 ("Codex", .supported(.codex)), ("agy", .supported(.agy)),
                                 ("Antigravity CLI", .supported(.agy)), ("omp", .unsupported)] {
            let data = Data("{\"ok\":true,\"data\":{\"active\":true,\"agent\":\"\(name)\"}}".utf8)
            XCTAssertEqual(OttyFocusedPaneDetector.parse(data), expected)
        }
    }

    func testMissingInvalidInactiveOrEmptyMetadataFallsBack() {
        for json in ["not JSON", "{}", #"{"ok":false,"data":{"active":true,"agent":"Claude Code"}}"#,
                     #"{"ok":true,"data":{"active":false,"agent":"Claude Code"}}"#,
                     #"{"ok":true,"data":{"active":true}}"#,
                     #"{"ok":true,"data":{"active":true,"agent":""}}"#] {
            XCTAssertNil(OttyFocusedPaneDetector.parse(Data(json.utf8)))
        }
    }
}
