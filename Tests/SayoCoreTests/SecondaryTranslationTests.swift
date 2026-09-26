import XCTest
@testable import SayoCore

final class SecondaryTranslationTests: XCTestCase {
    func testNewAndExistingConfigurationsStartUnboundWithCopiedPrompt() throws {
        let fresh = AppSettings()
        XCTAssertNil(fresh.secondaryShortcut)
        XCTAssertEqual(fresh.secondaryPrompt, fresh.prompt)
        XCTAssertNotEqual(fresh.secondaryTargetLanguage, fresh.targetLanguage)

        let data = Data(#"{"schemaVersion":3,"prompt":"Keep it short in ${targetLanguage}.","targetLanguage":"simplifiedChinese"}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(migrated.secondaryShortcut)
        XCTAssertEqual(migrated.secondaryPrompt, migrated.prompt)
        XCTAssertEqual(migrated.secondaryTargetLanguage, .english)
        XCTAssertEqual(migrated.effectivePrompt(for: .secondary), "Keep it short in English.")
    }

    func testLegacyBuiltInPromptMigratesBeforeCopying() throws {
        let data = try JSONEncoder().encode(["prompt": AppSettings.translatingDefaultPrompt])
        let migrated = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(migrated.secondaryPrompt, AppSettings.defaultPrompt)
        XCTAssertTrue(migrated.effectivePrompt(for: .secondary).contains("in Simplified Chinese"))
    }

    func testCustomPromptsAndLanguagesRemainIndependentAcrossSaves() throws {
        var settings = AppSettings()
        settings.prompt = "First: ${targetLanguage}"
        settings.secondaryPrompt = "Second: ${targetLanguage}"
        settings.secondaryTargetLanguage = .japanese
        settings.secondaryShortcut = Shortcut(keyCode: 40, command: false, control: true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.effectivePrompt, "First: English")
        XCTAssertEqual(decoded.effectivePrompt(for: .secondary), "Second: Japanese")
        settings.secondaryPrompt = "Use a friendly tone."
        XCTAssertEqual(settings.effectivePrompt(for: .secondary), "Use a friendly tone.\n\nOutput language requirement: Write the final result in Japanese.")
        XCTAssertEqual(settings.effectivePrompt, "First: English")
    }

    func testShortcutCanBeSetAndClearedInEveryMode() throws {
        let shortcut = Shortcut(keyCode: 40, command: false, control: true)
        for mode in WorkingMode.allCases {
            var settings = AppSettings()
            settings.mode = mode
            XCTAssertFalse(settings.activeGlobalShortcuts.contains(shortcut))
            settings.secondaryShortcut = shortcut
            XCTAssertTrue(settings.activeGlobalShortcuts.contains(shortcut))
            settings.secondaryShortcut = nil
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertNil(decoded.secondaryShortcut)
            XCTAssertFalse(decoded.activeGlobalShortcuts.contains(shortcut))
        }
    }

    func testSecondShortcutMustDifferFromEveryPrimaryActionEvenInSilentMode() throws {
        let second = Shortcut(keyCode: 40, command: false, control: true)
        for mode in WorkingMode.allCases {
            for keyPath in [\AppSettings.invokeShortcut, \.copyShortcut, \.replaceShortcut] {
                var settings = AppSettings()
                settings.mode = mode
                settings.secondaryShortcut = second
                XCTAssertNoThrow(try settings.validateTranslationShortcuts())
                settings[keyPath: keyPath] = second
                XCTAssertThrowsError(try settings.validateTranslationShortcuts())
            }
        }
        XCTAssertNoThrow(try AppSettings().validateTranslationShortcuts())
    }

    func testRewriteRequestUsesTheDestinationsLanguageAndPrompt() {
        var settings = AppSettings()
        settings.targetLanguage = .english
        settings.secondaryTargetLanguage = .japanese
        settings.prompt = "First ${targetLanguage}"
        settings.secondaryPrompt = "Second ${targetLanguage}"
        let primary = settings.rewriteRequest(text: "hi", destination: .primary)
        XCTAssertEqual(primary.targetLanguage, .english)
        XCTAssertEqual(primary.prompt, "First English")
        let secondary = settings.rewriteRequest(text: "hi", destination: .secondary)
        XCTAssertEqual(secondary.targetLanguage, .japanese)
        XCTAssertEqual(secondary.prompt, "Second Japanese")
        XCTAssertEqual(secondary.text, "hi")
    }
}
