import XCTest
import SayoCore
@testable import SayoUI

@MainActor final class CLIShortcutModelTests: XCTestCase {
    func testClearSavesNilAndDisplaysNotSetThenCanRebind() {
        let model = AppViewModel(settings: .init())
        var stored: String? = "ctrl+g"
        model.configureCLIShortcutAction = { _, key in stored = key }
        model.loadCLIShortcutAction = { _ in stored ?? "" }
        model.setCLIShortcut("agy", key: nil)
        XCTAssertNil(stored)
        XCTAssertEqual(model.cliShortcutDrafts["agy"], "")
        model.setCLIShortcut("agy", key: "f6")
        XCTAssertEqual(stored, "f6")
        XCTAssertEqual(model.cliShortcutDrafts["agy"], "f6")
    }
    func testFailedClearOrRecordingDoesNotChangeDisplayedBinding() {
        let model = AppViewModel(settings: .init())
        model.configureCLIShortcutAction = { _, _ in throw NSError(domain: "test", code: 1) }
        model.setCLIShortcut("claude", key: nil)
        XCTAssertEqual(model.cliShortcutDrafts["claude"], "ctrl+g")
        model.setCLIShortcut("claude", key: "f6")
        XCTAssertEqual(model.cliShortcutDrafts["claude"], "ctrl+g")
        XCTAssertTrue(model.noticeIsError)
    }
}
