import XCTest
import SayoCore

final class AppUpdatesTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    func testAutomaticCheckCacheExpiresAtExactlyOneHour() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertTrue(AppUpdateCheckCache().shouldCheckAutomatically(at: now))
        let cache = AppUpdateCheckCache(lastCheck: now)
        XCTAssertFalse(cache.shouldCheckAutomatically(at: now))
        XCTAssertFalse(cache.shouldCheckAutomatically(at: now.addingTimeInterval(3599)))
        XCTAssertTrue(cache.shouldCheckAutomatically(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(cache.shouldCheckAutomatically(at: now.addingTimeInterval(7200)))
        XCTAssertTrue(cache.shouldCheckAutomatically(at: now.addingTimeInterval(-1)), "A clock correction must not block checks indefinitely")
    }

    func testUpdatePreferencesDefaultToEnabledForNewAndExistingUsers() throws {
        for settings in [AppSettings(), try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))] {
            XCTAssertTrue(settings.automaticallyChecksForUpdates)
            XCTAssertTrue(settings.automaticallyDownloadsUpdates)
        }
        var settings = AppSettings()
        settings.automaticallyChecksForUpdates = false
        settings.automaticallyDownloadsUpdates = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.automaticallyChecksForUpdates)
        XCTAssertFalse(restored.automaticallyDownloadsUpdates)
    }

    func testUnpublishedBuildDoesNotConfigureAnUpdater() {
        XCTAssertNil(AppUpdateConfiguration(info: [:]))
        XCTAssertNil(AppUpdateConfiguration(info: ["SUFeedURL": "", "SUPublicEDKey": ""]))
    }

    func testPublicHTTPSFeedAndSigningKeyAreRequiredTogether() {
        let url = "https://github.com/example/sayo/releases/latest/download/appcast.xml"
        XCTAssertEqual(AppUpdateConfiguration(info: ["SUFeedURL": url, "SUPublicEDKey": key])?.feedURL.absoluteString, url)
        for unsafeURL in ["http://example.com/feed.xml", "file:///tmp/feed.xml", "https://user:secret@example.com/feed.xml", "https://example.com/feed.xml?token=secret", "https://example.com/feed.xml#fragment"] {
            XCTAssertNil(AppUpdateConfiguration(info: ["SUFeedURL": unsafeURL, "SUPublicEDKey": key]))
        }
        for invalidKey in ["", "not-a-key", Data(repeating: 1, count: 31).base64EncodedString()] {
            XCTAssertNil(AppUpdateConfiguration(info: ["SUFeedURL": url, "SUPublicEDKey": invalidKey]))
        }
    }
}
