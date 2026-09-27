import SwiftUI
import AppKit
import Dispatch
import SayoCore
import SayoApplication

public enum SettingsSaveState: Equatable {
    case saving
    case saved
    case failed
}

public struct ModelProfileOption: Identifiable, Equatable {
    public let id: String
    public let provider: ProviderKind
    public let model: String
    public let customIndex: Int?
    public let instanceIndex: Int

    public func displayName(language: InterfaceLanguage) -> String {
        if provider == .chromeNano {
            return language.text("Gemini Nano · Chrome local", "Gemini Nano · Chrome 本地")
        }
        if provider == .localModel {
            let name = language.text("Local Model", "本地模型")
            return instanceIndex > 1 ? "\(name) \(instanceIndex)" : name
        }
        guard provider == .custom else {
            return instanceIndex > 1 ? "\(provider.displayName) \(instanceIndex)" : provider.displayName
        }
        let base = language.text("Custom Model", "自定义模型")
        guard let customIndex, customIndex > 1 else { return base }
        return "\(base) \(customIndex)"
    }
}

@MainActor public final class AppViewModel: ObservableObject {
    public var features: Set<AppFeature> { AppFeature.shipped }
    public var supportsFocusedInput: Bool { features.contains(.focusedInput) }
    public var supportsTerminal: Bool { features.contains(.terminalIntegration) }
    @Published public var updateState: AppUpdateState = .notConfigured
    public var checkForUpdatesAction: (() -> Void)?
    public var dismissUpdatePromptAction: (() -> Void)?
    public var updatePreferencesAction: ((Bool, Bool) -> Void)?
    public var canRequestUpdateCheck: Bool {
        switch updateState {
        case .notConfigured, .checking, .downloading, .preparing, .installing: return false
        default: return true
        }
    }

    public func checkForUpdates() {
        guard canRequestUpdateCheck else { return }
        checkForUpdatesAction?()
    }

    @Published public var settings: AppSettings {
        didSet {
            if oldValue.automaticallyChecksForUpdates != settings.automaticallyChecksForUpdates ||
                oldValue.automaticallyDownloadsUpdates != settings.automaticallyDownloadsUpdates {
                updatePreferencesAction?(settings.automaticallyChecksForUpdates, settings.automaticallyDownloadsUpdates)
            }
        }
    }
    @Published public var apiKey = ""
    @Published public var accessibilityGranted = false
    @Published public var cliShortcutDrafts = Dictionary(uniqueKeysWithValues: CLIEditorProgram.allCases.map { ($0.rawValue, CLIShortcut.defaultKey) })
    public var loadCLIShortcutAction: ((String) throws -> String)?
    public var configureCLIShortcutAction: ((String, String?) throws -> Void)?

