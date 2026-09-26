import XCTest
import SayoCore
@testable import SayoPlatform

@MainActor final class SettingsPersistenceTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var legacyURL: URL { directory.appendingPathComponent("settings.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testFirstLaunchCreatesVersionedConfigAndPrivateFile() throws {
        let settings = try DiskSettingsRepository(url: configURL).load()
        XCTAssertEqual(settings, AppSettings())
        let json = try object(at: configURL)
        XCTAssertEqual(json["schemaVersion"] as? Int, AppSettings.configVersion)
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try DiskSettingsRepository(url: configURL).load(), settings)
    }

    func testEverySavedPreferenceSurvivesMovingConfigToAnotherInstallation() throws {
        var settings = AppSettings()
        settings.mode = .manual
        settings.prompt = "保留语气。"
        settings.interfaceLanguage = .simplifiedChinese
        settings.targetLanguage = .japanese
        settings.invokeShortcut = nil
        settings.copyShortcut = Shortcut(keyCode: 8, command: true)
        settings.replaceShortcut = nil
        settings.copyPasteCompatibilityEnabled = true
        settings.developerMode = true
        settings.retainDiagnosticLogs = false
        settings.launchAtLogin = true
        settings.automaticallyChecksForUpdates = false
        settings.automaticallyDownloadsUpdates = false
        settings.statusBarIconStyle = .monochrome
        settings.onboardingCompleted = true
        settings.applicationFilterMode = .whitelist
        settings.applicationBundleIDs = ["com.apple.TextEdit"]
        settings.llm.provider = .deepSeek
        settings.llm.baseURL = "https://example.test/v1"
        settings.llm.model = "custom-model"
        settings.providerConfigurations[ProviderKind.deepSeek.rawValue] = settings.llm
        var other = LLMConfiguration()
        other.model = "local-model"
        other.baseURL = "http://localhost:8317/v1"
        settings.providerConfigurations[other.provider.rawValue] = other
        try DiskSettingsRepository(url: configURL).save(settings)
        let destination = directory.appendingPathComponent("another-installation/config.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: configURL, to: destination)
        XCTAssertEqual(try DiskSettingsRepository(url: destination).load(), settings)
    }

    func testLegacyMigrationHandlesMissingNestedFieldsAndExcludesSecrets() throws {
        let legacy = Data(#"{"mode":"silent","llm":{"provider":"deepSeek","model":"saved-model","apiKey":"nested-secret"},"apiKey":"top-secret","token":"legacy-token","excludedBundleIDs":["com.example.private"],"shortcut":{"keyCode":36,"command":true,"option":false,"control":false,"shift":true}}"#.utf8)
        try legacy.write(to: legacyURL)
        let settings = try DiskSettingsRepository(url: configURL).load()
        XCTAssertEqual(settings.mode, .silent)
        XCTAssertEqual(settings.llm.provider, .deepSeek)
        XCTAssertEqual(settings.llm.baseURL, ProviderKind.deepSeek.defaultBaseURL)
        XCTAssertEqual(settings.llm.model, "saved-model")
        XCTAssertEqual(settings.applicationBundleIDs, ["com.example.private"])
        XCTAssertEqual(settings.invokeShortcut, Shortcut())
        XCTAssertEqual(settings.replaceShortcut, Shortcut())
        let encoded = try String(contentsOf: configURL, encoding: .utf8)
        for secret in ["apiKey", "token", "nested-secret", "top-secret", "legacy-token"] {
            XCTAssertFalse(encoded.contains(secret))
        }
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacy, "Keep the old file untouched for older releases.")
        XCTAssertEqual(try DiskSettingsRepository(url: configURL).load(), settings)
    }

    func testNewConfigTakesPrecedenceOverLegacyFile() throws {
        try Data(#"{"mode":"silent"}"#.utf8).write(to: legacyURL)
        try Data(#"{"schemaVersion":1,"mode":"manual"}"#.utf8).write(to: configURL)
        XCTAssertEqual(try DiskSettingsRepository(url: configURL).load().mode, .manual)
    }

    func testDamagedOrFutureConfigIsNeverReplacedOrLoadedFromLegacy() throws {
        try Data(#"{"mode":"silent"}"#.utf8).write(to: legacyURL)
        for content in ["{broken", #"{"schemaVersion":999,"mode":"manual"}"#, #"{"llm":{"model":42}}"#] {
            let original = Data(content.utf8)
            try original.write(to: configURL)
            let repository = DiskSettingsRepository(url: configURL)
            XCTAssertThrowsError(try repository.load())
            XCTAssertThrowsError(try repository.save(AppSettings()))
            XCTAssertEqual(try Data(contentsOf: configURL), original)
        }
    }

    func testDamagedLegacyFileIsPreservedAndDoesNotCreateDefaultConfig() throws {
        try Data("{broken".utf8).write(to: legacyURL)
        let repository = DiskSettingsRepository(url: configURL)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(AppSettings()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testCredentialBearingEndpointsCannotEnterConfigIncludingInactiveProviders() throws {
        let repository = DiskSettingsRepository(url: configURL)
        try repository.save(AppSettings())
        let original = try Data(contentsOf: configURL)
        for endpoint in ["https://user:secret@example.test/v1", "https://example.test/v1?key=secret", "https://example.test/v1#secret", "https://[broken/v1?key=secret"] {
            for active in [true, false] {
                var settings = AppSettings()
                var configuration = LLMConfiguration()
                configuration.baseURL = endpoint
                if active { settings.llm = configuration }
                else { settings.providerConfigurations[configuration.provider.rawValue] = configuration }
                XCTAssertThrowsError(try repository.save(settings)) { error in
                    XCTAssertFalse(error.localizedDescription.contains(endpoint))
                }
                XCTAssertEqual(try Data(contentsOf: configURL), original)
            }
        }
    }

    func testModelConfigEncodingUsesOnlyNonSecretFields() throws {
        var settings = AppSettings()
        for kind in ProviderKind.allCases {
            var configuration = LLMConfiguration()
            configuration.provider = kind
            configuration.baseURL = kind.defaultBaseURL
            settings.providerConfigurations[kind.rawValue] = configuration
        }
        try DiskSettingsRepository(url: configURL).save(settings)
        let json = try object(at: configURL)
        let configurations = try XCTUnwrap(json["providerConfigurations"] as? [String: [String: Any]])
        let allowed: Set<String> = ["provider", "baseURL", "model"]
        for configuration in Array(configurations.values) + [try XCTUnwrap(json["llm"] as? [String: Any])] {
            XCTAssertEqual(Set(configuration.keys), allowed)
        }
    }

    func testLegacyTemperatureFieldsAreIgnoredAndRemovedOnSave() throws {
        try Data(#"{"schemaVersion":2,"llm":{"provider":"openAICompatible","baseURL":"https://api.example.com/v1","model":"test","temperature":0.8,"useCustomTemperature":true}}"#.utf8).write(to: configURL)
        let repository = DiskSettingsRepository(url: configURL)
        let settings = try repository.load()

        XCTAssertEqual(settings.llm.model, "test")
        try repository.save(settings)

        let llm = try XCTUnwrap(try object(at: configURL)["llm"] as? [String: Any])
        XCTAssertNil(llm["temperature"])
        XCTAssertNil(llm["useCustomTemperature"])
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
