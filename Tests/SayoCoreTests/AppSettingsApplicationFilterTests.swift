import XCTest
@testable import SayoCore

final class AppSettingsApplicationFilterTests: XCTestCase {
    func testBlacklistIsDefaultAndAllowsUnselectedApps() {
        var settings = AppSettings()
        settings.applicationBundleIDs = ["com.example.blocked"]

        XCTAssertEqual(settings.applicationFilterMode, .blacklist)
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: "com.example.blocked"))
        XCTAssertTrue(settings.allowsApplication(bundleIdentifier: "com.example.allowed"))
    }

    func testWhitelistAllowsOnlySelectedApps() {
        var settings = AppSettings()
        settings.applicationFilterMode = .whitelist
        settings.applicationBundleIDs = ["com.example.allowed"]

        XCTAssertTrue(settings.allowsApplication(bundleIdentifier: "com.example.allowed"))
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: "com.example.other"))
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: nil))
    }

    func testLegacyExcludedBundleIDsMigrateToBlacklist() throws {
        let data = Data(#"{"excludedBundleIDs":["com.example.old"]}"#.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.applicationFilterMode, .blacklist)
        XCTAssertEqual(settings.applicationBundleIDs, ["com.example.old"])
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: "com.example.old"))
    }

    func testEncodingUsesNewApplicationFilterKeys() throws {
        var settings = AppSettings()
        settings.applicationFilterMode = .whitelist
        settings.applicationBundleIDs = ["com.example.editor"]

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["applicationFilterMode"] as? String, "whitelist")
        XCTAssertEqual(object["whitelistBundleIDs"] as? [String], ["com.example.editor"])
        XCTAssertEqual(object["blacklistBundleIDs"] as? [String], [])
        XCTAssertNil(object["applicationBundleIDs"])
        XCTAssertNil(object["excludedBundleIDs"])
    }
    func testListsStayIndependentAcrossEditsAndPersistence() throws {
        var settings = AppSettings()
        settings.applicationBundleIDs = ["blocked"]
        settings.applicationFilterMode = .whitelist
        XCTAssertTrue(settings.applicationBundleIDs.isEmpty)
        settings.applicationBundleIDs.append("allowed")
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: "blocked"))
        XCTAssertTrue(settings.allowsApplication(bundleIdentifier: "allowed"))

        settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(settings.applicationBundleIDs, ["allowed"])
        settings.applicationFilterMode = .blacklist
        XCTAssertEqual(settings.applicationBundleIDs, ["blocked"])
        XCTAssertFalse(settings.allowsApplication(bundleIdentifier: "blocked"))
        XCTAssertTrue(settings.allowsApplication(bundleIdentifier: "allowed"))
        settings.applicationBundleIDs.removeAll()
        settings.applicationFilterMode = .whitelist
        XCTAssertEqual(settings.applicationBundleIDs, ["allowed"])
    }

    func testSharedLegacyListMigratesOnlyIntoActiveMode() throws {
        for mode in ApplicationFilterMode.allCases {
            let data = Data("{\"applicationFilterMode\":\"\(mode.rawValue)\",\"applicationBundleIDs\":[\"legacy\"]}".utf8)
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(settings.applicationBundleIDs, ["legacy"])
            settings.applicationFilterMode = mode == .blacklist ? .whitelist : .blacklist
            XCTAssertTrue(settings.applicationBundleIDs.isEmpty)
        }
    }

    func testExplicitEmptyListsOverrideLegacyData() throws {
        let data = Data(#"{"applicationBundleIDs":["old"],"blacklistBundleIDs":[],"whitelistBundleIDs":["allowed"]}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(settings.blacklistBundleIDs.isEmpty)
        XCTAssertEqual(settings.whitelistBundleIDs, ["allowed"])
    }

}