    public func loadCLIShortcutSettings() {
        guard supportsTerminal else { return }
        for program in CLIEditorProgram.allCases.map(\.rawValue) {
            do {
                guard let value = try loadCLIShortcutAction?(program) else { continue }
                cliShortcutDrafts[program] = value
            } catch { notice = error.localizedDescription; noticeIsError = true }
        }
    }
    public func setCLIShortcut(_ program: String, key: String?) {
        guard supportsTerminal else { return }
        do {
            guard let action = configureCLIShortcutAction else { throw SayoError.terminalUnavailable }
            try action(program, key)
            cliShortcutDrafts[program] = key ?? ""
            if let value = try loadCLIShortcutAction?(program) { cliShortcutDrafts[program] = value }
            notice = text("CLI shortcut saved; restart the CLI and open a new terminal tab for Codex.", "CLI 快捷键已保存；请重启 CLI，Codex 还需打开新终端标签页。")
            noticeIsError = false
        } catch { notice = error.localizedDescription; noticeIsError = true }
    }
    @Published public var terminalInstalled: [String: Bool] = [:]
    @Published public var cliEditorInstalled: [String: Bool] = [:]
    public var loadCLIEditorsAction: (() throws -> [String: Bool])?
    public var installCLIEditorAction: ((String) throws -> Void)?
    public var resetCLIEditorAction: ((String) throws -> Void)?
    @Published public var notice = ""
    @Published public var noticeIsError = false
    @Published public var testingConnection = false
    @Published public var connectionResult = ""
    @Published public var connectionOriginal = ""
    @Published public var connectionOutput = ""
    public static let connectionTestText = "This weekend 想和朋友去海边散步，ゆっくり聊聊天，사진도拍几张。"
    @Published public var connectionSucceeded = false
    @Published public var connectionLatencyMilliseconds: UInt64?
    @Published public var availableModels: [String] = []
    @Published public var loadingModels = false
    @Published public var modelListResult = ""
    @Published public var modelListSucceeded = false
    @Published public var onboardingStep = 0
    @Published public var diagnosticText = ""
    @Published public var diagnosticAnalysis = DiagnosticAnalysis()
    @Published public var diagnosticStatus = ""
    @Published public var diagnosticPath = ""
    @Published public var diagnosticTextSnippetsEnabled = false
    @Published public var aiDiagnosticResult = ""
    @Published public var aiDiagnosticEvidence = ""
    @Published public var aiDiagnosticStatus = ""
    @Published public var aiDiagnosticRunning = false
    @Published public var aiDiagnosticFailureCount = 0
    @Published public private(set) var aiDiagnosticCandidates: AIDiagnosticEvidence?
    @Published public private(set) var aiDiagnosticSelectedCases: Set<Int> = []
    @Published public private(set) var settingsSaveState: SettingsSaveState = .saved
    public var refreshDiagnosticsAction: (() throws -> String)?
    public var openDiagnosticsAction: (() throws -> Void)?
    public var exportDiagnosticsAction: (() -> Void)?
    public var exportDiagnosticGroupAction: ((DiagnosticGroup) -> Void)?
    public var diagnosticSnippetsAction: ((Bool) -> Void)?
    public var runAIDiagnosticsAction: ((String) async throws -> String)?
    public var saveAIDiagnosticReportAction: ((String, String) -> Void)?
    public var openAIDiagnosticIssueAction: ((URL) -> Bool)?
    public var saveAction: ((AppSettings, String) throws -> Void)?
    public var configPath = ""
    public var openConfigAction: (() -> Void)?
    public var loadKeyAction: ((String) -> String)?
    public var deleteKeyAction: ((String) throws -> Void)?
    public var openModelEditorAction: ((String) -> Void)?
    public var testConnectionAction: ((LLMConfiguration, String, RewriteRequest) async throws -> String)?
    public var fetchModelsAction: ((LLMConfiguration, String) async throws -> [String])?
    public var nanoIsConnectedAction: (() -> Bool)?
    public var connectNanoAction: ((InterfaceLanguage) async throws -> Void)?
    @Published public var nanoConnected = false
    @Published public var nanoConnectionError = ""
    @Published public var connectingNano = false

    public func refreshNanoConnection() {
        let connected = nanoIsConnectedAction?() ?? false
        if nanoConnected != connected { nanoConnected = connected }
    }
    public func connectNano() {
        guard !connectingNano else { return }
        connectionConfigurationChanged()
        connectingNano = true
        nanoConnectionError = ""
        Task {
            defer { connectingNano = false; refreshNanoConnection() }
            do {
                guard let connectNanoAction else { throw SayoError.missingConfiguration }
                try await connectNanoAction(settings.interfaceLanguage)
            } catch { nanoConnectionError = error.localizedDescription }
        }
    }
    public var permissionAction: (() -> Void)?
    public var refreshAction: (() -> Void)?
    public var terminalInstallAction: ((String) throws -> String)?
    public var terminalUninstallAction: ((String) throws -> String)?
    public var finishOnboardingAction: (() -> Void)?
    public var showOnboardingAction: (() -> Void)?
    public var workingModeChangeAction: ((AppSettings) -> Void)?
    var connectionNowAction: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    private var connectionGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var modelListGeneration = 0
    private var modelListTask: Task<Void, Never>?
    private var aiDiagnosticGeneration = 0
    private var aiDiagnosticTask: Task<Void, Never>?
    private var providerDrafts: [String: ProviderDraft] = [:]
    private var autoSaveTask: Task<Void, Never>?
    private var lastSaveError: String?
    var autoSaveDelayNanoseconds: UInt64 = 450_000_000

