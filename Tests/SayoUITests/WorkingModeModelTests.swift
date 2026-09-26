import XCTest
import SayoCore
@testable import SayoUI

@MainActor
final class WorkingModeModelTests: XCTestCase {
    func testChangingWorkingModeUpdatesDraftBeforeNotifyingRuntime() {
        let model = AppViewModel(settings: .init())
        var received: AppSettings?
        model.workingModeChangeAction = { received = $0 }

        model.changeWorkingMode(.silent)

        XCTAssertEqual(model.settings.mode, .silent)
        XCTAssertEqual(received?.mode, .silent)
        XCTAssertEqual(received?.activeGlobalShortcuts, model.settings.activeGlobalShortcuts)
    }

    func testSelectingCurrentWorkingModeDoesNotNotifyRuntimeAgain() {
        let model = AppViewModel(settings: .init())
        var notifications = 0
        model.workingModeChangeAction = { _ in notifications += 1 }

        model.changeWorkingMode(.manual)

        XCTAssertEqual(notifications, 0)
    }
}
