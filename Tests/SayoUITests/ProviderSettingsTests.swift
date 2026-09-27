import XCTest
import SayoCore
@testable import SayoUI

@MainActor final class ProviderSettingsTests: XCTestCase {
    func testProviderCatalogHasStableOrderWithoutRecommendationGrouping() {
        XCTAssertEqual(ProviderKind.catalog, [
            .deepSeek, .doubao, .gemini, .chromeNano, .internAI, .localModel, .magpie, .moonshot, .openAICompatible,
            .openCode, .openRouter, .qwen, .siliconFlow, .zhipu
        ])
        XCTAssertEqual(ProviderKind.qwen.displayName, "千问AI平台")
        XCTAssertEqual(ProviderKind.qwen.defaultModel, "qwen3-vl-flash")
        XCTAssertEqual(ProviderKind.qwen.defaultBaseURL, "https://maas.qianwenaiapi.com/compatible-mode/v1")
        XCTAssertEqual(ProviderKind.qwen.homepageURL?.absoluteString, "https://www.qianwenai.com/models")
        XCTAssertEqual(ProviderKind.internAI.defaultBaseURL, "https://discovery-api.intern-ai.org.cn/v1")
        XCTAssertEqual(ProviderKind.internAI.homepageURL?.absoluteString, "https://discovery.intern-ai.org.cn/")
        XCTAssertEqual(ProviderKind.localModel.displayName, "Local Model")
        XCTAssertEqual(ProviderKind.localModel.defaultBaseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(ProviderKind.localModel.recommendedModel, "Hy-MT2-1.8B Q4_K_M")
        XCTAssertEqual(
            ProviderKind.localModel.homepageURL?.absoluteString,
            "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF"
        )
        XCTAssertNil(ProviderKind.custom.homepageURL)
        XCTAssertEqual(ProviderKind.magpie.homepageURL?.absoluteString, "https://usemagpie.ai/")
        XCTAssertEqual(ProviderKind.magpie.defaultBaseURL, "http://127.0.0.1:3425/v1")
        XCTAssertEqual(ProviderKind.magpie.defaultAPIKey, "magpie")
        XCTAssertEqual(ProviderKind.magpie.apiFormat(model: "anything"), .chatCompletions)
    }

    func testRetiredAnthropicTemplateCannotCreateProfilesButSavedProfilesRemainEditable() throws {
        var settings = AppSettings()
        var legacy = LLMConfiguration()
        legacy.provider = .anthropic
        legacy.baseURL = ProviderKind.anthropic.defaultBaseURL
        legacy.model = "claude-existing-model"
        settings.providerConfigurations["anthropic2"] = legacy
        let model = AppViewModel(settings: try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)))
        model.loadKeyAction = { $0 == "anthropic2" ? "existing-key" : "" }

        XCTAssertFalse(model.availableModelProfiles.contains { $0.provider == .anthropic })
        XCTAssertNil(model.modelProfileEditor(for: "template:anthropic"))
        model.changeModelProfile("template:anthropic")
        XCTAssertEqual(model.settings.activeModelProfileID, settings.activeModelProfileID)
        XCTAssertNil(model.settings.providerConfigurations["anthropic"])