    public init(settings: AppSettings) {
        self.settings = settings
        providerDrafts[settings.activeModelProfileID] = ProviderDraft(configuration: settings.llm, apiKey: "")
    }
    public func text(_ english: String, _ simplifiedChinese: String) -> String {
        settings.interfaceLanguage.text(english, simplifiedChinese)
    }
    public func targetLanguageName(_ language: TargetLanguage) -> String {
        language.displayName(interfaceLanguage: settings.interfaceLanguage)
    }
    public var configuredModelProfiles: [ModelProfileOption] {
        // Retired templates can still have saved profiles and Keychain credentials.
        (ProviderKind.catalog + [.anthropic]).flatMap { kind in
            configurationsByProfileID.keys
                .filter { providerKind(for: $0) == kind && isConfigured(profileID: $0) }
                .sorted { profileIndex(for: $0, provider: kind) < profileIndex(for: $1, provider: kind) }
                .map { profileOption(id: $0, provider: kind) }
        } + configuredCustomProfileIDs.map { profileOption(id: $0, provider: .custom) }
    }
    public var pendingModelProfiles: [ModelProfileOption] {
        let allKinds = ProviderKind.catalog + [.anthropic, .custom]
        return allKinds.flatMap { kind in
            configurationsByProfileID.keys
                .filter { providerKind(for: $0) == kind && !isConfigured(profileID: $0) }
                .sorted { profileIndex(for: $0, provider: kind) < profileIndex(for: $1, provider: kind) }
                .map { profileOption(id: $0, provider: kind) }
        }
    }
    public var availableModelProfiles: [ModelProfileOption] {
        (ProviderKind.catalog + [.custom]).map { kind in
            ModelProfileOption(id: "template:\(kind.rawValue)", provider: kind,
                               model: kind.defaultModel, customIndex: kind == .custom ? 1 : nil,
                               instanceIndex: 1)
        }
    }
    public func changeWorkingMode(_ mode: WorkingMode) {
        guard supportsFocusedInput, settings.mode != mode else { return }
        settings.mode = mode
        workingModeChangeAction?(settings)
    }
    @discardableResult public func refreshDiagnostics() -> Bool {
        do {
            let updated = try refreshDiagnosticsAction?() ?? ""
            if diagnosticText != updated {
                diagnosticText = updated
                diagnosticAnalysis = DiagnosticAnalysis(jsonLines: updated)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "HH:mm:ss ZZZZZ"
            let time = formatter.string(from: Date())
            diagnosticStatus = text("Refreshed \(time) · Newest first · Local time", "已刷新 \(time) · 最新在上 · 本地时间")
            return true
        } catch {
            diagnosticStatus = text("Refresh failed; showing the previous snapshot: \(error.localizedDescription)",
                "刷新失败，当前仍为上次内容：\(error.localizedDescription)")
            return false
        }
    }
    public func openDiagnostics() {
        do { try openDiagnosticsAction?() }
        catch { notice = error.localizedDescription; noticeIsError = true }
    }
    public func prepareAIDiagnostics(now: Date = Date()) {
        guard !aiDiagnosticRunning else { return }
        aiDiagnosticCandidates = nil; aiDiagnosticSelectedCases = []
        aiDiagnosticResult = ""; aiDiagnosticEvidence = ""; aiDiagnosticFailureCount = 0
        guard refreshDiagnostics() else {
            aiDiagnosticStatus = diagnosticStatus
            return
        }
        let evidence = AIDiagnosticEvidence(jsonLines: diagnosticText, now: now)
        aiDiagnosticCandidates = evidence
        aiDiagnosticSelectedCases = Set(evidence.failures.indices)
        aiDiagnosticStatus = evidence.isEmpty
            ? text("No failed cases were found in the past 30 minutes.", "过去 30 分钟内没有找到失败案例。")
            : text("Found \(evidence.failures.count) failed case(s). Select the cases to analyze.",
                   "找到 \(evidence.failures.count) 个失败案例，请选择需要分析的案例。")
    }

    public func selectAIDiagnosticCase(_ index: Int, selected: Bool) {
        guard !aiDiagnosticRunning, aiDiagnosticCandidates?.failures.indices.contains(index) == true else { return }
        if selected { aiDiagnosticSelectedCases.insert(index) }
        else { aiDiagnosticSelectedCases.remove(index) }
    }

    public func selectAllAIDiagnosticCases() {
        guard !aiDiagnosticRunning, let candidates = aiDiagnosticCandidates else { return }
        aiDiagnosticSelectedCases = Set(candidates.failures.indices)
    }

    public func invertAIDiagnosticSelection() {
        guard !aiDiagnosticRunning, let candidates = aiDiagnosticCandidates else { return }
        aiDiagnosticSelectedCases = Set(candidates.failures.indices).subtracting(aiDiagnosticSelectedCases)
    }

    /// Called only by the explicit authorization button, using the displayed scan.
    public func runAIDiagnostics() {
        guard !aiDiagnosticRunning, let candidates = aiDiagnosticCandidates else { return }
        let evidence = candidates.selecting(aiDiagnosticSelectedCases)
        guard !evidence.isEmpty else { return }
        do {
            let source = try evidence.jsonText()
            aiDiagnosticGeneration += 1
            let token = aiDiagnosticGeneration
            aiDiagnosticTask?.cancel()
            let secrets = [apiKey]
            aiDiagnosticRunning = true
            aiDiagnosticResult = ""; aiDiagnosticEvidence = source
            aiDiagnosticFailureCount = evidence.failures.count
            aiDiagnosticStatus = text(
                "Sending \(evidence.failures.count) redacted failed case(s) to the configured model…",
                "正在将 \(evidence.failures.count) 个脱敏失败案例发送给已配置的模型…"
            )
            aiDiagnosticTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let action = self.runAIDiagnosticsAction else { throw SayoError.missingConfiguration }
                    let result = try await action(source)
                    guard !Task.isCancelled, token == self.aiDiagnosticGeneration else { return }
                    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw SayoError.invalidResponse }
                    self.aiDiagnosticResult = DiagnosticRedaction.text(trimmed, secrets: secrets)
                    self.aiDiagnosticStatus = self.text(
                        "AI diagnosis completed from \(evidence.failures.count) failed case(s).",
                        "AI 自诊断已完成，共分析 \(evidence.failures.count) 个失败案例。"
                    )
                    self.aiDiagnosticRunning = false
                } catch {
                    guard !Task.isCancelled, token == self.aiDiagnosticGeneration else { return }
                    self.aiDiagnosticStatus = self.text(
                        "AI diagnosis failed: \(error.localizedDescription)",
                        "AI 自诊断失败：\(error.localizedDescription)"
                    )
                    self.aiDiagnosticRunning = false
                }
            }
        } catch {
            aiDiagnosticRunning = false
            aiDiagnosticStatus = text(
                "Could not prepare redacted diagnostics: \(error.localizedDescription)",
                "无法准备脱敏诊断数据：\(error.localizedDescription)"
            )
        }
    }
    public func saveAIDiagnosticReport() {
        guard !aiDiagnosticResult.isEmpty, !aiDiagnosticEvidence.isEmpty else { return }
        saveAIDiagnosticReportAction?(aiDiagnosticResult, aiDiagnosticEvidence)
    }

    public func openAIDiagnosticIssue() {
        guard !aiDiagnosticRunning, !aiDiagnosticResult.isEmpty, !aiDiagnosticEvidence.isEmpty else { return }
        do {
            let evidence = try JSONDecoder().decode(AIDiagnosticEvidence.self, from: Data(aiDiagnosticEvidence.utf8))
            let draft = try AIDiagnosticIssueDraft(
                result: aiDiagnosticResult, evidence: evidence,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            guard openAIDiagnosticIssueAction?(draft.url) == true else {
                aiDiagnosticStatus = text("Could not open GitHub. Please try again.", "无法打开 GitHub，请重试。")
                return
            }
            aiDiagnosticStatus = draft.isAbbreviated
                ? text("GitHub draft opened with an abbreviated report. You can save and attach the full result file.",
                       "已打开 GitHub 草稿。内容较长，草稿包含摘要，可保存完整结果文件后添加为附件。")
                : text("GitHub draft opened. Review the content there before submitting.", "已打开 GitHub 草稿，请在 GitHub 检查内容后提交。")
        } catch {
            aiDiagnosticStatus = text("Could not prepare the GitHub draft: \(error.localizedDescription)",
                                      "无法准备 GitHub 草稿：\(error.localizedDescription)")
        }
    }
    public func scheduleAutoSave() {
        autoSaveTask?.cancel()
        settingsSaveState = .saving
        autoSaveTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: autoSaveDelayNanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            _ = save()
        }
    }
    @discardableResult public func save() -> Bool {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        settingsSaveState = .saving
        do {
            rememberCurrentProviderDraft()
            try saveAction?(settings, apiKey)
            if noticeIsError, notice == lastSaveError {
                notice = ""
                noticeIsError = false
            }
            lastSaveError = nil
            settingsSaveState = .saved
            return true
        } catch {
            lastSaveError = error.localizedDescription
            notice = error.localizedDescription
            noticeIsError = true
            settingsSaveState = .failed
            return false
        }
    }
    public func changeProvider(_ kind: ProviderKind) {
        changeModelProfile(kind.rawValue)
    }
    public func changeActiveModel(_ name: String) {
        guard settings.llm.provider != .chromeNano else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != settings.llm.model else { return }
        settings.llm.model = trimmed
        connectionConfigurationChanged()
    }
    public func changeModelProfile(_ profileID: String) {
        if profileID.hasPrefix("template:"),
           let kind = ProviderKind(rawValue: String(profileID.dropFirst("template:".count))) {
            addModelProfile(from: kind)
            return
        }
        guard profileID != settings.activeModelProfileID,
              let kind = providerKind(for: profileID) else { return }
        guard save() else { return }
        settings.activeModelProfileID = profileID

        if let draft = providerDrafts[profileID] {
            settings.llm = draft.configuration
            apiKey = draft.apiKey
        } else {
            var configuration = settings.providerConfigurations[profileID] ?? LLMConfiguration()
            configuration.provider = kind
            if settings.providerConfigurations[profileID] == nil {
                configuration.baseURL = kind.defaultBaseURL
                configuration.model = kind.defaultModel
            }
            settings.llm = configuration
            apiKey = loadKeyAction?(profileID) ?? kind.defaultAPIKey
            rememberCurrentProviderDraft()
        }
        connectionConfigurationChanged()
        availableModels = []; modelListResult = ""
        scheduleModelRefresh()
    }
    public func addModelProfile(from kind: ProviderKind) {
        guard ProviderKind.catalog.contains(kind) || kind == .custom else { return }
        guard save() else { return }
        let profileID = nextProfileID(for: kind)
        var configuration = LLMConfiguration()
        configuration.provider = kind
        configuration.baseURL = kind.defaultBaseURL
        configuration.model = kind.defaultModel
        settings.activeModelProfileID = profileID
        settings.llm = configuration
        apiKey = kind.defaultAPIKey
        rememberCurrentProviderDraft()
        connectionConfigurationChanged()
        availableModels = []; modelListResult = ""; modelListSucceeded = false
        scheduleModelRefresh()
    }
    public func modelProfileEditor(for selection: String) -> ModelProfileEditorSession? {
        let isNew = selection.hasPrefix("template:")
        let kind: ProviderKind?
        if isNew {
            kind = ProviderKind(rawValue: String(selection.dropFirst("template:".count)))
        } else {
            kind = providerKind(for: selection)
        }
        guard let kind else { return nil }
        guard !isNew || ProviderKind.catalog.contains(kind) || kind == .custom else { return nil }
        let profileID = isNew ? nextProfileID(for: kind) : selection
        var configuration = isNew ? LLMConfiguration() : configurationsByProfileID[profileID] ?? LLMConfiguration()
        configuration.provider = kind
        if isNew {
            configuration.baseURL = kind.defaultBaseURL
            configuration.model = kind.defaultModel
        }
        let key = isNew ? kind.defaultAPIKey : profileID == settings.activeModelProfileID
            ? apiKey : providerDrafts[profileID]?.apiKey ?? loadKeyAction?(profileID) ?? ""
        return ModelProfileEditorSession(parent: self, profileID: profileID,
                                         isNew: isNew, configuration: configuration, apiKey: key)
    }
    @discardableResult func commitModelProfile(_ profileID: String, configuration: LLMConfiguration,
                                               apiKey newKey: String) -> Bool {
        let previousSettings = settings, previousKey = apiKey, previousDrafts = providerDrafts
        rememberCurrentProviderDraft()
        settings.activeModelProfileID = profileID
        settings.llm = configuration
        apiKey = newKey
        settings.providerConfigurations[profileID] = configuration
        providerDrafts[profileID] = ProviderDraft(configuration: configuration, apiKey: newKey)
        guard save() else {
            settings = previousSettings; apiKey = previousKey; providerDrafts = previousDrafts
            return false
        }
        connectionConfigurationChanged()
        availableModels = []; modelListResult = ""; modelListSucceeded = false
        scheduleModelRefresh()
        return true
    }
    @discardableResult public func deleteModelProfile(_ profileID: String) -> Bool {
        guard isConfigured(profileID: profileID) else { return false }
        do { try deleteKeyAction?(profileID) }
        catch {
            notice = error.localizedDescription; noticeIsError = true
            return false
        }
        let replacement = configuredModelProfiles.first { $0.id != profileID }?.id
        settings.providerConfigurations.removeValue(forKey: profileID)
        providerDrafts.removeValue(forKey: profileID)
        if settings.activeModelProfileID == profileID {
            if let replacement, let kind = providerKind(for: replacement) {
                settings.activeModelProfileID = replacement
                let configuration = settings.providerConfigurations[replacement] ?? LLMConfiguration()
                settings.llm = configuration
                settings.llm.provider = kind
                apiKey = providerDrafts[replacement]?.apiKey ?? loadKeyAction?(replacement) ?? ""
            } else {
                settings.activeModelProfileID = ProviderKind.openAICompatible.rawValue
                settings.llm = LLMConfiguration()
                apiKey = ""
            }
            connectionConfigurationChanged()
            availableModels = []; modelListResult = ""; modelListSucceeded = false
            scheduleModelRefresh()
        }
        return save()
    }
    public func testConnection() {
        connectionConfigurationChanged()
        testingConnection = true
        connectionOriginal = Self.connectionTestText
        let token = connectionGeneration
        let configuration = settings.llm, key = apiKey
        let request = RewriteRequest(text: Self.connectionTestText, prompt: settings.effectivePrompt,
                                     targetLanguage: settings.targetLanguage)
        let startedAt = connectionNowAction()
        connectionTask = Task {
            do {
                guard let testConnectionAction else { throw SayoError.missingConfiguration }
                let result = try await testConnectionAction(configuration, key, request)
                guard token == connectionGeneration else { return }
                connectionOutput = result
                connectionResult = text("Connected", "连接成功"); connectionSucceeded = true
            } catch {
                guard token == connectionGeneration else { return }
                connectionResult = error.localizedDescription
            }
            if token == connectionGeneration {
                let finishedAt = connectionNowAction()
                connectionLatencyMilliseconds = finishedAt >= startedAt
                    ? (finishedAt - startedAt) / 1_000_000
                    : 0
                testingConnection = false
                if configuration.provider == .chromeNano { refreshNanoConnection() }
            }
        }
    }
    public func connectionConfigurationChanged() {
        rememberCurrentProviderDraft()
        connectionGeneration += 1; connectionTask?.cancel(); connectionTask = nil
        testingConnection = false; connectionResult = ""; connectionSucceeded = false
        connectionOriginal = ""; connectionOutput = ""
        connectionLatencyMilliseconds = nil
    }
    public func modelConnectionDetailsChanged() {
        connectionConfigurationChanged()
        availableModels = []; modelListResult = ""; modelListSucceeded = false
        scheduleModelRefresh()
    }
    public func refreshModels() {
        startModelRefresh(delayNanoseconds: 0)
    }
    public func refreshModelsIfConfigured() {
        scheduleModelRefresh()
    }
    private func scheduleModelRefresh() {
        guard canAutomaticallyLoadModels else {
            modelListGeneration += 1; modelListTask?.cancel(); modelListTask = nil
            loadingModels = false
            return
        }
        startModelRefresh(delayNanoseconds: 600_000_000)
    }
    private func startModelRefresh(delayNanoseconds: UInt64) {
        modelListGeneration += 1
        modelListTask?.cancel()
        let token = modelListGeneration
        let configuration = settings.llm, key = apiKey
        loadingModels = true; modelListResult = ""; modelListSucceeded = false
        modelListTask = Task {
            do {
                if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
                let models = try await fetchModelsAction?(configuration, key) ?? []
                guard token == modelListGeneration else { return }
                availableModels = models
                modelListSucceeded = true
                modelListResult = models.isEmpty
                    ? text("No models found.", "未找到模型。")
                    : text("Loaded \(models.count) models.", "已加载 \(models.count) 个模型。")
                if settings.llm.model.isEmpty, models.count == 1 { settings.llm.model = models[0] }
            } catch is CancellationError {
                return
            } catch {
                guard token == modelListGeneration else { return }
                availableModels = []; modelListResult = error.localizedDescription
            }
            if token == modelListGeneration { loadingModels = false }
        }
    }
    private var canAutomaticallyLoadModels: Bool {
        if settings.llm.provider == .chromeNano { return false }
        let baseURL = settings.llm.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return false }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard [.localModel, .openAICompatible, .custom].contains(settings.llm.provider),
              let host = URLComponents(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }
    private func rememberCurrentProviderDraft() {
        let profileID = settings.activeModelProfileID
        settings.providerConfigurations[profileID] = settings.llm
        providerDrafts[profileID] = ProviderDraft(configuration: settings.llm, apiKey: apiKey)
    }
    private var configurationsByProfileID: [String: LLMConfiguration] {
        var configurations = settings.providerConfigurations
        configurations[settings.activeModelProfileID] = settings.llm
        return configurations
    }
    private var configuredCustomProfileIDs: [String] {
        configurationsByProfileID.keys
            .filter { providerKind(for: $0) == .custom && isConfigured(profileID: $0) }
            .sorted { customIndex(for: $0) < customIndex(for: $1) }
    }
    private func nextProfileID(for kind: ProviderKind) -> String {
        let occupied = Set(configurationsByProfileID.keys.filter { isConfigured(profileID: $0) })
        var index = 1
        while occupied.contains(profileID(for: kind, index: index)) { index += 1 }
        return profileID(for: kind, index: index)
    }
    private func profileID(for kind: ProviderKind, index: Int) -> String {
        index == 1 ? kind.rawValue : "\(kind.rawValue)\(index)"
    }
    private func isConfigured(profileID: String) -> Bool {
        guard let configuration = configurationsByProfileID[profileID] else { return false }
        if configuration.provider == .chromeNano { return configuration.model == "gemini-nano" }
        return !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func profileOption(id: String, provider: ProviderKind) -> ModelProfileOption {
        ModelProfileOption(
            id: id,
            provider: provider,
            model: configurationsByProfileID[id]?.model ?? provider.defaultModel,
            customIndex: provider == .custom ? customIndex(for: id) : nil,
            instanceIndex: profileIndex(for: id, provider: provider)
        )
    }
    private func providerKind(for profileID: String) -> ProviderKind? {
        if customIndex(for: profileID) > 0 { return .custom }
        return ProviderKind.allCases.first { profileIndex(for: profileID, provider: $0) > 0 }
    }
    private func profileIndex(for profileID: String, provider: ProviderKind) -> Int {
        guard profileID.hasPrefix(provider.rawValue) else { return 0 }
        let suffix = profileID.dropFirst(provider.rawValue.count)
        if suffix.isEmpty { return 1 }
        guard let index = Int(suffix), index > 1, String(index) == suffix else { return 0 }
        return index
    }
    private func customIndex(for profileID: String) -> Int {
        profileIndex(for: profileID, provider: .custom)
    }
    public func loadCLIEditors() {
        guard supportsTerminal else { return }
        do { cliEditorInstalled = try loadCLIEditorsAction?() ?? [:] }
        catch { notice = error.localizedDescription; noticeIsError = true }
    }
    public func configureCLIEditor(_ program: String, install: Bool) {
        guard supportsTerminal else { return }
        do {
            let action = install ? installCLIEditorAction : resetCLIEditorAction
            guard let action else { throw SayoError.terminalUnavailable }
            try action(program)
            cliEditorInstalled = try loadCLIEditorsAction?() ?? [:]
            notice = install
                ? text("Installed; open a new terminal tab and restart the CLI.", "已安装；请打开新的终端标签页并重新启动 CLI。")
                : text("Reset; new terminal tabs use the CLI's own editor settings.", "已恢复默认；新的终端标签页将使用 CLI 自己的编辑器设置。")
            noticeIsError = false
        } catch {
            notice = error.localizedDescription; noticeIsError = true
        }
    }
    public func installTerminal(_ shell: String) {
        guard supportsTerminal else { return }
        do { notice = try terminalInstallAction?(shell) ?? text("Unavailable", "不可用"); noticeIsError = false }
        catch { notice = error.localizedDescription; noticeIsError = true }
    }
    public func uninstallTerminal(_ shell: String) {
        guard supportsTerminal else { return }
        do { notice = try terminalUninstallAction?(shell) ?? text("Not installed", "未安装"); noticeIsError = false }
        catch { notice = error.localizedDescription; noticeIsError = true }
    }
}

private struct ProviderDraft {
    var configuration: LLMConfiguration
    var apiKey: String
}

public extension WorkingMode {
    func title(language: InterfaceLanguage) -> String {
        switch self {
        case .silent: return language.text("Silent", "静默")
        case .manual: return language.text("Manual", "手动")
        }
    }
    var symbol: String { switch self { case .silent: "moon"; case .manual: "cursorarrow" } }
    func detail(language: InterfaceLanguage) -> String {
        switch self {
        case .silent: return language.text("A shortcut, then a quiet replacement.", "按下快捷键后直接安静地替换。")
        case .manual: return language.text("Click the little bubble when you need it.", "需要时点击小气泡开始改写。")
        }
    }
}
