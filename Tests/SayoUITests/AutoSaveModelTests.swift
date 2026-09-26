import XCTest
import SayoCore
@testable import SayoUI

@MainActor
final class AutoSaveModelTests: XCTestCase {
    func testAutoSaveCoalescesRapidChangesAndReportsCompletion() async throws {
        let model = AppViewModel(settings: .init())
        model.autoSaveDelayNanoseconds = 1_000_000
        var savedPrompts: [String] = []
        model.saveAction = { settings, _ in savedPrompts.append(settings.prompt) }

        model.settings.prompt = "First"
        model.scheduleAutoSave()
        model.settings.prompt = "Latest"
        model.scheduleAutoSave()

        XCTAssertEqual(model.settingsSaveState, .saving)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(savedPrompts, ["Latest"])
        XCTAssertEqual(model.settingsSaveState, .saved)
    }

    func testFailedAutoSaveReportsFailureAndRecoversOnNextChange() async throws {
        let model = AppViewModel(settings: .init())
        model.autoSaveDelayNanoseconds = 1_000_000
        var shouldFail = true
        model.saveAction = { _, _ in
            if shouldFail { throw NSError(domain: "AutoSaveModelTests", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Cannot save"]) }
        }

        model.scheduleAutoSave()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.settingsSaveState, .failed)
        XCTAssertEqual(model.notice, "Cannot save")

        shouldFail = false
        model.scheduleAutoSave()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.settingsSaveState, .saved)
        XCTAssertEqual(model.notice, "")
    }
}
