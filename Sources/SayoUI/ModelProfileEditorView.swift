import SwiftUI
import SayoCore

@MainActor public final class ModelProfileEditorSession: ObservableObject {
    public let profileID: String
    public let isNew: Bool
    public let draft: AppViewModel
    @Published public private(set) var errorMessage = ""

    private let parent: AppViewModel
    private var originalConfiguration: LLMConfiguration
    private var originalKey: String
    private var saved = false

    init(parent: AppViewModel, profileID: String, isNew: Bool,
         configuration: LLMConfiguration, apiKey: String) {
        self.parent = parent
        self.profileID = profileID
        self.isNew = isNew
        originalConfiguration = configuration
        originalKey = apiKey
        var settings = parent.settings
        settings.activeModelProfileID = profileID
        settings.llm = configuration
        draft = AppViewModel(settings: settings)
        draft.apiKey = apiKey
        draft.fetchModelsAction = parent.fetchModelsAction
        draft.testConnectionAction = parent.testConnectionAction
        draft.nanoIsConnectedAction = parent.nanoIsConnectedAction
        draft.connectNanoAction = parent.connectNanoAction
    }

    public var hasUnsavedChanges: Bool {
        !saved && (draft.settings.llm != originalConfiguration || draft.apiKey != originalKey)
    }

    @discardableResult public func save() -> Bool {
        var configuration = draft.settings.llm
        if configuration.provider == .chromeNano {
            configuration.baseURL = ""
            configuration.model = "gemini-nano"
            draft.settings.llm = configuration
            draft.apiKey = ""
        }
        guard configuration.provider == .chromeNano || !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = parent.text("Enter the service address and model name before saving.", "请先填写服务地址和模型名称。")
            return false
        }
        guard parent.commitModelProfile(profileID, configuration: configuration, apiKey: draft.apiKey) else {
            errorMessage = parent.notice
            return false
        }
        originalConfiguration = configuration
        originalKey = draft.apiKey
        saved = true
        errorMessage = ""
        return true
    }
}

public struct ModelProfileEditorView: View {
    @ObservedObject var session: ModelProfileEditorSession
    @ObservedObject private var draft: AppViewModel
    @State private var showingNanoDetails = false
    let onSaved: () -> Void
    let onCancel: () -> Void

