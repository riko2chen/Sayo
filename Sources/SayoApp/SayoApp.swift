import AppKit
import OSLog
import SwiftUI
import SayoCore
import SayoApplication
import SayoPlatform
import SayoLLM
import SayoTerminal
import SayoUI

public enum SayoRuntime {
    @MainActor public static func run(updater: (any AppUpdateChecking)? = nil) {
        let app = NSApplication.shared
        let delegate = AppDelegate(updater: updater)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class RoutedInput: TextInputSource, AnimatedTextReplacer {
    var accessibility: AccessibilityTextAdapter?
    let copyPasteCompatibility: CopyPasteCompatibilityAdapter
    var terminalContext: TextContext?
    var terminalPID: pid_t?
    var terminalCompletion: ((TerminalResponse) -> Void)?
    init(accessibility: AccessibilityTextAdapter?, copyPasteCompatibility: CopyPasteCompatibilityAdapter) {
        self.accessibility = accessibility
        self.copyPasteCompatibility = copyPasteCompatibility
    }
    func currentContext() throws -> TextContext? {
        if let context = terminalContext {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == terminalPID else { return nil }
            return context
        }
        if copyPasteCompatibility.isActive {
            if let context = copyPasteCompatibility.currentContext() { return context }
            copyPasteCompatibility.cancel()
        }
        return try accessibility?.currentContext()
    }
    func replace(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        if terminalContext != nil {
            guard let current = try currentContext(), snapshot.matches(current) else { throw SayoError.staleInput }
            let result = snapshot.replacing(with: text)
            finish(.init(text: result))
            return .replaced
        } else if copyPasteCompatibility.isActive {
            return try await copyPasteCompatibility.replace(text, in: snapshot)
        } else {
            guard let accessibility else { throw SayoError.unsupportedInput }
            return try await accessibility.replace(text, in: snapshot)
        }
    }
    func replaceAnimated(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        if terminalContext != nil || copyPasteCompatibility.isActive {
            return try await replace(text, in: snapshot)
        }
        guard let accessibility else { throw SayoError.unsupportedInput }
        return try await accessibility.replaceAnimated(text, in: snapshot)
    }
    func finish(_ response: TerminalResponse) {
        let completion = terminalCompletion
        terminalCompletion = nil; terminalContext = nil; terminalPID = nil
        completion?(response)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let updater: (any AppUpdateChecking)?
    private let activeFeatures = AppFeature.shipped
    private var supportsFocusedInput: Bool { activeFeatures.contains(.focusedInput) }
    private var supportsTerminal: Bool { activeFeatures.contains(.terminalIntegration) }
    private var shipsTerminal: Bool { activeFeatures.contains(.terminalIntegration) }

    init(updater: (any AppUpdateChecking)?) {
        self.updater = updater
        super.init()
    }

    private let logger = Logger(subsystem: "com.sayo.app", category: "app")
    private let repository = DiskSettingsRepository()
    private let secrets = KeychainSecretStore(service: "com.sayo.app")
    private lazy var accessibility = AccessibilityTextAdapter()
    private let copyPasteCompatibility = CopyPasteCompatibilityAdapter()
    private let shortcuts = GlobalShortcutManager()
    private let loginItems = LoginItemManager()
    private var routedInput: RoutedInput!
    private var observer: InputObserver!
    private var coordinator: RewriteCoordinator!
    private var model: AppViewModel!
    private var bubble: BubblePanelController!
    private var bridge: TerminalBridge?
    private var installer: TerminalInstaller?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var modelEditorWindow: NSWindow?
    private var modelEditorSession: ModelProfileEditorSession?
    private var welcomeWindow: NSWindow?
    private var updateWindow: NSWindow?
    /// Sayo is a menu bar app: it appears in the Dock and app switcher only while one of its windows is open.
    private var hasOpenWindow = false
    private var permissionTimer: Timer?
    private let permissionGuide = AccessibilityPermissionGuideController()
    private var isPaused = false
    private var terminalTimeout: Task<Void, Never>?
    private var terminalShortcutDispatchTask: Task<Void, Never>?
    private var terminalTranslationRoute = TerminalTranslationRoute()
    private var compatibilityCaptureTask: Task<Void, Never>?
    private var lastLoggedAccessibilityGranted: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("launch")
        var loadError: Error?
        let settings: AppSettings
        do { settings = try repository.load() }
        catch { settings = AppSettings(); loadError = error }
        DiagnosticLog.shared.setEnabled(settings.retainDiagnosticLogs)
        DiagnosticLog.shared.record("launch", fields: [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "accessibilityTrusted": String(supportsFocusedInput && AccessibilityTextAdapter.isTrusted), "textSnippets": "false"
        ])
        model = AppViewModel(settings: settings)
        model.checkForUpdatesAction = { [weak self] in self?.updater?.checkForUpdates() }
        model.dismissUpdatePromptAction = { [weak self] in self?.updateWindow?.close() }
        model.updatePreferencesAction = { [weak self] checks, downloads in
            self?.updater?.configure(automaticallyChecks: checks, automaticallyDownloads: downloads)
        }
        updater?.onStateChange = { [weak self] state in self?.model.updateState = state }
        updater?.onShowUpdate = { [weak self] in self?.showUpdateWindow() }
        updater?.configure(automaticallyChecks: settings.automaticallyChecksForUpdates,
                           automaticallyDownloads: settings.automaticallyDownloadsUpdates)
        updater?.start()
        model.updateState = updater?.state ?? .notConfigured
        model.configPath = repository.url.path
        model.diagnosticPath = DiagnosticLog.shared.directory.path
        model.apiKey = (try? secrets.readKey(for: settings.activeModelProfileID)) ?? ""
        if let loadError {
            model.notice = settings.interfaceLanguage.text(
                "Settings could not be loaded: \(loadError.localizedDescription)",
                "设置无法加载：\(loadError.localizedDescription)"
            )
            model.noticeIsError = true
        }
        routedInput = RoutedInput(accessibility: supportsFocusedInput ? accessibility : nil, copyPasteCompatibility: copyPasteCompatibility)
        observer = InputObserver(source: routedInput)
        coordinator = RewriteCoordinator(settings: settings, source: routedInput, replacer: routedInput,
            provider: ConfiguredRewriteProvider(configuration: settings.llm, apiKey: model.apiKey))
        bubble = BubblePanelController()
        configureBindings()
        makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = makeStatusItemImage(style: settings.statusBarIconStyle)
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = settings.interfaceLanguage.text("Sayo · Rewrite wherever you type", "Sayo · 随处改写")
        updateMenu()
        if shipsTerminal {
            do { installer = try TerminalInstaller() } catch { model.notice = error.localizedDescription; model.noticeIsError = true }
        }
        applyRuntime(settings)
        refreshStatus()
        if !settings.onboardingCompleted && !CommandLine.arguments.contains("--background") { showWelcome() }
        else if CommandLine.arguments.contains("--settings") { showSettings() }
        updater?.checkForUpdatesAutomatically()
    }

    private func configureBindings() {
        var invocationApplications: [String: [String: String]] = [:]
        coordinator.onDiagnostic = { [weak self] event, fields in
            var fields = fields
            if let id = fields["invocationID"] {
                if event == "invocation_started" {
                    if invocationApplications.count > 64 { invocationApplications.removeAll() }
                    let app = NSWorkspace.shared.frontmostApplication
                    invocationApplications[id] = ["app": app?.localizedName ?? "unknown", "bundleID": app?.bundleIdentifier ?? "unknown"]
                }
                fields.merge(invocationApplications[id] ?? [:], uniquingKeysWith: { current, _ in current })
            }
            if event == "input_captured", self?.routedInput.terminalContext == nil,
               let evidence = self?.accessibility.lastInputDiagnosticFields,
               evidence["inputID"] == fields["inputID"] {
                fields.merge(evidence, uniquingKeysWith: { current, _ in current })
            }
            DiagnosticLog.shared.record(event, fields: fields)
        }
        coordinator.onChange = { [weak self] state in
            guard let self else { return }
            self.logger.debug("bubble state phase=\(String(describing: state.phase), privacy: .public) expanded=\(state.expanded, privacy: .public) context=\(state.context != nil, privacy: .public) caret=\(state.context?.caret != nil, privacy: .public)")
            if self.supportsFocusedInput {
                self.accessibility.replacementInvocationID = self.coordinator.diagnosticInvocationID
            }
            self.copyPasteCompatibility.replacementInvocationID = self.coordinator.diagnosticInvocationID
            var bubbleFields = [
                "phase": String(describing: state.phase), "expanded": String(state.expanded),
                "app": state.context?.applicationName ?? "none", "inputID": state.context?.id ?? "none",
                "resolvedLength": state.context.map { String($0.text.utf16.count) } ?? "none"
            ]
            bubbleFields["invocationID"] = self.coordinator.diagnosticInvocationID
            DiagnosticLog.shared.record("bubble", fields: bubbleFields)
            self.bubble.update(state)
            if state.phase == .hidden { self.copyPasteCompatibility.cancel() }
            if state.phase == .hidden, self.routedInput.terminalContext != nil {
                self.routedInput.finish(.init(error: self.localized(
                    "Rewrite cancelled because the input or focus changed.",
                    "输入内容或焦点发生变化，改写已取消。"
                )))
            } else if state.phase == .failed, self.routedInput.terminalContext != nil {
                self.routedInput.finish(.init(error: state.message))
            }
        }
        bubble.onRewrite = { [weak self] in self?.coordinator.click() }
        bubble.onReplace = { [weak self] in self?.coordinator.applyResult() }
        bubble.onDismiss = { [weak self] in self?.dismissRewrite() }
        bubble.onCopy = { [weak self] in self?.copyResult() }
        model.saveAction = { [weak self] settings, key in
            guard let self else { return }
            self.logger.info("settings save requested provider=\(settings.llm.provider.rawValue, privacy: .public) interfaceLanguage=\(settings.interfaceLanguage.rawValue, privacy: .public) targetLanguage=\(settings.targetLanguage.rawValue, privacy: .public) modelConfigured=\(!settings.llm.model.isEmpty, privacy: .public)")
            // Validate before persisting so shortcut conflicts leave the saved configuration intact.
            do {
                try self.repository.validateForSave(settings)
                let current = self.coordinator.settings
                if self.supportsFocusedInput && current.globalShortcutBindings != settings.globalShortcutBindings {
                    try self.validateTerminalShortcutSeparation(settings)
                }
                if self.supportsFocusedInput && NSApp.isActive {
                    try self.shortcuts.validate(settings.activeGlobalShortcuts)
                }
                try self.registerShortcuts(settings)
                try self.secrets.saveKey(key, for: settings.activeModelProfileID)
                if self.loginItems.enabled != settings.launchAtLogin { try self.loginItems.setEnabled(settings.launchAtLogin) }
                try self.repository.save(settings)
                self.applyRuntime(settings)
                self.logger.info("settings saved")
            } catch {
                try? self.registerShortcuts(self.coordinator.settings)
                self.logger.error("settings save failed error=\(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        model.openConfigAction = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.repository.url])
        }
        model.loadKeyAction = { [weak self] profileID in (try? self?.secrets.readKey(for: profileID)) ?? "" }
        model.deleteKeyAction = { [weak self] profileID in
            try self?.secrets.saveKey("", for: profileID)
        }
        model.openModelEditorAction = { [weak self] selection in
            self?.showModelEditor(selection: selection)
        }
        model.testConnectionAction = { configuration, key, request in
            let provider = ConfiguredRewriteProvider(configuration: configuration, apiKey: key)
            return try await provider.rewrite(request).text
        }
        model.fetchModelsAction = { configuration, key in
            if configuration.provider == .chromeNano { return ["gemini-nano"] }
            return try await HTTPModelCatalog(configuration: configuration, apiKey: key).models()
        }
        model.nanoIsConnectedAction = { ChromeNanoBridge.shared.isConnected }
        model.connectNanoAction = { language in
            guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                throw SayoError.network("Install Google Chrome 148 or later to connect Gemini Nano. / 请安装 Chrome 148 或更高版本。")
            }
            let url = try await ChromeNanoBridge.shared.connectionURL(interfaceLanguage: language)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration)
        }
        model.permissionAction = { [weak self] in
            guard let self, self.supportsFocusedInput else { return }
            self.permissionGuide.begin(language: self.model.settings.interfaceLanguage) { [weak self] in self?.refreshStatus() }
        }
        model.refreshAction = { [weak self] in self?.refreshStatus() }
        model.refreshDiagnosticsAction = { try DiagnosticLog.shared.recentText(limit: Int.max) }
        model.openDiagnosticsAction = {
            try DiagnosticLog.shared.prepareDirectory()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: DiagnosticLog.shared.directory.path)
        }
        model.exportDiagnosticsAction = { [weak self] in self?.exportDiagnostics() }
        model.exportDiagnosticGroupAction = { [weak self] group in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let text = group.events.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
            self?.exportDiagnostics(text: text)
        }
        model.diagnosticSnippetsAction = { [weak self] enabled in
            if self?.supportsFocusedInput == true { self?.accessibility.diagnosticTextSnippetsEnabled = enabled }
            DiagnosticLog.shared.record("diagnostic_options", fields: ["textSnippets": String(enabled)])
        }
        model.runAIDiagnosticsAction = { [weak self] evidence in
            guard let self else { throw CancellationError() }
            let language = self.model.settings.interfaceLanguage
            let responseLanguage = language.resolved == .simplifiedChinese
                ? "Write the diagnosis in concise Simplified Chinese."
                : "Write the diagnosis in concise English."
            let prompt = """
            You are the diagnostic assistant built into Sayo, a macOS writing and translation app.
            Analyze only the supplied redacted diagnostic evidence. Do not invent events, source text,
            translated text, system state, or a confirmed root cause that the evidence cannot establish.
            Explain: (1) what failed, grouped by application when useful; (2) the most likely cause and
            the evidence for it; (3) safe steps the user can try; and (4) what remains uncertain and
            would help the author investigate. Clearly distinguish facts from hypotheses. Never ask for
            API keys, input text, translated text, or other private content. \(responseLanguage)
            """
            DiagnosticLog.shared.record("ai_diagnostic_requested", fields: ["windowMinutes": "30"])
            let provider = ConfiguredRewriteProvider(configuration: self.model.settings.llm, apiKey: self.model.apiKey)
            let result = try await provider.rewrite(.init(text: evidence, prompt: prompt,
                targetLanguage: language.resolved == .simplifiedChinese ? .simplifiedChinese : .english))
            DiagnosticLog.shared.record("ai_diagnostic_completed", fields: [
                "resultLength": String(result.text.utf16.count)
            ])
            return result.text
        }
        model.saveAIDiagnosticReportAction = { [weak self] result, evidence in
            self?.exportAIDiagnosticReport(result: result, evidence: evidence)
        }
        model.openAIDiagnosticIssueAction = { NSWorkspace.shared.open($0) }
        if shipsTerminal {
            model.loadCLIShortcutAction = { name in
                guard let program = CLIEditorProgram(rawValue: name) else { throw SayoError.terminalUnavailable }
                return try CLIShortcutSettings().status(program).value
            }
            model.configureCLIShortcutAction = { [weak self] name, key in
                guard let program = CLIEditorProgram(rawValue: name) else { throw SayoError.terminalUnavailable }
                let shortcuts = CLIShortcutSettings()
                if let key {
                    let normalized = try CLIShortcutSettings.validatedKey(key, program: program)
                    if let self {
                        try TerminalShortcutConflictPolicy.validateCLIShortcut(
                            normalized,
                            program: program,
                            globalShortcuts: self.model.settings.configuredGlobalShortcuts
                        )
                    }
                    guard try CLIEditorInstaller().isInstalled(program) else {
                        throw NSError(domain: "Sayo", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "Install this CLI’s editor integration in Terminal first. / 请先在「终端」中安装该 CLI 的编辑器集成。"])
                    }
                    if program == .codex { try CLIEditorInstaller().install(program) }
                    try shortcuts.apply(program, key: key)
                } else {
                    if program == .codex, try CLIEditorInstaller().isInstalled(program) {
                        try CLIEditorInstaller().install(program)
                    }
                    try shortcuts.disable(program)
                }
            }
            model.loadCLIEditorsAction = {
                let installer = CLIEditorInstaller()
                return try Dictionary(uniqueKeysWithValues: CLIEditorProgram.allCases.map {
                    ($0.rawValue, try installer.isInstalled($0))
                })
            }
            model.installCLIEditorAction = { name in
                guard let program = CLIEditorProgram(rawValue: name) else { throw SayoError.terminalUnavailable }
                let key = try CLIShortcutSettings().status(program).value
                try TerminalShortcutConflictPolicy.validateCLIShortcut(
                    key,
                    program: program,
                    globalShortcuts: self.model.settings.configuredGlobalShortcuts
                )
                try CLIEditorInstaller().install(program)
            }
            model.resetCLIEditorAction = { name in
                guard let program = CLIEditorProgram(rawValue: name) else { throw SayoError.terminalUnavailable }
                try CLIEditorInstaller().reset(program)
            }
            model.terminalInstallAction = { [weak self] shellName in
                guard let self, let shell = TerminalShell(rawValue: shellName), let installer = self.installer else { throw SayoError.terminalUnavailable }
                try TerminalShortcutConflictPolicy.validateGlobalShortcuts(
                    self.model.settings.configuredGlobalShortcuts,
                    shellIntegrationInstalled: true,
                    cliShortcuts: [:]
                )
                try installer.install(shell: shell)
                self.refreshStatus()
                return self.localized(
                    "\(shell.name) installed. Open a new terminal tab to use Sayo.",
                    "已安装 \(shell.name) 集成。请打开新的终端标签页使用 Sayo。"
                )
            }
            model.terminalUninstallAction = { [weak self] shellName in
                guard let self, let shell = TerminalShell(rawValue: shellName), let installer = self.installer else { throw SayoError.terminalUnavailable }
                try installer.uninstall(shell: shell)
                self.refreshStatus()
                return self.localized(
                    "\(shell.name) integration removed. Open a new terminal tab.",
                    "已移除 \(shell.name) 集成。请打开新的终端标签页。"
                )
            }
        }
        model.finishOnboardingAction = { [weak self] in self?.welcomeWindow?.close(); self?.showSettings() }
        model.showOnboardingAction = { [weak self] in self?.model.onboardingStep = 0; self?.showWelcome() }
        model.workingModeChangeAction = { [weak self] settings in
            guard let self, self.supportsFocusedInput else { return }
            do {
                try self.registerShortcuts(settings)
                self.coordinator.configureShortcutBehavior(settings)
                self.model.notice = self.localized(
                    "Working mode updated.",
                    "工作模式已更新。"
                )
                self.model.noticeIsError = false
            } catch {
                self.model.notice = error.localizedDescription
                self.model.noticeIsError = true
            }
            self.updateMenu()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismissRewrite() }
            return event
        }
    }

    private func applyRuntime(_ settings: AppSettings) {
        updater?.configure(automaticallyChecks: settings.automaticallyChecksForUpdates,
                           automaticallyDownloads: settings.automaticallyDownloadsUpdates)
        DiagnosticLog.shared.setEnabled(settings.retainDiagnosticLogs)
        syncFeatureServices()
        updateDockVisibility()
        dismissRewrite()
        if supportsFocusedInput {
            accessibility.applicationAccess = settings.applicationAccess
        }
        coordinator.configure(settings, provider: ConfiguredRewriteProvider(configuration: settings.llm,
            apiKey: (try? secrets.readKey(for: settings.activeModelProfileID)) ?? ""))
        bubble.configure(
            interfaceLanguage: settings.interfaceLanguage,
            copyShortcut: settings.copyShortcut,
            replaceShortcut: settings.replaceShortcut,
        )
        statusItem?.button?.image = makeStatusItemImage(style: settings.statusBarIconStyle)
        statusItem?.button?.toolTip = settings.interfaceLanguage.text("Sayo · Rewrite wherever you type", "Sayo · 随处改写")
        settingsWindow?.title = settings.interfaceLanguage.text("Sayo Settings", "Sayo 设置")
        welcomeWindow?.title = settings.interfaceLanguage.text("Welcome to Sayo", "欢迎使用 Sayo")
        do { try registerShortcuts(settings) }
        catch { model.notice = error.localizedDescription; model.noticeIsError = true }
        if !isPaused { startObserving() }
        makeMainMenu()
        updateMenu()
        refreshStatus()
    }

    /// Starts or stops the services behind optional features so they match `activeFeatures`.
    private func syncFeatureServices() {
        routedInput.accessibility = supportsFocusedInput ? accessibility : nil
        if supportsFocusedInput {
            if permissionTimer == nil {
                permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshStatus() }
                }
            }
        } else {
            permissionTimer?.invalidate(); permissionTimer = nil
            observer.stop()
            shortcuts.unregister()
            permissionGuide.close()
        }
        if supportsTerminal {
            guard bridge == nil else { return }
            do {
                let bridge = try TerminalBridge()
                let closing = localized("Sayo is closing.", "Sayo 正在关闭。")
                bridge.start { [weak self] request in
                    guard let self else { return .init(error: closing) }
                    return await self.handleTerminal(request)
                }
                self.bridge = bridge
            } catch { model.notice = error.localizedDescription; model.noticeIsError = true }
        } else {
            bridge?.stop(); bridge = nil
        }
    }

    private func updateDockVisibility() {
        let activationPolicy: NSApplication.ActivationPolicy = hasOpenWindow ? .regular : .accessory
        if NSApp.activationPolicy() != activationPolicy {
            NSApp.setActivationPolicy(activationPolicy)
        }
        // Supply the bundled image directly: Launch Services can retain an old
        // Dock icon after an in-place application update.
        if hasOpenWindow,
           let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }
    private func registerShortcuts(_ settings: AppSettings) throws {
        guard supportsFocusedInput else { return }
        try settings.validateTranslationShortcuts()
        try shortcuts.register(settings.activeGlobalShortcuts, enabled: !NSApp.isActive) { [weak self] shortcut in
            self?.shortcutPressed(shortcut)
        }
    }
    private func validateTerminalShortcutSeparation(_ settings: AppSettings) throws {
        let shellInstalled = TerminalShell.allCases.contains { installer?.isInstalled(shell: $0) == true }
        let cliInstaller = CLIEditorInstaller()
        let cliSettings = CLIShortcutSettings()
        var cliShortcuts: [CLIEditorProgram: String] = [:]
        for program in CLIEditorProgram.allCases {
            guard try cliInstaller.isInstalled(program) else { continue }
            cliShortcuts[program] = try cliSettings.status(program).value
        }
        try TerminalShortcutConflictPolicy.validateGlobalShortcuts(
            settings.configuredGlobalShortcuts,
            shellIntegrationInstalled: shellInstalled,
            cliShortcuts: cliShortcuts
        )
    }
    private func startObserving() {
        guard supportsFocusedInput else { return }
        observer.start { [weak self] context in
            guard let self, !self.isPaused else { return }
            if let context {
                self.logger.debug("input context app=\(context.applicationName, privacy: .public) utf16Length=\(context.text.utf16.count, privacy: .public) selectionLength=\(context.selection.length, privacy: .public) caret=\(context.caret != nil, privacy: .public)")
            } else if let error = self.observer.lastError {
                self.logger.error("input unavailable error=\(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.debug("input context none")
            }
            self.coordinator.inputChanged(context)
        }
    }
    private func shortcutPressed(_ shortcut: Shortcut) {
        guard supportsFocusedInput else { return }
        let settings = coordinator.settings
        let state = coordinator.state
        if settings.secondaryShortcut == shortcut {
            invokeShortcutPressed(triggeringShortcut: shortcut, destination: .secondary)
            return
        }
        if settings.mode == .silent, settings.replaceShortcut == shortcut {
            invokeShortcutPressed(triggeringShortcut: shortcut)
            return
        }
        if settings.mode.showsCopyShortcut, !state.result.isEmpty, settings.copyShortcut == shortcut {
            copyResult()
            return
        }
        if state.phase == .ready, settings.replaceShortcut == shortcut {
            coordinator.applyResult()
            return
        }
        guard settings.mode.showsInvokeShortcut, settings.invokeShortcut == shortcut else { return }
        invokeShortcutPressed(triggeringShortcut: shortcut)
    }
    private func invokeShortcutPressed(triggeringShortcut: Shortcut, destination: TranslationDestination = .primary) {
        guard !isPaused, coordinator.state.phase != .loading, coordinator.state.phase != .replacing else { return }
        terminalShortcutDispatchTask?.cancel()
        terminalTranslationRoute.clear()
        if routedInput.terminalContext != nil { coordinator.shortcut(destination: destination); return }
        if let application = NSWorkspace.shared.frontmostApplication,
           TerminalDetector.isTerminal(application.bundleIdentifier) {
            switch TerminalForegroundProcessDetector.detect(in: application) {
            case .cli(let command):
                invokeCLIShortcut(command, triggeringShortcut: triggeringShortcut, destination: destination, applicationPID: application.processIdentifier)
                return
            case .unknown:
                DiagnosticLog.shared.record("terminal_shortcut_route_unknown", fields: [
                    "app": application.localizedName ?? "unknown",
                    "bundleID": application.bundleIdentifier ?? "unknown",
                    "attempt": UUID().uuidString
                ])
                model.notice = localized(
                    "Sayo could not identify the CLI in the focused terminal tab. Focus its input and try again.",
                    "Sayo 无法识别当前终端标签页中的 CLI。请聚焦到输入区后重试。"
                )
                model.noticeIsError = true
                return
            case .shell:
                break
            }
            guard TerminalShell.allCases.contains(where: { installer?.isInstalled(shell: $0) == true }) else {
                model.notice = localized(
                    "Install your shell integration in Terminal settings first.",
                    "请先在终端设置中安装 Shell 集成。"
                ); model.noticeIsError = true
                showSettings(); return
            }
            DiagnosticLog.shared.record("terminal_shortcut_route", fields: [
                "route": "shell", "attempt": UUID().uuidString
            ])
            terminalShortcutDispatchTask?.cancel()
            terminalShortcutDispatchTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.terminalShortcutDispatchTask = nil }
                let routeID = self.terminalTranslationRoute.arm(destination: destination, applicationPID: application.processIdentifier)
                do {
                    try await self.shortcuts.triggerTerminalWidget(afterReleasing: triggeringShortcut)
                    DiagnosticLog.shared.record("terminal_shortcut_posted", fields: [
                        "route": "shell", "key": "ctrl+x ctrl+r"
                    ])
                } catch is CancellationError {
                    self.terminalTranslationRoute.clear(id: routeID)
                    return
                } catch {
                    self.terminalTranslationRoute.clear(id: routeID)
                    DiagnosticLog.shared.record("terminal_shortcut_route_failed", fields: [
                        "route": "shell", "error": error.localizedDescription
                    ])
                    self.model.notice = error.localizedDescription
                    self.model.noticeIsError = true
                }
            }
        } else { invokeTextShortcutPressed(destination: destination) }
    }

    private func invokeCLIShortcut(_ command: TerminalForegroundCommand, triggeringShortcut: Shortcut, destination: TranslationDestination, applicationPID: Int32) {
        let program = command.program
        do {
            guard try CLIEditorInstaller().isInstalled(program) else {
                model.notice = localized(
                    "Install the \(program.name) editor integration in Terminal settings first.",
                    "请先在终端设置中安装 \(program.name) 编辑器集成。"
                )
                model.noticeIsError = true
                showSettings()
                return
            }
            let state = try CLIShortcutSettings().status(program)
            guard let shortcut = CLIShortcut.shortcut(for: state.value) else {
                model.notice = localized(
                    "The \(program.name) external-editor shortcut is unbound.",
                    "\(program.name) 的外部编辑器快捷键尚未绑定。"
                )
                model.noticeIsError = true
                showSettings()
                return
            }
            DiagnosticLog.shared.record("terminal_shortcut_route", fields: [
                "route": "cli",
                "program": program.rawValue,
                "key": state.value,
                "tty": command.tty ?? "unknown",
                "matchesGlobal": String(coordinator.settings.activeGlobalShortcuts.contains(shortcut)),
                "attempt": UUID().uuidString
            ])
            terminalShortcutDispatchTask?.cancel()
            terminalShortcutDispatchTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.terminalShortcutDispatchTask = nil }
                let routeID = self.terminalTranslationRoute.arm(destination: destination, applicationPID: applicationPID)
                do {
                    let relayed = try await self.shortcuts.triggerTerminalCLIShortcut(
                        shortcut,
                        afterReleasing: triggeringShortcut
                    )
                    DiagnosticLog.shared.record("terminal_shortcut_posted", fields: [
                        "program": program.rawValue,
                        "key": state.value,
                        "relayed": String(relayed)
                    ])
                } catch is CancellationError {
                    self.terminalTranslationRoute.clear(id: routeID)
                    return
                } catch {
                    self.terminalTranslationRoute.clear(id: routeID)
                    DiagnosticLog.shared.record("terminal_shortcut_route_failed", fields: [
                        "route": "cli",
                        "program": program.rawValue,
                        "error": error.localizedDescription
                    ])
                    self.model.notice = error.localizedDescription
                    self.model.noticeIsError = true
                }
            }
        } catch {
            DiagnosticLog.shared.record("terminal_shortcut_route_failed", fields: [
                "route": "cli",
                "program": program.rawValue,
                "error": error.localizedDescription
            ])
            model.notice = error.localizedDescription
            model.noticeIsError = true
            showSettings()
        }
    }
    private func invokeTextShortcutPressed(destination: TranslationDestination) {
        guard compatibilityCaptureTask == nil else { return }
        if copyPasteCompatibility.isActive {
            coordinator.shortcut(destination: destination)
            return
        }

        do {
            if try accessibility.currentContext() != nil {
                coordinator.shortcut(destination: destination)
                return
            }
        } catch let error as SayoError where error != .unsupportedInput {
            coordinator.shortcut(destination: destination)
            return
        } catch {
            coordinator.shortcut(destination: destination)
            return
        }

        let settings = coordinator.settings
        guard settings.copyPasteCompatibilityEnabled,
              CopyPasteCompatibilityAdapter.shouldAttemptFallback(after: accessibility.lastInputDiagnosticFields),
              let application = NSWorkspace.shared.frontmostApplication,
              settings.allowsApplication(bundleIdentifier: application.bundleIdentifier)
        else {
            coordinator.shortcut(destination: destination)
            return
        }

        compatibilityCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.compatibilityCaptureTask = nil }
            do {
                _ = try await self.copyPasteCompatibility.captureCurrentSelection()
                guard self.coordinator.settings.copyPasteCompatibilityEnabled else {
                    self.copyPasteCompatibility.cancel()
                    throw SayoError.staleInput
                }
                self.coordinator.shortcut(destination: destination)
            } catch is CancellationError {
                self.copyPasteCompatibility.cancel()
            } catch {
                self.copyPasteCompatibility.cancel()
                self.coordinator.rejectInvocation(error, trigger: "copy_paste_compatibility")
            }
        }
    }
    private func copyResult() {
        let text = coordinator.state.result
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func handleTerminal(_ request: TerminalRequest) async -> TerminalResponse {
        guard !isPaused else { return .init(error: localized("Sayo is paused.", "Sayo 已暂停。")) }
        guard routedInput.terminalContext == nil else {
            return .init(error: localized("Finish the current Sayo rewrite first.", "请先完成当前的 Sayo 改写。"))
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == request.applicationPID else {
            return .init(error: localized("The terminal is no longer focused.", "终端已经失去焦点。"))
        }
        guard model.settings.allowsApplication(bundleIdentifier: application.bundleIdentifier) else {
            return .init(error: localized("Sayo is disabled in this app.", "Sayo 已在此应用中停用。"))
        }
        let destination = terminalTranslationRoute.consume(for: request)
        coordinator.dismiss()
        let timeoutMessage = localized(
            "Rewrite timed out. Your original buffer was kept.",
            "改写超时，原始终端缓冲区已保留。"
        )
        return await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: TerminalResponse(error: localized("Request cancelled.", "请求已取消。")))
                return
            }
            routedInput.terminalPID = request.applicationPID
            let mouse = NSEvent.mouseLocation
            routedInput.terminalContext = TextContext(id: "terminal:\(request.id.uuidString)", text: request.text,
                selection: request.selection, caret: .init(x: mouse.x, y: mouse.y, width: 0, height: 0),
                applicationName: application.localizedName ?? "Terminal")
            routedInput.terminalCompletion = { [weak self] response in
                self?.terminalTimeout?.cancel(); self?.terminalTimeout = nil
                continuation.resume(returning: response)
            }
            terminalTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(110)) } catch { return }
                guard self?.routedInput.terminalContext?.id == "terminal:\(request.id.uuidString)" else { return }
                self?.routedInput.finish(.init(error: timeoutMessage))
                self?.coordinator.dismiss()
            }
            coordinator.beginRewrite(autoApply: coordinator.settings.mode == .silent, trigger: "terminal", destination: destination)
          }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.routedInput.terminalContext?.id == "terminal:\(request.id.uuidString)" else { return }
                self.dismissRewrite()
            }
        }
    }
    private func dismissRewrite() {
        terminalShortcutDispatchTask?.cancel()
        terminalShortcutDispatchTask = nil
        terminalTranslationRoute.clear()
        compatibilityCaptureTask?.cancel()
        compatibilityCaptureTask = nil
        copyPasteCompatibility.cancel()
        routedInput.finish(.init(error: localized(
            "Rewrite cancelled. Your original buffer was kept.",
            "改写已取消，原始终端缓冲区已保留。"
        )))
        coordinator.dismiss()
    }
    private func refreshStatus() {
        let accessibilityGranted = supportsFocusedInput && AccessibilityTextAdapter.isTrusted
        model.accessibilityGranted = accessibilityGranted
        if lastLoggedAccessibilityGranted != accessibilityGranted {
            logger.info("accessibilityTrusted=\(accessibilityGranted, privacy: .public)")
            lastLoggedAccessibilityGranted = accessibilityGranted
        }
        if accessibilityGranted { permissionGuide.close() }
        if let installer {
            model.terminalInstalled = Dictionary(uniqueKeysWithValues: TerminalShell.allCases.map {
                ($0.rawValue, installer.isInstalled(shell: $0))
            })
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if model != nil { updater?.checkForUpdatesAutomatically() }
        guard supportsFocusedInput else { return }
        do { try shortcuts.setEnabled(false) }
        catch { logger.error("shortcut suspension failed error=\(error.localizedDescription, privacy: .public)") }
        refreshStatus()
        permissionGuide.refreshPermission()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard supportsFocusedInput else { return }
        do { try shortcuts.setEnabled(true) }
        catch {
            model.notice = error.localizedDescription
            model.noticeIsError = true
            logger.error("shortcut restoration failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 925, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = model.settings.interfaceLanguage.text("Sayo Settings", "Sayo 设置"); window.identifier = .init("sayo.settings")
            window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 900, height: 690); window.center(); settingsWindow = window
        }
        hasOpenWindow = true
        updateDockVisibility()
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdatesAutomatically()
    }

    private func showModelEditor(selection: String) {
        if let modelEditorWindow, modelEditorWindow.isVisible {
            modelEditorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let session = model.modelProfileEditor(for: selection) else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = localized(session.isNew ? "Add model" : "Edit model",
                                 session.isNew ? "新增模型" : "编辑模型")
        window.identifier = .init("sayo.model-editor")
        window.minSize = NSSize(width: 620, height: 630)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ModelProfileEditorView(
            session: session,
            onSaved: { [weak window] in window?.close() },
            onCancel: { [weak window] in window?.performClose(nil) }
        ))
        window.center()
        modelEditorSession = session
        modelEditorWindow = window
        hasOpenWindow = true
        updateDockVisibility()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func exportDiagnostics(text: String? = nil) {
        do {
            let text = try text ?? DiagnosticLog.shared.recentText(limit: Int.max)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "sayo-diagnostics.jsonl"
            panel.title = localized("Export diagnostic logs", "导出诊断日志")
            panel.canCreateDirectories = true
            guard let settingsWindow else { return }
            panel.beginSheetModal(for: settingsWindow) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    self.model.notice = self.localized("Logs exported to \(url.path)", "日志已导出到 \(url.path)")
                    self.model.noticeIsError = false
                } catch { self.model.notice = error.localizedDescription; self.model.noticeIsError = true }
            }
        } catch { model.notice = error.localizedDescription; model.noticeIsError = true }
    }

    private func exportAIDiagnosticReport(result: String, evidence: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let report = """
        Sayo AI Diagnosis
        Generated: \(formatter.string(from: Date()))
        Version: \(version) (\(build))
        Window: past 30 minutes

        This report contains the AI diagnosis and the exact redacted diagnostic evidence sent to the configured model.
        It excludes input text, rewritten text, API keys, prompts, process IDs, and internal invocation identifiers.

        === AI Diagnosis ===

        \(result)

        === Redacted Diagnostic Evidence ===

        \(evidence)
        """
        let panel = NSSavePanel()
        let filenameDate = DateFormatter()
        filenameDate.locale = Locale(identifier: "en_US_POSIX")
        filenameDate.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "sayo-ai-diagnosis-\(filenameDate.string(from: Date())).txt"
        panel.title = localized("Save AI diagnosis", "保存 AI 自诊断结果")
        panel.canCreateDirectories = true
        guard let settingsWindow else { return }
        panel.beginSheetModal(for: settingsWindow.attachedSheet ?? settingsWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                self.model.notice = self.localized("Diagnosis saved to \(url.path)", "诊断结果已保存到 \(url.path)")
                self.model.noticeIsError = false
            } catch {
                self.model.notice = error.localizedDescription
                self.model.noticeIsError = true
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === modelEditorWindow {
            guard modelEditorSession?.hasUnsavedChanges == true else { return true }
            return confirmDiscardModelChanges()
        }
        guard sender === settingsWindow else { return true }
        return model.save()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard modelEditorSession?.hasUnsavedChanges == true else { return .terminateNow }
        return confirmDiscardModelChanges() ? .terminateNow : .terminateCancel
    }

    private func confirmDiscardModelChanges() -> Bool {
        let alert = NSAlert()
        alert.messageText = localized("Discard unsaved model changes?", "放弃未保存的模型更改？")
        alert.informativeText = localized("Changes in this window will not be saved.",
                                         "此窗口中的更改不会保存。")
        alert.addButton(withTitle: localized("Keep editing", "继续编辑"))
        alert.addButton(withTitle: localized("Discard changes", "放弃更改"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindow || closingWindow === welcomeWindow
                || closingWindow === modelEditorWindow || closingWindow === updateWindow else { return }
        let hasOtherWindow = [settingsWindow, welcomeWindow, modelEditorWindow, updateWindow].compactMap { $0 }.contains {
            $0 !== closingWindow && ($0.isVisible || $0.isMiniaturized)
        }
        if closingWindow === modelEditorWindow {
            modelEditorWindow = nil
            modelEditorSession = nil
        }
        if !hasOtherWindow {
            hasOpenWindow = false
            updateDockVisibility()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showWelcome() {
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 760), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = model.settings.interfaceLanguage.text("Welcome to Sayo", "欢迎使用 Sayo"); window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.delegate = self
            window.center(); welcomeWindow = window
        }
        hasOpenWindow = true
        updateDockVisibility()
        welcomeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func replayWelcome() { model.onboardingStep = 0; showWelcome() }
    @objc private func togglePause() {
        isPaused.toggle()
        DiagnosticLog.shared.record("pause", fields: ["paused": String(isPaused)])
        if isPaused { observer.stop(); dismissRewrite() } else { startObserving() }
        updateMenu()
    }
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String, let value = WorkingMode(rawValue: mode) else { return }
        model.settings.mode = value; model.save()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { model.checkForUpdates() }
    private func showUpdateWindow() {
        if updateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.identifier = .init("sayo.updates")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: AppUpdatePromptView(model: model))
            window.center()
            updateWindow = window
        }
        updateWindow?.title = model.settings.interfaceLanguage.text("Sayo Updates", "Sayo 更新")
        hasOpenWindow = true
        updateDockVisibility()
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            menuItem.title = model.updateActionTitle
            return model.canRequestUpdateCheck
        }
        return true
    }
    private func updateMenu() {
        guard statusItem != nil else { return }
        let language = model.settings.interfaceLanguage
        let menu = NSMenu()
        let heading = NSMenuItem(title: language.text("Sayo · Rewrite in \(model.settings.targetLanguage.promptName)", "Sayo · 目标语言：\(model.settings.targetLanguage.displayName(interfaceLanguage: language))"), action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        menu.addItem(.separator())
        add(menu, title: language.text("Settings…", "设置…"), action: #selector(showSettings), key: ",")
        add(menu, title: language.text("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates))
        add(menu, title: isPaused ? language.text("Resume Sayo", "继续 Sayo") : language.text("Pause Sayo", "暂停 Sayo"), action: #selector(togglePause))
        menu.addItem(.separator())
        if supportsFocusedInput {
        for mode in WorkingMode.allCases {
            let item = add(menu, title: mode.title(language: language), action: #selector(selectMode(_:)))
            item.representedObject = mode.rawValue; item.state = model.settings.mode == mode ? .on : .off
        }
        menu.addItem(.separator())
        }
        add(menu, title: language.text("Welcome tour…", "欢迎引导…"), action: #selector(replayWelcome))
        add(menu, title: language.text("Quit Sayo", "退出 Sayo"), action: #selector(quit), key: "q")
        statusItem.menu = menu
    }
    private func makeStatusItemImage(style: StatusBarIconStyle) -> NSImage? {
        switch style {
        case .brand:
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let source = NSImage(contentsOf: url),
               let image = source.copy() as? NSImage {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = false
                image.accessibilityDescription = "Sayo"
                return image
            }
        case .monochrome:
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Sayo")?
                .withSymbolConfiguration(configuration) {
                image.isTemplate = true
                return image
            }
        }
        let fallback = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Sayo")
        fallback?.isTemplate = true
        return fallback
    }
    @discardableResult private func add(_ menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }
    private func makeMainMenu() {
        guard model != nil else { return }
        let language = model.settings.interfaceLanguage
        let menu = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        add(appMenu, title: language.text("Settings…", "设置…"), action: #selector(showSettings), key: ",")
        add(appMenu, title: language.text("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates))
        appMenu.addItem(.separator()); add(appMenu, title: language.text("Quit Sayo", "退出 Sayo"), action: #selector(quit), key: "q")
        let editTitle = language.text("Edit", "编辑")
        let edit = NSMenu(title: editTitle); let editItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        let commands = [(language.text("Undo", "撤销"), "undo:", "z"), (language.text("Cut", "剪切"), "cut:", "x"), (language.text("Copy", "复制"), "copy:", "c"), (language.text("Paste", "粘贴"), "paste:", "v"), (language.text("Select All", "全选"), "selectAll:", "a")]
        for (title, action, key) in commands {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        NSApp.mainMenu = menu
    }
    private func localized(_ english: String, _ simplifiedChinese: String) -> String {
        (model?.settings.interfaceLanguage ?? .system).text(english, simplifiedChinese)
    }
    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate(); permissionGuide.close(); observer?.stop(); shortcuts.unregister(); dismissRewrite(); bridge?.stop()
        DiagnosticLog.shared.record("shutdown", fields: ["pid": String(ProcessInfo.processInfo.processIdentifier)])
        _ = try? DiagnosticLog.shared.recentText(limit: 0)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.settings.onboardingCompleted { showSettings() } else { showWelcome() }
        return true
    }
}
