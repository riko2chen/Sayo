import XCTest
import Sparkle
import SayoCore
@testable import SayoUpdates

@MainActor final class SparkleAppUpdaterTests: XCTestCase {
    func testCheckHistoryPersistsAcrossLaunchesAndManualChecksBypassAndRefreshIt() {
        let suite = "SayoUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(timeIntervalSince1970: 10000)
        let first = SparkleAppUpdater(defaults: defaults, now: { date })
        XCTAssertTrue(first.reserveCheck(automatically: true))
        let reopened = SparkleAppUpdater(defaults: UserDefaults(suiteName: suite)!, now: { date })
        date.addTimeInterval(3599)
        XCTAssertFalse(reopened.reserveCheck(automatically: true))
        XCTAssertTrue(reopened.reserveCheck(automatically: false))
        date.addTimeInterval(1)
        XCTAssertFalse(reopened.reserveCheck(automatically: true), "Manual check resets the hour")
        date.addTimeInterval(3599)
        XCTAssertTrue(reopened.reserveCheck(automatically: true))
        reopened.configure(automaticallyChecks: false, automaticallyDownloads: true)
        date.addTimeInterval(3600)
        XCTAssertFalse(reopened.reserveCheck(automatically: true))
        XCTAssertTrue(reopened.reserveCheck(automatically: false), "Manual checks work with automatic checks disabled")
    }

    func testAutomaticDownloadStopsAtReadyAndInstallRequiresAnAction() {
        let updater = SparkleAppUpdater()
        var downloads = 0
        var installs = 0
        var prompts = 0
        updater.onShowUpdate = { prompts += 1 }
        updater.showUserInitiatedUpdateCheck(cancellation: {})
        updater.showUpdateInFocus()
        XCTAssertEqual(updater.state, .checking)
        XCTAssertEqual(prompts, 0)
        updater.receiveUpdate(version: "1.0.0", downloaded: false, installing: false) { choice in
            XCTAssertEqual(choice, .install)
            downloads += 1
        }
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(updater.state, .downloading(version: "1.0.0", progress: nil))
        updater.showDownloadInitiated(cancellation: {})
        updater.showDownloadDidReceiveExpectedContentLength(100)
        updater.showDownloadDidReceiveData(ofLength: 25)
        XCTAssertEqual(updater.state, .downloading(version: "1.0.0", progress: 0.25))
        updater.showDownloadDidStartExtractingUpdate()
        XCTAssertEqual(updater.state, .preparing(version: "1.0.0"))
        updater.showUpdateInFocus()
        XCTAssertEqual(prompts, 0, "Checking, downloading and preparing must stay in the status button")
        updater.showReady(toInstallAndRelaunch: { _ in installs += 1 })
        XCTAssertEqual(updater.state, .readyToInstall(version: "1.0.0"))
        XCTAssertEqual(installs, 0)
        updater.checkForUpdates()
        updater.checkForUpdates()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(prompts, 1, "Only a ready update opens the prompt")
    }

    func testDisabledAutomaticDownloadsWaitForManualAction() {
        let updater = SparkleAppUpdater()
        updater.configure(automaticallyChecks: true, automaticallyDownloads: false)
        var downloads = 0
        var prompts = 0
        updater.onShowUpdate = { prompts += 1 }
        updater.receiveUpdate(version: "1.0.0", downloaded: false, installing: false) { _ in downloads += 1 }
        XCTAssertEqual(updater.state, .available(version: "1.0.0"))
        XCTAssertEqual(downloads, 0)
        updater.checkForUpdates()
        updater.checkForUpdates() // Repeated actions while downloading do nothing.
        updater.showUpdateInFocus()
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(prompts, 0)
    }

    func testPreviouslyDownloadedOrPreparedUpdatesNeverDownloadAutomaticallyAgain() {
        for installing in [false, true] {
            let updater = SparkleAppUpdater()
            var replies = 0
            var prompts = 0
            updater.onShowUpdate = { prompts += 1 }
            updater.receiveUpdate(version: "1.0.0", downloaded: !installing, installing: installing) { _ in replies += 1 }
            XCTAssertEqual(updater.state, .readyToInstall(version: "1.0.0"))
            XCTAssertEqual(replies, 0)
            XCTAssertEqual(prompts, 1, "Cached ready updates can prompt immediately")
            updater.checkForUpdates()
            XCTAssertEqual(replies, 1)
            XCTAssertEqual(updater.state, installing ? .installing(version: "1.0.0") : .preparing(version: "1.0.0"))
        }
    }

    func testEnablingDownloadsStartsAnAlreadyOfferedUpdateExactlyOnce() {
        let updater = SparkleAppUpdater()
        updater.configure(automaticallyChecks: false, automaticallyDownloads: false)
        var downloads = 0
        updater.receiveUpdate(version: "1.0.0", downloaded: false, installing: false) { _ in downloads += 1 }
        updater.configure(automaticallyChecks: false, automaticallyDownloads: true)
        updater.configure(automaticallyChecks: false, automaticallyDownloads: true)
        XCTAssertEqual(downloads, 1)
    }

    func testUpgradeRequiringAttentionWaitsForAnExplicitDownloadEvenWhenPreferenceChanges() {
        let updater = SparkleAppUpdater()
        var downloads = 0
        updater.receiveUpdate(version: "2.0.0", downloaded: false, installing: false, automaticallyDownloadAllowed: false) { _ in downloads += 1 }
        updater.configure(automaticallyChecks: true, automaticallyDownloads: false)
        updater.configure(automaticallyChecks: true, automaticallyDownloads: true)
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(updater.state, .available(version: "2.0.0"))
        updater.checkForUpdates()
        XCTAssertEqual(downloads, 1)
    }

    func testFailedDownloadClearsTheOldActionAndAcknowledgesSparkle() {
        let updater = SparkleAppUpdater()
        updater.configure(automaticallyChecks: true, automaticallyDownloads: false)
        var downloads = 0
        var acknowledgements = 0
        var prompts = 0
        updater.onShowUpdate = { prompts += 1 }
        updater.receiveUpdate(version: "1.0.0", downloaded: false, installing: false) { _ in downloads += 1 }
        updater.showUpdaterError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline"])) {
            acknowledgements += 1
        }
        updater.dismissUpdateInstallation()
        updater.checkForUpdates()
        updater.showUpdateInFocus()
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(updater.state, .failed("Offline"))
        XCTAssertEqual(prompts, 0, "An error must not interrupt the user")
    }

    func testUnsupportedSystemIsNotReportedAsAlreadyUpToDate() {
        let updater = SparkleAppUpdater()
        var prompts = 0
        updater.onShowUpdate = { prompts += 1 }
        for (reason, expected) in [(SPUNoUpdateFoundReason.onLatestVersion, AppUpdateState.upToDate),
                                   (.systemIsTooOld, .unavailable("Requires a newer macOS"))] {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue),
                                           NSLocalizedDescriptionKey: "Requires a newer macOS"])
            var acknowledged = false
            updater.showUpdateNotFoundWithError(error) { acknowledged = true }
            updater.dismissUpdateInstallation()
            updater.showUpdateInFocus()
            XCTAssertEqual(updater.state, expected)
            XCTAssertTrue(acknowledged)
            XCTAssertEqual(prompts, 0)
        }
    }
}