    public init(session: ModelProfileEditorSession, onSaved: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.session = session
        _draft = ObservedObject(wrappedValue: session.draft)
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    @State private var showingModelNames = false
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ProviderBadge(provider: draft.settings.llm.provider, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.isNew ? t("Add service", "添加服务") : t("Edit service", "编辑服务"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(providerName)
                        .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                }
                Spacer()
                if let website = draft.settings.llm.provider.homepageURL {
                    Link(destination: website) {
                        Label(t("Official website", "官方网站"), systemImage: "arrow.up.right")
                            .font(.system(size: 12))
                    }
                }
            }.padding(26)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SayoCard(spacing: 22) {
                        if draft.settings.llm.provider == .chromeNano {
                            nanoIntroduction
                        } else {
                            field(t("Connection type", "连接类型")) {
                                VStack(alignment: .leading, spacing: 9) {
                                    SayoSegmentedControl(title: t("Connection type", "连接类型"),
                                        options: ModelAPIFormat.allCases, selection: Binding(
                                        get: { draft.settings.llm.resolvedAPIFormat },
                                        set: { draft.settings.llm.apiFormat = $0 }
                                    ), label: { $0.displayName })
                                    .accessibilityIdentifier("editor-api-format")
                                    Text(formatDescription).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            field(t("Service address", "服务地址")) {
                                TextField(draft.settings.llm.provider == .custom
                                    ? "https://api.example.com/v1" : draft.settings.llm.provider.defaultBaseURL,
                                    text: $draft.settings.llm.baseURL)
                                    .accessibilityIdentifier("editor-base-url")
                            }
                            field(t("Service key", "服务密钥")) {
                                VStack(alignment: .leading, spacing: 7) {
                                    SecureField("sk-…", text: $draft.apiKey)
                                        .accessibilityIdentifier("editor-api-key")
                                    Text(t("Your key is saved in this Mac's Keychain.", "密钥保存在本机系统钥匙串。"))
                                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                }
                            }
                            field(t("Model name", "模型名称")) {
                                VStack(alignment: .leading, spacing: 9) {
                                    TextField(t("Enter the model name", "填写模型名称"), text: $draft.settings.llm.model)
                                        .accessibilityIdentifier("editor-model-name")
                                    HStack(spacing: 8) {
                                        if !draft.availableModels.isEmpty {
                                            Button { showingModelNames = true } label: {
                                                Label(t("Choose model", "选择模型"), systemImage: "list.bullet")
                                            }
                                            .popover(isPresented: $showingModelNames) {
                                                ModelNamePickerView(names: draft.availableModels,
                                                                    language: draft.settings.interfaceLanguage,
                                                                    selected: draft.settings.llm.model,
                                                                    showsTitle: false) { name in
                                                    draft.settings.llm.model = name
                                                    showingModelNames = false
                                                }
                                            }
                                        }
                                        Button { draft.refreshModels() } label: {
                                            Label(t("Refresh", "刷新列表"), systemImage: "arrow.clockwise")
                                        }.disabled(draft.loadingModels)
                                        if draft.loadingModels { ProgressView().controlSize(.small) }
                                        Spacer(minLength: 0)
                                    }
                                    if !draft.modelListResult.isEmpty {
                                        Text(draft.modelListResult).font(.system(size: 11))
                                            .foregroundStyle(draft.modelListSucceeded ? SayoStyle.muted : Color.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let recommendation = draft.settings.llm.provider.recommendedModel {
                                        Text(t("Recommended: \(recommendation)", "推荐：\(recommendation)"))
                                            .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                    }
                                }
                            }
                        }
                    }
                    SayoCard { ModelConnectionTestView(model: draft) }
                    if !session.errorMessage.isEmpty {
                        Label(session.errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .accessibilityIdentifier("editor-save-error")
                    }
                }
                .padding(.horizontal, 26).padding(.bottom, 24)
            }
            Divider()
            HStack(spacing: 10) {
                Text(t("Use this service as soon as you save it.", "保存后，立即使用此服务。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Spacer()
                Button(t("Cancel", "取消"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(t("Save service", "保存服务")) {
                    if session.save() { onSaved() }
                }
                .buttonStyle(SayoButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("save-model-profile")
            }.padding(.horizontal, 26).padding(.vertical, 16)
        }
        .frame(minWidth: 580, minHeight: 590)
        .textFieldStyle(SayoFieldStyle())
        .buttonStyle(SayoButtonStyle())
        .background(SayoStyle.paper)
        .foregroundStyle(SayoStyle.ink)
        .tint(SayoStyle.accent)
        .preferredColorScheme(.light)
        .onChange(of: draft.settings.llm.baseURL) { _, _ in draft.modelConnectionDetailsChanged() }
        .onChange(of: draft.apiKey) { _, _ in draft.modelConnectionDetailsChanged() }
        .onChange(of: draft.settings.llm.model) { _, _ in draft.connectionConfigurationChanged() }
        .onChange(of: draft.settings.llm.apiFormat) { _, _ in draft.modelConnectionDetailsChanged() }
        .onAppear {
            if draft.settings.llm.provider != .chromeNano { draft.refreshModelsIfConfigured() }
        }
    }

    private var formatDescription: String {
        switch draft.settings.llm.resolvedAPIFormat {
        case .chatCompletions: return t("Chat Completions\nFor most services compatible with OpenAI.", "Chat Completions\n适用于多数兼容 OpenAI 的服务。")
        case .responses: return t("For services that provide OpenAI Responses.", "适用于提供 Responses 的服务。")
        case .anthropic: return t("Messages\nFor Claude and services compatible with Anthropic.", "Messages\n适用于 Claude 及兼容服务。")
        case .gemini: return t("GenerateContent\nFor services compatible with Google Gemini.", "GenerateContent\n适用于兼容 Gemini 的服务。")
        }
    }
    private var providerName: String {
        switch draft.settings.llm.provider {
        case .custom: return t("Custom model", "自定义模型")
        case .localModel: return t("Local model", "本地模型")
        case .chromeNano: return t("Gemini Nano · Chrome local", "Gemini Nano · Chrome 本地")
        default: return draft.settings.llm.provider.displayName
        }
    }

    private var nanoIntroduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t("On this Mac", "本机处理"), systemImage: "desktopcomputer")
                .font(.system(size: 14, weight: .medium))
            Text(t("Provided by Google. Downloaded and managed by Chrome.", "由谷歌提供，浏览器下载和管理。"))
            Text(t("Chrome processes your text on this Mac.\nConnecting opens a local page.\nKeep it open while you use this service.", "文字由本机浏览器处理。\n连接时会打开一个页面。\n使用期间，请保持页面开启。"))
            Text(t("Supported languages: English, Japanese, and Spanish.\nGerman and French are also supported.\nChinese and other languages are experimental.\nResults may be incomplete or inaccurate.", "正式支持英语、日语、西班牙语。\n也支持德语和法语。\n中文等其他语言仍在试用。\n结果可能不完整或不准确。"))
                .foregroundStyle(SayoStyle.ink)
                .accessibilityIdentifier("nano-language-limits")
            DisclosureGroup(t("How to use it", "使用说明"),
                            isExpanded: $showingNanoDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    nanoDetail(t("Where it comes from", "下载来源"),
                               t("Chrome may have already downloaded it.\nSome Macs need to download it first.\nThe component is named:\nOptimization Guide On Device Model", "浏览器可能已经下载了它。\n部分电脑需要先下载。\n下载组件名称：\nOptimization Guide On Device Model"))
                    nanoDetail(t("Where your text goes", "文字去向"),
                               t("Your text is processed only on this Mac.\nDownloads and updates still need an internet connection.", "文字只在本机处理。\n下载和更新仍需联网。"))
                    nanoDetail(t("Connection steps", "连接步骤"),
                               t("You do not need to build a website.\nClick Connect model on the page that opens.\nReturn here and click Test connection.\nReconnect if the page, Chrome, or Sayo closes.", "无需自己搭建网页。\n在打开的页面点击“连接模型”。\n返回此处，点击“测试连接”。\n页面或应用关闭后，需重新连接。"))
                    nanoDetail(t("Requirements", "使用条件"),
                               t("Requires Chrome 148 or later.\nYour hardware, free space, and browser settings must support it.\nThe first download may be several GB.\nSpeed and text length depend on the device and model.\nTest the connection to check availability.", "需要 Chrome 148 或更高版本。\n设备、空间和浏览器设置需符合要求。\n首次下载可能占用数 GB。\n速度和文字长度受设备限制。\n请先测试是否可用。"))
                }
                .padding(.top, 8)
            }
            .accessibilityIdentifier("nano-model-details")
        }
        .font(.system(size: 12))
        .foregroundStyle(SayoStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func nanoDetail(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium).foregroundStyle(SayoStyle.ink)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label).font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                .frame(width: 72, alignment: .trailing).padding(.top, 9)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func t(_ english: String, _ chinese: String) -> String {
        draft.text(english, chinese)
    }
}