        XCTAssertEqual(model.configuredModelProfiles.first { $0.provider == .anthropic }?.id, "anthropic2")
        let editor = try XCTUnwrap(model.modelProfileEditor(for: "anthropic2"))
        XCTAssertEqual(editor.draft.settings.llm, legacy)
        XCTAssertEqual(editor.draft.apiKey, "existing-key")
        XCTAssertEqual(editor.draft.settings.llm.resolvedAPIFormat, .anthropic)
    }

    func testMagpieTemplateDefaultsAndAPIFormatOverrideSurviveReload() throws {
        let model = AppViewModel(settings: .init())
        let session = try XCTUnwrap(model.modelProfileEditor(for: "template:magpie"))
        XCTAssertEqual(session.draft.settings.llm.baseURL, "http://127.0.0.1:3425/v1")
        XCTAssertEqual(session.draft.apiKey, "magpie")
        XCTAssertEqual(session.draft.settings.llm.resolvedAPIFormat, .chatCompletions)

        session.draft.settings.llm.model = "test-model"
        session.draft.settings.llm.apiFormat = .responses
        model.saveAction = { _, _ in }
        XCTAssertTrue(session.save())
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(model.settings))
        XCTAssertEqual(reloaded.llm.resolvedAPIFormat, .responses)
        XCTAssertEqual(reloaded.providerConfigurations[reloaded.activeModelProfileID]?.apiFormat, .responses)
    }

    func testChromeNanoProfileSavesWithoutEndpointOrKeyAndSurvivesReload() throws {
        let model = AppViewModel(settings: .init())
        var saved: AppSettings?
        model.saveAction = { settings, key in saved = settings; XCTAssertTrue(key.isEmpty) }
        let session = try XCTUnwrap(model.modelProfileEditor(for: "template:chromeNano"))
        XCTAssertEqual(session.draft.settings.llm.model, "gemini-nano")
        XCTAssertTrue(session.save())
        let settings = try XCTUnwrap(saved)
        XCTAssertEqual(settings.llm.provider, .chromeNano)
        XCTAssertEqual(settings.llm.baseURL, "")
        let reloaded = AppViewModel(settings: try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)))
        XCTAssertTrue(reloaded.configuredModelProfiles.contains { $0.provider == .chromeNano })
        XCTAssertEqual(reloaded.configuredModelProfiles.first { $0.provider == .chromeNano }?.displayName(language: .simplifiedChinese), "Gemini Nano · Chrome 本地")
    }

    func testLocalModelUsesLocalizedNameAndLoopbackDefaultOnFirstSelection() {
        let model = AppViewModel(settings: .init())
        let profile = try! XCTUnwrap(
            model.availableModelProfiles.first { $0.provider == .localModel }
        )

        XCTAssertEqual(profile.displayName(language: .english), "Local Model")
        XCTAssertEqual(profile.displayName(language: .simplifiedChinese), "本地模型")

        model.changeProvider(.localModel)

        XCTAssertEqual(model.settings.llm.baseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(model.settings.llm.model, "")
    }

    func testQwenUsesProviderDefaultsOnFirstSelection() {
        let model = AppViewModel(settings: .init())

        model.changeProvider(.qwen)

        XCTAssertEqual(model.settings.llm.baseURL, "https://maas.qianwenaiapi.com/compatible-mode/v1")
        XCTAssertEqual(model.settings.llm.model, "qwen3-vl-flash")
    }

    func testSwitchingPlatformDoesNotReuseAnotherPlatformsCredentialsOrEndpoint() {
        var settings = AppSettings()
        settings.llm.baseURL = "http://localhost:8317/v1"; settings.llm.model = "local-model"
        let model = AppViewModel(settings: settings); model.apiKey = "local-secret"
        model.loadKeyAction = { $0 == ProviderKind.deepSeek.rawValue ? "deepseek-secret" : "" }
        model.changeProvider(.deepSeek)
        XCTAssertEqual(model.settings.llm.baseURL, ProviderKind.deepSeek.defaultBaseURL)
        XCTAssertEqual(model.settings.llm.model, "")
        XCTAssertEqual(model.apiKey, "deepseek-secret")
        model.settings.llm.model = "deepseek-v4-flash"
        model.changeProvider(.openRouter)
        XCTAssertEqual(model.apiKey, "")
        XCTAssertEqual(model.settings.llm.baseURL, ProviderKind.openRouter.defaultBaseURL)
        model.changeProvider(.openAICompatible)
        XCTAssertEqual(model.settings.llm.baseURL, "http://localhost:8317/v1")
        XCTAssertEqual(model.settings.llm.model, "local-model")
        XCTAssertEqual(model.apiKey, "local-secret")
        model.changeProvider(.deepSeek)
        XCTAssertEqual(model.settings.llm.model, "deepseek-v4-flash")
        XCTAssertEqual(model.apiKey, "deepseek-secret")
    }

    func testSavedProviderPreferencesSurviveRestartWithoutSerializingKeys() throws {
        let model = AppViewModel(settings: .init())
        model.settings.llm.baseURL = "http://localhost:8317/v1"
        model.settings.llm.model = "local-model"
        model.apiKey = "local-secret"
        model.changeProvider(.deepSeek)
        model.settings.llm.model = "remote-model"
        model.apiKey = "remote-secret"
        var data = Data()
        model.saveAction = { settings, _ in data = try JSONEncoder().encode(settings) }
        XCTAssertTrue(model.save())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("local-secret"))
        XCTAssertFalse(text.contains("remote-secret"))
        let restarted = AppViewModel(settings: try JSONDecoder().decode(AppSettings.self, from: data))
        restarted.loadKeyAction = { $0 == ProviderKind.openAICompatible.rawValue ? "keychain-local" : "keychain-remote" }
        restarted.apiKey = "keychain-remote"
        restarted.changeProvider(.openAICompatible)
        XCTAssertEqual(restarted.settings.llm.baseURL, "http://localhost:8317/v1")
        XCTAssertEqual(restarted.settings.llm.model, "local-model")
        XCTAssertEqual(restarted.apiKey, "keychain-local")
        restarted.changeProvider(.deepSeek)
        XCTAssertEqual(restarted.settings.llm.model, "remote-model")
        XCTAssertEqual(restarted.apiKey, "keychain-remote")
    }

    func testInternAIAndCustomKeepIndependentEndpointsAndCredentials() {
        let model = AppViewModel(settings: .init())
        model.loadKeyAction = { $0 == ProviderKind.internAI.rawValue ? "intern-secret" : "" }

        model.changeProvider(.internAI)
        XCTAssertEqual(model.settings.llm.baseURL, "https://discovery-api.intern-ai.org.cn/v1")
        XCTAssertEqual(model.apiKey, "intern-secret")
        model.settings.llm.model = "intern-model"

        model.changeProvider(.custom)
        XCTAssertEqual(model.settings.llm.baseURL, ProviderKind.custom.defaultBaseURL)
        XCTAssertEqual(model.apiKey, "")
        model.settings.llm.baseURL = "http://localhost:9000/v1"

        model.changeProvider(.internAI)
        XCTAssertEqual(model.settings.llm.model, "intern-model")
        XCTAssertEqual(model.apiKey, "intern-secret")
        model.changeProvider(.custom)
        XCTAssertEqual(model.settings.llm.baseURL, "http://localhost:9000/v1")
    }

    func testConfiguredProfilesArePromotedAndIncludeTheirModelNames() {
        var settings = AppSettings()
        settings.llm.provider = .deepSeek
        settings.llm.baseURL = ProviderKind.deepSeek.defaultBaseURL
        settings.llm.model = "deepseek-chat"
        settings.activeModelProfileID = ProviderKind.deepSeek.rawValue

        let model = AppViewModel(settings: settings)

        XCTAssertEqual(model.configuredModelProfiles.map(\.id), [ProviderKind.deepSeek.rawValue])
        XCTAssertEqual(model.configuredModelProfiles.first?.model, "deepseek-chat")
        XCTAssertTrue(model.availableModelProfiles.map(\.id).contains("template:deepSeek"))
        XCTAssertEqual(model.availableModelProfiles.last?.id, "template:custom")
    }

    func testConfiguredCustomProfileCreatesNumberedEmptyProfileBelowItAfterRestart() throws {
        var settings = AppSettings()
        settings.llm.provider = .custom
        settings.llm.baseURL = "http://127.0.0.1:8080/v1"
        settings.llm.model = "hy-mt2"
        settings.activeModelProfileID = ProviderKind.custom.rawValue
        settings.providerConfigurations[ProviderKind.custom.rawValue] = settings.llm
        let restartedSettings = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        let model = AppViewModel(settings: restartedSettings)

        XCTAssertEqual(model.configuredModelProfiles.last?.id, "custom")
        XCTAssertEqual(
            model.configuredModelProfiles.last?.displayName(language: .simplifiedChinese),
            "自定义模型"
        )
        XCTAssertEqual(model.availableModelProfiles.last?.id, "template:custom")
        XCTAssertEqual(
            model.availableModelProfiles.last?.displayName(language: .simplifiedChinese),
            "自定义模型"
        )

        model.changeModelProfile("template:custom")
        XCTAssertEqual(model.settings.activeModelProfileID, "custom2")
        XCTAssertEqual(model.settings.llm.provider, .custom)
        XCTAssertEqual(model.settings.llm.baseURL, "")
        XCTAssertEqual(model.settings.llm.model, "")
    }

    func testConfiguredProviderRemainsAnAddTemplateAndCreatesIndependentProfile() throws {
        let model = AppViewModel(settings: .init())
        model.changeModelProfile("template:qwen")
        model.apiKey = "first-secret"
        model.settings.llm.model = "first-model"

        XCTAssertEqual(model.settings.activeModelProfileID, "qwen")
        XCTAssertTrue(model.availableModelProfiles.contains { $0.id == "template:qwen" })

        model.changeModelProfile("template:qwen")
        XCTAssertEqual(model.settings.activeModelProfileID, "qwen2")
        XCTAssertEqual(model.apiKey, "")
        XCTAssertEqual(model.settings.llm.model, ProviderKind.qwen.defaultModel)
        XCTAssertEqual(model.configuredModelProfiles.filter { $0.provider == .qwen }.map(\.id), ["qwen", "qwen2"])
        XCTAssertEqual(model.configuredModelProfiles.last?.displayName(language: .simplifiedChinese), "千问AI平台 2")

        model.changeModelProfile("qwen")
        XCTAssertEqual(model.settings.llm.model, "first-model")
        XCTAssertEqual(model.apiKey, "first-secret")
        let restored = AppViewModel(settings: try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(model.settings)))
        XCTAssertEqual(restored.configuredModelProfiles.filter { $0.provider == .qwen }.map(\.id), ["qwen", "qwen2"])
        XCTAssertTrue(restored.availableModelProfiles.contains { $0.id == "template:qwen" })
    }

    func testDeletingConfiguredProfileRemovesCredentialAndSelectsSurvivor() {
        let model = AppViewModel(settings: .init())
        var deletedKeys: [String] = []
        model.deleteKeyAction = { deletedKeys.append($0) }
        model.changeModelProfile("template:qwen")
        model.apiKey = "first-secret"
        model.changeModelProfile("template:qwen")
        model.apiKey = "second-secret"

        XCTAssertTrue(model.deleteModelProfile("qwen2"))
        XCTAssertEqual(deletedKeys, ["qwen2"])
        XCTAssertEqual(model.settings.activeModelProfileID, "qwen")
        XCTAssertEqual(model.apiKey, "first-secret")
        XCTAssertNil(model.settings.providerConfigurations["qwen2"])
        XCTAssertEqual(model.configuredModelProfiles.filter { $0.provider == .qwen }.map(\.id), ["qwen"])
        XCTAssertTrue(model.availableModelProfiles.contains { $0.id == "template:qwen" })
    }

    func testDeletionFailurePreservesProfile() {
        let model = AppViewModel(settings: .init())
        model.changeModelProfile("template:qwen")
        model.deleteKeyAction = { _ in throw SayoError.network("Keychain unavailable") }

        XCTAssertFalse(model.deleteModelProfile("qwen"))
        XCTAssertEqual(model.settings.activeModelProfileID, "qwen")
        XCTAssertEqual(model.configuredModelProfiles.map(\.id), ["qwen"])
        XCTAssertTrue(model.noticeIsError)
    }

    func testDeletingLastConfiguredProfileReturnsToEmptyDraft() {
        let model = AppViewModel(settings: .init())
        model.changeModelProfile("template:qwen")

        XCTAssertTrue(model.deleteModelProfile("qwen"))
        XCTAssertEqual(model.settings.activeModelProfileID, ProviderKind.openAICompatible.rawValue)
        XCTAssertEqual(model.settings.llm.model, "")
        XCTAssertTrue(model.configuredModelProfiles.isEmpty)
        XCTAssertTrue(model.availableModelProfiles.contains { $0.id == "template:qwen" })
    }

    func testSwitchingAfterEnteringAKeySavesThePreviousProfilesCredential() {
        let model = AppViewModel(settings: .init())
        var savedKeys: [(String, String)] = []
        model.saveAction = { settings, key in savedKeys.append((settings.activeModelProfileID, key)) }
        model.changeModelProfile("template:qwen")
        model.apiKey = "first-secret"
        model.changeModelProfile("template:qwen")

        XCTAssertTrue(savedKeys.contains { $0.0 == "qwen" && $0.1 == "first-secret" })
        XCTAssertEqual(model.settings.activeModelProfileID, "qwen2")
    }

    func testNewModelEditorKeepsDraftOutOfSettingsUntilExplicitSave() throws {
        let model = AppViewModel(settings: .init())
        var savedProfileIDs: [String] = []
        model.saveAction = { settings, _ in savedProfileIDs.append(settings.activeModelProfileID) }
        let original = model.settings
        let session = try XCTUnwrap(model.modelProfileEditor(for: "template:deepSeek"))

        XCTAssertTrue(session.isNew)
        XCTAssertFalse(session.hasUnsavedChanges)
        session.draft.settings.llm.model = "deepseek-chat"
        session.draft.apiKey = "draft-secret"
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(model.settings, original)
        XCTAssertEqual(model.apiKey, "")
        XCTAssertTrue(savedProfileIDs.isEmpty)

        XCTAssertTrue(session.save())
        XCTAssertEqual(model.settings.activeModelProfileID, "deepSeek")
        XCTAssertEqual(model.settings.llm.model, "deepseek-chat")
        XCTAssertEqual(model.apiKey, "draft-secret")
        XCTAssertEqual(savedProfileIDs, ["deepSeek"])
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testEditingModelCanBeDiscardedWithoutChangingSavedProfile() throws {
        var settings = AppSettings()
        settings.llm.provider = .deepSeek
        settings.llm.baseURL = ProviderKind.deepSeek.defaultBaseURL
        settings.llm.model = "old-model"
        settings.activeModelProfileID = "deepSeek"
        let model = AppViewModel(settings: settings)
        model.apiKey = "old-key"
        let session = try XCTUnwrap(model.modelProfileEditor(for: "deepSeek"))

        XCTAssertFalse(session.isNew)
        XCTAssertFalse(session.hasUnsavedChanges)
        session.draft.settings.llm.model = "new-model"
        session.draft.apiKey = "new-key"
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(model.settings.llm.model, "old-model")
        XCTAssertEqual(model.apiKey, "old-key")
        session.draft.settings.llm.model = "old-model"
        session.draft.apiKey = "old-key"
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testModelEditorRejectsIncompleteProfileAndPreservesDraftOnSaveFailure() throws {
        let model = AppViewModel(settings: .init())
        let session = try XCTUnwrap(model.modelProfileEditor(for: "template:custom"))
        XCTAssertFalse(session.save())
        XCTAssertFalse(session.errorMessage.isEmpty)
        XCTAssertTrue(model.configuredModelProfiles.isEmpty)

        session.draft.settings.llm.baseURL = "http://localhost:8080/v1"
        session.draft.settings.llm.model = "local-model"
        model.saveAction = { _, _ in throw SayoError.network("Cannot save") }
        XCTAssertFalse(session.save())
        XCTAssertEqual(model.settings.activeModelProfileID, "openAICompatible")
        XCTAssertNil(model.settings.providerConfigurations["custom"])
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    func testPreviouslySavedIncompleteProfileRemainsVisibleAfterSwitch() {
        var settings = AppSettings()
        var custom = LLMConfiguration()
        custom.provider = .custom
        custom.baseURL = "http://localhost:8080/v1"
        settings.providerConfigurations["custom"] = custom
        let model = AppViewModel(settings: settings)

        XCTAssertTrue(model.pendingModelProfiles.contains { $0.id == "custom" })
        model.changeModelProfile("custom")
        model.changeModelProfile("openAICompatible")
        XCTAssertTrue(model.pendingModelProfiles.contains { $0.id == "custom" })
    }

    func testManualModelNameRemainsUsableWhenModelCatalogFails() async {
        let model = AppViewModel(settings: .init())
        model.settings.llm.model = "custom-model"
        model.fetchModelsAction = { _, _ in throw SayoError.network("Catalog unavailable") }
        model.refreshModels()
        for _ in 0..<100 where model.loadingModels { await Task.yield() }
        XCTAssertFalse(model.loadingModels)
        XCTAssertEqual(model.settings.llm.model, "custom-model")
        XCTAssertEqual(model.modelListResult, "Catalog unavailable")
    }

    func testConnectionResultIncludesMeasuredLatencyAndConfigurationChangesClearIt() async {
        let model = AppViewModel(settings: .init())
        var instants: [UInt64] = [1_000_000_000, 1_345_999_999]
        model.connectionNowAction = { instants.removeFirst() }
        model.settings.interfaceLanguage = .english
        model.testConnectionAction = { _, _, _ in "This weekend, I want to stroll along the beach with friends, chat at a leisurely pace, and take a few photos." }

        model.testConnection()
        for _ in 0..<100 where model.testingConnection { await Task.yield() }

        XCTAssertFalse(model.testingConnection)
        XCTAssertTrue(model.connectionSucceeded)
        XCTAssertEqual(model.connectionResult, "Connected")
        XCTAssertEqual(model.connectionOriginal, "This weekend 想和朋友去海边散步，ゆっくり聊聊天，사진도拍几张。")
        XCTAssertEqual(model.connectionOutput, "This weekend, I want to stroll along the beach with friends, chat at a leisurely pace, and take a few photos.")
        XCTAssertEqual(model.connectionLatencyMilliseconds, 345)

        model.connectionConfigurationChanged()
        XCTAssertNil(model.connectionLatencyMilliseconds)
        XCTAssertTrue(model.connectionOriginal.isEmpty)
        XCTAssertTrue(model.connectionOutput.isEmpty)
    }

    func testEveryProviderReceivesTheSameTestSentenceAndConfiguredPromptAndTarget() async {
        for kind in ProviderKind.allCases {
            var settings = AppSettings()
            settings.llm.provider = kind
            settings.targetLanguage = .japanese
            let model = AppViewModel(settings: settings)
            model.apiKey = "test-key"
            var called = false
            model.testConnectionAction = { configuration, key, request in
                called = true
                XCTAssertEqual(configuration.provider, kind)
                XCTAssertEqual(key, "test-key")
                XCTAssertEqual(request.text, "This weekend 想和朋友去海边散步，ゆっくり聊聊天，사진도拍几张。")
                XCTAssertEqual(request.text, model.connectionOriginal)
                XCTAssertEqual(request.prompt, settings.effectivePrompt)
                XCTAssertEqual(request.targetLanguage, .japanese)
                return "今週末は友達と海辺を散歩して、ゆっくりおしゃべりをし、写真も何枚か撮りたいです。"
            }
            model.testConnection()
            for _ in 0..<100 where model.testingConnection { await Task.yield() }
            XCTAssertTrue(called, kind.rawValue)
            XCTAssertTrue(model.connectionSucceeded, kind.rawValue)
            XCTAssertEqual(model.connectionOutput, "今週末は友達と海辺を散歩して、ゆっくりおしゃべりをし、写真も何枚か撮りたいです。")
        }
    }

    func testFailedConnectionKeepsOriginalAndNeverShowsPreviousOutput() async {
        let model = AppViewModel(settings: .init())
        var instants: [UInt64] = [1_000_000_000, 1_250_000_000, 2_000_000_000, 2_750_000_000]
        model.connectionNowAction = { instants.removeFirst() }
        model.testConnectionAction = { _, _, _ in "Previous result" }
        model.testConnection()
        for _ in 0..<100 where model.testingConnection { await Task.yield() }
        model.testConnectionAction = { _, _, _ in throw SayoError.network("Unsupported input language") }
        model.testConnection()
        XCTAssertEqual(model.connectionOriginal, "This weekend 想和朋友去海边散步，ゆっくり聊聊天，사진도拍几张。")
        XCTAssertTrue(model.connectionOutput.isEmpty)
        for _ in 0..<100 where model.testingConnection { await Task.yield() }
        XCTAssertFalse(model.connectionSucceeded)
        XCTAssertEqual(model.connectionOriginal, "This weekend 想和朋友去海边散步，ゆっくり聊聊天，사진도拍几张。")
        XCTAssertTrue(model.connectionOutput.isEmpty)
        XCTAssertEqual(model.connectionResult, "Unsupported input language")
        XCTAssertEqual(model.connectionLatencyMilliseconds, 750)
    }

    func testChangingSelectedModelDiscardsInFlightResultAndTiming() async throws {
        let model = AppViewModel(settings: .init())
        var oldResponse: CheckedContinuation<String, Never>?
        model.testConnectionAction = { configuration, _, _ in
            if configuration.provider == .chromeNano { return "Current model result" }
            return await withCheckedContinuation { oldResponse = $0 }
        }
        model.testConnection()
        for _ in 0..<100 where oldResponse == nil { await Task.yield() }
        let response = try XCTUnwrap(oldResponse)

        model.changeProvider(.chromeNano)
        XCTAssertFalse(model.testingConnection)
        XCTAssertTrue(model.connectionOutput.isEmpty)
        XCTAssertNil(model.connectionLatencyMilliseconds)
        model.testConnection()
        for _ in 0..<100 where model.testingConnection { await Task.yield() }
        XCTAssertEqual(model.connectionOutput, "Current model result")
        let currentTiming = model.connectionLatencyMilliseconds

        response.resume(returning: "Old model result")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.connectionOutput, "Current model result")
        XCTAssertEqual(model.connectionLatencyMilliseconds, currentTiming)
    }

    func testChromeConnectionUsesTheEditorInterfaceLanguage() async throws {
        let parent = AppViewModel(settings: .init())
        parent.settings.interfaceLanguage = .simplifiedChinese
        var received: InterfaceLanguage?
        var connected = false
        parent.nanoIsConnectedAction = { connected }
        parent.connectNanoAction = { received = $0; connected = true }
        let session = try XCTUnwrap(parent.modelProfileEditor(for: "template:chromeNano"))
        session.draft.connectNano()
        for _ in 0..<100 where session.draft.connectingNano { await Task.yield() }
        XCTAssertEqual(received, .simplifiedChinese)
        XCTAssertTrue(session.draft.nanoConnected)
        connected = false
        session.draft.refreshNanoConnection()
        XCTAssertFalse(session.draft.nanoConnected)
    }

    func testOpeningChromeFailureKeepsStatusDisconnectedAndReportsTheActionError() async {
        let model = AppViewModel(settings: .init())
        model.nanoIsConnectedAction = { false }
        model.connectNanoAction = { _ in throw SayoError.network("Could not open Chrome") }
        model.connectionResult = "Previous failure"
        model.connectionLatencyMilliseconds = 50
        model.connectNano()
        XCTAssertTrue(model.connectionResult.isEmpty)
        XCTAssertNil(model.connectionLatencyMilliseconds)
        for _ in 0..<100 where model.connectingNano { await Task.yield() }
        XCTAssertFalse(model.connectingNano)
        XCTAssertFalse(model.nanoConnected)
        XCTAssertEqual(model.nanoConnectionError, "Could not open Chrome")

        model.connectNanoAction = { _ in }
        model.connectNano()
        XCTAssertTrue(model.nanoConnectionError.isEmpty)
        for _ in 0..<100 where model.connectingNano { await Task.yield() }
        XCTAssertFalse(model.nanoConnected)
    }

    func testChangingActiveModelUpdatesTheCurrentProfileAndClearsConnectionResult() {
        let model = AppViewModel(settings: .init())
        model.changeModelProfile("template:qwen")
        model.settings.llm.model = "first-model"
        model.connectionResult = "Connected"
        model.connectionSucceeded = true
        model.connectionLatencyMilliseconds = 120

        model.changeActiveModel("qwen3-vl-flash")

        XCTAssertEqual(model.settings.llm.model, "qwen3-vl-flash")
        XCTAssertEqual(model.settings.providerConfigurations["qwen"]?.model, "qwen3-vl-flash")
        XCTAssertTrue(model.connectionResult.isEmpty)
        XCTAssertFalse(model.connectionSucceeded)
        XCTAssertNil(model.connectionLatencyMilliseconds)
    }

    func testChangingActiveModelIsIgnoredForChromeNanoAndBlankNames() {
        let model = AppViewModel(settings: .init())
        model.changeModelProfile("template:chromeNano")
        model.changeActiveModel("other-model")
        XCTAssertEqual(model.settings.llm.model, "gemini-nano")

        model.changeModelProfile("template:qwen")
        model.settings.llm.model = "qwen3-vl-flash"
        model.changeActiveModel("   ")
        model.changeActiveModel("qwen3-vl-flash")
        XCTAssertEqual(model.settings.llm.model, "qwen3-vl-flash")
    }
}
