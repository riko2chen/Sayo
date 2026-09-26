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
            errorMessage = parent.text("Enter a Base URL and model name before saving.",
                                       "保存前请填写 Base URL 和模型名称。")
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
                    Text(session.isNew ? t("Add model", "新增模型") : t("Edit model", "编辑模型"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(providerName)
                        .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                }
                Spacer()
                if let website = draft.settings.llm.provider.homepageURL {
                    Link(destination: website) {
                        Label(t("Website", "官网"), systemImage: "arrow.up.right")
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
                            field(t("API format", "API 格式")) {
                                VStack(alignment: .leading, spacing: 9) {
                                    SayoSegmentedControl(title: t("API format", "API 格式"),
                                        options: ModelAPIFormat.allCases, selection: Binding(
                                        get: { draft.settings.llm.resolvedAPIFormat },
                                        set: { draft.settings.llm.apiFormat = $0 }
                                    ), label: { $0.displayName })
                                    .accessibilityIdentifier("editor-api-format")
                                    Text(formatDescription).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            field("Base URL") {
                                TextField(draft.settings.llm.provider == .custom
                                    ? "https://api.example.com/v1" : draft.settings.llm.provider.defaultBaseURL,
                                    text: $draft.settings.llm.baseURL)
                                    .accessibilityIdentifier("editor-base-url")
                            }
                            field("API Key") {
                                VStack(alignment: .leading, spacing: 7) {
                                    SecureField("sk-…", text: $draft.apiKey)
                                        .accessibilityIdentifier("editor-api-key")
                                    Text(t("Saved securely in this Mac's Keychain.", "密钥安全保存在本机的 macOS 钥匙串中。"))
                                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                }
                            }
                            field(t("Model", "模型")) {
                                VStack(alignment: .leading, spacing: 9) {
                                    TextField(t("Enter a model name", "输入模型名称"), text: $draft.settings.llm.model)
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
                Text(t("Use this model after saving.", "保存后使用此模型。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Spacer()
                Button(t("Cancel", "取消"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(t("Save model", "保存模型")) {
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
        case .chatCompletions: return t("Chat Completions · Supported by most compatible services.", "Chat Completions · 适用于大多数兼容 OpenAI 的服务。")
        case .responses: return t("Responses · For services using the OpenAI Responses API.", "适用于提供 OpenAI Responses 接口的服务。")
        case .anthropic: return t("Messages · For Claude and Anthropic-compatible services.", "Messages · 适用于 Claude 及兼容 Anthropic 的服务。")
        case .gemini: return t("GenerateContent · For Google Gemini-compatible services.", "GenerateContent · 适用于兼容 Google Gemini 的服务。")
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
            Label(t("On-device AI · No API key", "本地 AI · 无需 API Key"), systemImage: "desktopcomputer")
                .font(.system(size: 14, weight: .medium))
            Text(t("Gemini Nano is Google's small AI model, downloaded and managed by Chrome for its built-in AI features.",
                   "Gemini Nano 是 Google 的轻量 AI 模型，由 Chrome 下载和管理，供浏览器内置 AI 功能使用。"))
            Text(t("Sayo processes your text on this Mac through Chrome. Connecting opens an extra local Chrome page; keep it open while using the model.",
                   "Sayo 通过 Chrome 在本机处理文本。连接时会额外打开一个 Chrome 本机页面，使用期间需保持开启。"))
            Text(t("Official input and output languages: English, Japanese, Spanish, German and French. Sayo also allows Chinese and other languages as experimental use; translations may be incomplete or inaccurate.",
                   "官方支持的输入和输出语言：英语、日语、西班牙语、德语、法语。中文等其他语言可作为实验性功能使用，Sayo 不作语言限制，但翻译可能不完整或不准确。"))
                .foregroundStyle(SayoStyle.ink)
                .accessibilityIdentifier("nano-language-limits")
            DisclosureGroup(t("More about the model and connection", "模型来源、连接方式与限制"),
                            isExpanded: $showingNanoDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    nanoDetail(t("Why is it on my Mac?", "为什么电脑上会有？"),
                               t("Chrome's AI features may have already downloaded it as “Optimization Guide On Device Model”. Sayo reuses the model through Chrome; not every Mac has it installed.",
                                 "Chrome 的 AI 功能可能已下载它，对应组件名为「Optimization Guide On Device Model」。Sayo 会通过 Chrome 复用它，并非每台电脑都已安装。"))
                    nanoDetail(t("What stays local?", "是否完全本地处理？"),
                               t("This connection sends text only to Chrome on this Mac and returns the result to Sayo. It does not call a cloud model. Chrome still needs internet access to download or update the model.",
                                 "此连接只把文本交给本机 Chrome 推理，再将结果传回 Sayo，不调用云端模型。模型下载和更新仍需由 Chrome 联网完成。"))
                    nanoDetail(t("Do I need to build a website?", "需要自己搭建网页吗？"),
                               t("No. Sayo temporarily provides the local connection page; nothing needs to be hosted or published. Click Connect model on that page, then return here to test. Reconnect if the tab or Chrome closes, or Sayo restarts.",
                                 "不需要。连接页由 Sayo 临时在本机提供，无需搭建或发布网站。在页面点击「连接模型」，再回到这里测试。关闭标签页、退出 Chrome 或重启 Sayo 后需重新连接。"))
                    nanoDetail(t("Other limits", "还有哪些限制？"),
                               t("Requires Chrome 148 or later and compatible hardware, free space and browser policies. The first connection may download several GB. Speed and text length are limited by the device and model. Test the connection to check availability.",
                                 "需要 Chrome 148 或更高版本，并满足硬件、可用空间和浏览器策略要求。首次连接可能下载数 GB；处理速度和文本长度受设备及模型限制。请通过测试连接检查可用性。"))
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
