import XCTest
import SayoCore
import SayoUI

@MainActor final class AppUpdateModelTests: XCTestCase {
    func testDirectEditionDispatchesOnlyWhenUpdaterIsReady() {
        let model = AppViewModel(settings: .init())
        var requests = 0
        model.checkForUpdatesAction = { requests += 1 }
        for state in [AppUpdateState.notConfigured, .checking, .downloading(version: "1.0.0", progress: nil),
                      .preparing(version: "1.0.0"), .installing(version: "1.0.0")] {
            model.updateState = state
            XCTAssertFalse(model.canRequestUpdateCheck)
            model.checkForUpdates()
        }
        XCTAssertEqual(requests, 0)
        model.updateState = .ready
        model.checkForUpdates()
        XCTAssertEqual(requests, 1)
    }

    func testUnconfiguredBuildShowsAnUnavailableStatusWithoutAnAction() {
        let model = AppViewModel(settings: .init())
        model.settings.interfaceLanguage = .simplifiedChinese
        XCTAssertFalse(model.canRequestUpdateCheck)
        XCTAssertEqual(model.updateActionTitle, "更新不可用")
    }

    func testFailedCheckCanBeRetriedButAnActiveCheckCannotBeDuplicated() {
        let model = AppViewModel(settings: .init())
        var requests = 0
        model.checkForUpdatesAction = { requests += 1 }
        model.updateState = .failed("Offline")
        XCTAssertTrue(model.canRequestUpdateCheck)
        model.checkForUpdates()
        XCTAssertEqual(requests, 1)

        model.updateState = .checking
        XCTAssertFalse(model.canRequestUpdateCheck)
        model.checkForUpdates()
        XCTAssertEqual(requests, 1)
    }

    func testButtonReflectsDownloadAndInstallStagesInBothLanguages() {
        let model = AppViewModel(settings: .init())
        for (language, download, install) in [(InterfaceLanguage.english, "Download Update", "Update Now"),
                                             (.simplifiedChinese, "下载更新", "点击更新")] {
            model.settings.interfaceLanguage = language
            model.updateState = .available(version: "1.0.0")
            XCTAssertEqual(model.updateActionTitle, download)
            model.updateState = .readyToInstall(version: "1.0.0")
            XCTAssertEqual(model.updateActionTitle, install)
            XCTAssertTrue(model.canRequestUpdateCheck)
        }
    }

    func testButtonShowsCheckProgressAndResultWithoutNeedingADialog() {
        let model = AppViewModel(settings: .init())
        model.settings.interfaceLanguage = .simplifiedChinese
        model.updateState = .checking
        XCTAssertEqual(model.updateActionTitle, "检查更新中")
        model.updateState = .downloading(version: "1.0.0", progress: 0.4)
        XCTAssertEqual(model.updateActionTitle, "下载中 40%")
        XCTAssertFalse(model.canRequestUpdateCheck)
        model.updateState = .upToDate
        XCTAssertEqual(model.updateActionTitle, "已是最新版本")
        XCTAssertTrue(model.canRequestUpdateCheck)
        model.updateState = .failed("Offline")
        XCTAssertEqual(model.updateActionTitle, "更新失败 · 重试")
        XCTAssertTrue(model.canRequestUpdateCheck)
    }

    func testUpdatePreferencesAreAppliedImmediatelyAndIndependently() {
        let model = AppViewModel(settings: .init())
        var changes: [[Bool]] = []
        model.updatePreferencesAction = { changes.append([$0, $1]) }
        model.settings.automaticallyChecksForUpdates = false
        model.settings.automaticallyDownloadsUpdates = false
        model.settings.interfaceLanguage = .english
        XCTAssertEqual(changes, [[false, true], [false, false]])
    }
}
