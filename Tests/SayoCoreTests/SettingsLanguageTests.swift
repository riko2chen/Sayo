import XCTest
@testable import SayoCore

final class SettingsLanguageTests: XCTestCase {
    func testDeveloperModeDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).developerMode)
        var settings = AppSettings()
        settings.developerMode = true
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).developerMode)
    }

    func testDiagnosticLogRetentionDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).retainDiagnosticLogs)
        var settings = AppSettings()
        settings.retainDiagnosticLogs = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).retainDiagnosticLogs)
    }

    func testStatusBarIconStyleDefaultsToBrandAndRoundTrips() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).statusBarIconStyle,
            .brand
        )
        var settings = AppSettings()
        settings.statusBarIconStyle = .monochrome
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).statusBarIconStyle,
            .monochrome
        )
    }

    func testRetiredOptionsAreIgnoredAndNotWrittenBack() throws {
        let legacy = Data(#"{"showButtonShortcuts":false,"animateResultText":false,"animateReplacementText":false,"showInDock":true,"selectAllFallbackEnabled":false,"prompt":"Keep."}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(settings.prompt, "Keep.")
        let written = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        for key in ["showButtonShortcuts", "animateResultText", "animateReplacementText", "showInDock", "selectAllFallbackEnabled"] {
            XCTAssertFalse(written.contains(key), key)
        }
    }

    func testShippedPromptsMigrateAndFollowEveryTargetLanguage() throws {
        for oldPrompt in [AppSettings.translatingDefaultPrompt, AppSettings.rewritingDefaultPrompt, AppSettings.previousDefaultPrompt, AppSettings.legacyEnglishPrompt] {
            let data = try JSONEncoder().encode(["prompt": oldPrompt])
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(settings.prompt, AppSettings.defaultPrompt)
            for language in TargetLanguage.allCases {
                settings.targetLanguage = language
                XCTAssertTrue(settings.effectivePrompt.contains("Rewrite the user's text in \(language.promptName)."))
                XCTAssertFalse(settings.effectivePrompt.contains("clear English"))
                XCTAssertTrue(settings.effectivePrompt.contains("The input may mix languages"))
                XCTAssertTrue(settings.effectivePrompt.contains("variable placeholders exactly"))
            }
        }
    }

    func testCustomEnglishPromptIsNotOverwritten() throws {
        let custom = AppSettings.legacyEnglishPrompt + "\nKeep my personal style."
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(["prompt": custom]))
        XCTAssertEqual(settings.prompt, custom)
    }

    func testRemovedSelectionOnlyPreferenceIsIgnoredAndNotResaved() throws {
        let legacyData = Data(#"{"onlyReplaceSelection":true,"mode":"manual"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        XCTAssertEqual(settings.mode, .manual)

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["onlyReplaceSelection"])
    }

    func testLegacyScopeKeyIsIgnored() throws {
        for scope in ["selection", "entireInput", "unknown"] {
            let json = Data("{\"scope\":\"\(scope)\",\"prompt\":\"Keep.\"}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: json).prompt, "Keep.")
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self).contains("\"scope\""))
    }

    func testRemovedAutomaticWorkingModeMigratesToManualAndDropsIdleDelay() throws {
        let legacy = Data(#"{"mode":"automatic","idleDelay":4.5}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(settings.mode, .manual)
        XCTAssertEqual(WorkingMode.allCases, [.manual, .silent])

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["mode"] as? String, "manual")
        XCTAssertNil(object["idleDelay"])
    }

    func testLegacySettingsDecodeWithLanguageDefaults() throws {
        let data = Data(#"{"mode":"manual","prompt":"Keep my style.","onboardingCompleted":true}"#.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.mode, .manual)
        XCTAssertEqual(settings.prompt, "Keep my style.")
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(settings.interfaceLanguage, .system)
        XCTAssertEqual(settings.targetLanguage, .english)
        XCTAssertEqual(settings.invokeShortcut, .controlG)
        XCTAssertNil(settings.copyShortcut)
        XCTAssertEqual(settings.replaceShortcut, .controlG)
        XCTAssertFalse(settings.copyPasteCompatibilityEnabled)
    }

    func testLegacyShortcutMigratesToInvokeAndReplace() throws {
        let data = Data(#"{"shortcut":{"keyCode":36,"command":true,"option":false,"control":false,"shift":true}}"#.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        let legacy = Shortcut()
        XCTAssertEqual(settings.invokeShortcut, legacy)
        XCTAssertEqual(settings.replaceShortcut, legacy)
        XCTAssertNil(settings.copyShortcut)
    }

    func testShortcutSettingsRoundTripPreservesUnsetValues() throws {
        var settings = AppSettings()
        settings.invokeShortcut = nil
        settings.copyShortcut = Shortcut(keyCode: 8, command: true, option: false, control: false, shift: false)
        settings.replaceShortcut = nil
        settings.copyPasteCompatibilityEnabled = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertNil(decoded.invokeShortcut)
        XCTAssertEqual(decoded.copyShortcut, settings.copyShortcut)
        XCTAssertNil(decoded.replaceShortcut)
        XCTAssertTrue(decoded.copyPasteCompatibilityEnabled)
    }

    func testActiveGlobalShortcutsFollowWorkingModeWithoutClearingStoredBindings() {
        var settings = AppSettings()
        settings.invokeShortcut = Shortcut(keyCode: 1, control: true)
        settings.copyShortcut = Shortcut(keyCode: 2, control: true)
        settings.replaceShortcut = Shortcut(keyCode: 3, control: true)

        settings.mode = .manual
        XCTAssertEqual(settings.activeGlobalShortcuts, [settings.invokeShortcut, settings.copyShortcut, settings.replaceShortcut].compactMap { $0 })

        settings.mode = .silent
        XCTAssertEqual(settings.activeGlobalShortcuts, [settings.replaceShortcut].compactMap { $0 })
        XCTAssertNotNil(settings.invokeShortcut)
        XCTAssertNotNil(settings.copyShortcut)
        XCTAssertNotNil(settings.replaceShortcut)
    }

    func testEffectivePromptCombinesCustomPromptWithTargetLanguage() {
        var settings = AppSettings()
        settings.prompt = "Keep the writer's tone and punctuation."
        settings.targetLanguage = .japanese

        XCTAssertTrue(settings.effectivePrompt.contains("Keep the writer's tone and punctuation."))
        XCTAssertTrue(settings.effectivePrompt.contains("Write the final result in Japanese."))
        XCTAssertEqual(settings.prompt, "Keep the writer's tone and punctuation.")
    }

    func testPromptTemplateResolvesEveryOccurrenceWhenTargetLanguageChanges() throws {
        var settings = AppSettings()
        let template = settings.prompt
        for language in TargetLanguage.allCases {
            settings.targetLanguage = language
            let effective = settings.effectivePrompt
            XCTAssertTrue(effective.contains("Rewrite the user's text in \(language.promptName)."))
            XCTAssertTrue(effective.contains("parts already in \(language.promptName) for natural wording"))
            XCTAssertTrue(effective.contains("Return only the finished text in \(language.promptName),"))
            XCTAssertFalse(effective.contains("${targetLanguage}"))
            XCTAssertEqual(settings.prompt, template)
        }
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.prompt, template)
        XCTAssertEqual(decoded.effectivePrompt, settings.effectivePrompt)
    }

    func testCustomPromptResolvesOnlyTargetLanguagePlaceholder() throws {
        let template = "  Write in ${targetLanguage}. Keep ${name}, $HOME and ${targetLanguageExtra} literal.  "
        var settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(["prompt": template]))
        settings.targetLanguage = .japanese
        XCTAssertEqual(settings.effectivePrompt, "Write in Japanese. Keep ${name}, $HOME and ${targetLanguageExtra} literal.")
        XCTAssertEqual(settings.prompt, template)
    }

    func testSettingsRoundTripPreservesLanguageAndModelEndpoint() throws {
        var settings = AppSettings()
        settings.interfaceLanguage = .simplifiedChinese
        settings.targetLanguage = .japanese
        settings.llm.baseURL = "https://example.test/v1"
        settings.llm.model = "example-model"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.interfaceLanguage, .simplifiedChinese)
        XCTAssertEqual(decoded.targetLanguage, .japanese)
        XCTAssertEqual(decoded.llm.baseURL, "https://example.test/v1")
        XCTAssertEqual(decoded.llm.model, "example-model")
    }

    func testInputAnimationPreferenceRoundTripsAndPreservesExistingDefault() throws {
        XCTAssertTrue(AppSettings().inputAnimationEnabled)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).inputAnimationEnabled)
        for enabled in [false, true] {
            var settings = AppSettings()
            settings.inputAnimationEnabled = enabled
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.inputAnimationEnabled, enabled)
        }
    }

    func testVersionTwoModelSelectionMigratesToAProfileIdentifier() throws {
        let data = Data(#"{"schemaVersion":2,"llm":{"provider":"deepSeek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat"}}"#.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.activeModelProfileID, ProviderKind.deepSeek.rawValue)
        XCTAssertEqual(settings.llm.provider, .deepSeek)
    }

    func testTargetLanguageNamesFollowInterfaceLanguage() {
        XCTAssertEqual(TargetLanguage.traditionalChinese.displayName(interfaceLanguage: .english), "Traditional Chinese")
        XCTAssertEqual(TargetLanguage.traditionalChinese.displayName(interfaceLanguage: .simplifiedChinese), "繁体中文")
        XCTAssertEqual(TargetLanguage.japanese.displayName(interfaceLanguage: .simplifiedChinese), "日语")
    }

    func testKnownErrorsCanUseSelectedInterfaceLanguage() {
        XCTAssertEqual(SayoError.noSelection.message(language: .english), "Select the text you want to rewrite.")
        XCTAssertEqual(SayoError.noSelection.message(language: .simplifiedChinese), "请选择要改写的文本。")
        XCTAssertEqual(
            SayoError.compatibilitySelectionRequired.message(language: .english),
            "This app cannot replace text directly. Select some text first."
        )
        XCTAssertEqual(
            SayoError.compatibilitySelectionRequired.message(language: .simplifiedChinese),
            "当前应用不支持直接替换，需要先选中内容。"
        )
    }
}
