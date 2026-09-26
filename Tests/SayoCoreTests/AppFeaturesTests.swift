import XCTest
import SayoCore

final class ApplicationAccessTests: XCTestCase {
    func testBlacklistAndWhitelistShareOneRule() {
        let black = ApplicationAccess(mode: .blacklist, bundleIDs: ["com.example.blocked"])
        XCTAssertFalse(black.allows(bundleIdentifier: "com.example.blocked"))
        XCTAssertTrue(black.allows(bundleIdentifier: "com.example.other"))
        XCTAssertTrue(black.allows(bundleIdentifier: nil))
        XCTAssertTrue(black.allows(bundleIdentifier: ""))

        let white = ApplicationAccess(mode: .whitelist, bundleIDs: ["com.example.allowed"])
        XCTAssertTrue(white.allows(bundleIdentifier: "com.example.allowed"))
        XCTAssertFalse(white.allows(bundleIdentifier: "com.example.other"))
        XCTAssertFalse(white.allows(bundleIdentifier: nil))
    }

    func testSettingsExposeTheActiveList() {
        var settings = AppSettings()
        settings.applicationFilterMode = .whitelist
        settings.applicationBundleIDs = ["com.apple.TextEdit"]
        XCTAssertEqual(settings.applicationAccess, ApplicationAccess(mode: .whitelist, bundleIDs: ["com.apple.TextEdit"]))
        XCTAssertTrue(settings.allowsApplication(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: "com.apple.Notes"))
    }
}
