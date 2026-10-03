import SwiftUI
import AppKit
import SayoCore

public struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @State private var page: SettingsPage = .general
    @State private var promptDestination: TranslationDestination = .primary
    public init(model: AppViewModel) { self.model = model }
    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(page.title(language: model.settings.interfaceLanguage)).font(.system(size: 25, weight: .semibold))
                        Text(page.subtitle(language: model.settings.interfaceLanguage))
                            .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                    }
                    Spacer()
                    AppUpdateStatusButton(model: model)
                }.padding(.horizontal, 30).padding(.top, 27).padding(.bottom, 22)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .general: general
                        case .model: ModelConfigurationView(model: model)
                        case .rewriting: rewriting
                        case .shortcuts: shortcuts
                        case .appAccess: appAccess
                        case .terminal: terminal
                        case .diagnostics: diagnostics
                        case .about: about
                        }
                    }.frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30).padding(.bottom, 28)
                }
                Divider().opacity(0.45)
                HStack {
                    Text(model.notice)
                        .font(.system(size: 11)).foregroundStyle(model.noticeIsError ? .red : SayoStyle.muted)
                        .lineLimit(2).textSelection(.enabled)
                    Spacer()
                    saveStatus
                }.padding(.horizontal, 30).padding(.vertical, 10)
            }.frame(maxWidth: .infinity)
        }.frame(minWidth: 880, minHeight: 650).background(SayoStyle.paper)
            .foregroundStyle(SayoStyle.ink).tint(SayoStyle.accent).preferredColorScheme(.light)
            .buttonStyle(SayoButtonStyle())
            .toggleStyle(.switch).controlSize(.small)
            .onAppear { model.refreshAction?() }
            .onChange(of: model.settings) { oldValue, newValue in
                if oldValue != newValue { model.scheduleAutoSave() }
            }
            .onChange(of: model.apiKey) { oldValue, newValue in
                if oldValue != newValue { model.scheduleAutoSave() }
            }
            .onChange(of: model.settings.developerMode) { _, enabled in
                if !enabled && page.requiresDeveloperMode { page = .general }
            }
            .onChange(of: model.features) { _, features in
                if !page.requiresDeveloperMode && !SettingsPage.standardPages(for: features).contains(page) { page = .general }
            }
    }
    @ViewBuilder private var saveStatus: some View {
        HStack(spacing: 6) {
            switch model.settingsSaveState {
            case .saving:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text(t("Saving", "保存中"))
            case .saved:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text(t("Saved", "保存完毕"))
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .medium))
                Text(t("Save failed", "保存失败"))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(model.settingsSaveState == .failed ? Color.red : SayoStyle.muted)
        .accessibilityElement(children: .combine)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SayoMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sayo").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(t("A little clarity.", "让表达更清晰")).font(.system(size: 10)).foregroundStyle(SayoStyle.muted)
                }
            }
            .padding(.horizontal, 21).padding(.top, 24).padding(.bottom, 30)
            sidebarLabel(t("WORKSPACE", "工作区"))
            ForEach(SettingsPage.standardPages(for: model.features).filter { [.general, .model, .rewriting].contains($0) }) { item in
                sidebarButton(item)
            }
            sidebarLabel(t("TOOLS", "工具")).padding(.top, 20)
            ForEach(SettingsPage.standardPages(for: model.features).filter { [.shortcuts, .appAccess, .terminal].contains($0) }) { item in
                sidebarButton(item)
            }
            Spacer(minLength: 24)
            sidebarButton(.about)
            if model.settings.developerMode {
                ForEach(SettingsPage.developerPages) { item in
                    sidebarButton(item)
                }
            }
            Divider().padding(.horizontal, 20).padding(.top, 10)
            Group {
                if model.accessibilityGranted {
                    accessibilityStatus
                } else {
                    Button { model.permissionAction?() } label: { accessibilityStatus }
                        .buttonStyle(.plain)
                        .help(t("Enable Accessibility…", "启用辅助功能…"))
                }
            }.font(.system(size: 10, weight: .medium)).padding(20)
        }.frame(width: 190).background(SayoStyle.field.opacity(0.65))
            .overlay(alignment: .trailing) { Rectangle().fill(SayoStyle.line).frame(width: 1) }
    }
    private func sidebarLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(SayoStyle.muted)
            .padding(.horizontal, 25).padding(.bottom, 9)
    }
    private var accessibilityStatus: some View {
        HStack(spacing: 7) {
            Circle().fill(model.accessibilityGranted ? SayoStyle.green : Color.orange).frame(width: 6, height: 6)
            Text(model.accessibilityGranted ? t("Accessibility enabled", "辅助功能已启用") : t("Accessibility disabled", "辅助功能未启用"))
        }.contentShape(Rectangle())
    }
    private func sidebarButton(_ item: SettingsPage) -> some View {
        Button { page = item; model.notice = "" } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 19)
                    .foregroundStyle(page == item ? SayoStyle.accent : SayoStyle.muted)
                Text(item.title(language: model.settings.interfaceLanguage))
                    .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                    // Long translations must wrap within the sidebar instead of widening its content.
                    .lineLimit(2).minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
                .background(page == item ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(page == item ? SayoStyle.line.opacity(0.7) : .clear))
                .shadow(color: .black.opacity(page == item ? 0.035 : 0), radius: 3, y: 1)
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
    }
    private var general: some View {
        Group {
            if model.supportsFocusedInput && !model.accessibilityGranted {
                SayoCard {
                    SayoSettingRow(title: t("Let Sayo work where you type", "让 Sayo 在你输入的地方工作"),
                                   detail: t("Accessibility lets Sayo read and replace the active input.", "开启辅助功能权限，即可读取并替换当前输入框内容。")) {
                        Button(t("Enable…", "启用…")) { model.permissionAction?() }
                            .buttonStyle(SayoButtonStyle(prominent: true))
                    }
                }
            }
            SayoCard {
                sectionLabel(t("Languages", "语言"))
                SayoSettingRow(title: t("Interface language", "界面语言"), detail: t("The language Sayo speaks to you.", "Sayo 界面的显示语言。")) {
                    Picker("", selection: $model.settings.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }.labelsHidden().frame(width: 180)
                        .accessibilityLabel(t("Interface language", "界面语言"))
                }
                Divider()
                SayoSettingRow(title: t("First language", "第一语言"), detail: t("Your default translation destination.", "日常翻译与改写使用的目标语言。")) {
                    Picker("", selection: $model.settings.targetLanguage) {
                        ForEach(TargetLanguage.allCases, id: \.self) { language in
                            Text(model.targetLanguageName(language)).tag(language)
                        }
                    }.labelsHidden().frame(width: 180)
                        .accessibilityLabel(t("First language", "第一语言"))
                }
                if model.supportsFocusedInput {
                    Divider()
                    SayoSettingRow(title: t("Second language", "第二语言"), detail: t("Use a separate shortcut to translate into this language.", "通过独立快捷键，快速翻译为另一种语言。")) {
                        Picker("", selection: $model.settings.secondaryTargetLanguage) {
                            ForEach(TargetLanguage.allCases, id: \.self) { language in
                                Text(model.targetLanguageName(language)).tag(language)
                            }
                        }.labelsHidden().frame(width: 180)
                            .accessibilityLabel(t("Second language", "第二语言"))
                    }
                    HStack(spacing: 6) {
                        let shortcut = model.settings.secondaryShortcut?.displayLabel(language: model.settings.interfaceLanguage) ?? t("Not set", "未设置")
                        Image(systemName: "keyboard")
                        Text(t("Second-language shortcut: \(shortcut)", "第二语言快捷键：\(shortcut)"))
                        Spacer()
                        pageLink(t("Set shortcut", "设置快捷键"), to: .shortcuts)
                    }
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                    .padding(11).background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            SayoCard {
                sectionLabel(t("App behavior", "应用行为"))
                toggleRow(t("Open Sayo at login", "登录时启动 Sayo"), isOn: $model.settings.launchAtLogin,
                          detail: t("Ready whenever you start writing.", "每次打开电脑，即可开始使用。"))
                Divider()
                SayoSettingRow(title: t("Status bar icon", "状态栏图标"),
                               detail: t("Monochrome adapts to your menu bar appearance.", "单色图标会自动适应菜单栏的深浅外观。")) {
                    Picker("", selection: $model.settings.statusBarIconStyle) {
                        Text(t("Chameleon", "变色龙")).tag(StatusBarIconStyle.brand)
                        Text(t("Monochrome", "单色（macOS）")).tag(StatusBarIconStyle.monochrome)
                    }.labelsHidden().frame(width: 145)
                        .accessibilityLabel(t("Status bar icon", "状态栏图标"))
                    StatusIconPreview(style: $model.settings.statusBarIconStyle).frame(width: 44, height: 44)
                }
            }
            SayoCard {
                DisclosureGroup(t("Advanced settings", "高级设置")) {
                    VStack(alignment: .leading, spacing: 16) {
                        SayoSettingRow(title: t("Settings file", "配置文件")) {
                            Button(t("Show in Finder", "在 Finder 中显示")) { model.openConfigAction?() }
                        }
                        Text(model.configPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(SayoStyle.muted)
                        Text(t("API keys stay in macOS Keychain. To migrate, quit Sayo, copy this file to the same location, reopen Sayo, and re-enter API keys on a new Mac.",
                               "API Key 单独保存在 macOS 钥匙串中。迁移时先退出 Sayo，将此文件复制到相同位置后重新启动，并在新 Mac 上重新填写 API Key。"))
                            .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                        Divider()
                        toggleRow(t("Developer mode", "开发者模式"), isOn: $model.settings.developerMode,
                                  detail: t("Show Quick Troubleshooting in the sidebar.", "在侧栏显示快速排查。"))
                        Divider()
                        Button(t("Replay welcome tour", "重新查看欢迎引导")) { model.showOnboardingAction?() }
                    }.padding(.top, 16)
                }
                .font(.system(size: 13, weight: .medium))
            }
        }
    }
    private var rewriting: some View {
        Group {
            if model.supportsFocusedInput {
            SayoCard {
                sectionLabel(t("WORKING MODE", "工作模式"))
                HStack(spacing: 10) {
                    ForEach(WorkingMode.allCases, id: \.self) { mode in
                        Button { model.changeWorkingMode(mode) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: mode.symbol).font(.system(size: 18))
                                    Spacer()
                                    Image(systemName: model.settings.mode == mode ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13)).opacity(model.settings.mode == mode ? 1 : 0.25)
                                }
                                Text(mode.title(language: model.settings.interfaceLanguage)).font(.system(size: 13, weight: .semibold))
                                Text(mode.detail(language: model.settings.interfaceLanguage)).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32, alignment: .top)
                            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.settings.mode == mode ? SayoStyle.accent.opacity(0.055) : SayoStyle.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(model.settings.mode == mode ? SayoStyle.accent.opacity(0.4) : SayoStyle.line))
                        }.buttonStyle(.plain)
                    }
                }
            }
            }
            SayoCard {
                sectionLabel(t("PROMPT", "提示词"))
                if model.supportsFocusedInput {
                    SayoSegmentedControl(title: t("Translation prompt", "翻译提示词"),
                        options: [TranslationDestination.primary, .secondary], selection: $promptDestination) {
                            $0 == .primary ? t("First language", "第一语言") : t("Second language", "第二语言")
                        }.frame(width: 240)
                }
                HStack(spacing: 6) {
                    let language = model.targetLanguageName(selectedPromptLanguage)
                    Text(t("Target: \(language). ${targetLanguage} in the prompt is replaced with it.",
                           "目标语言：\(language)。提示词中的 ${targetLanguage} 会替换为该语言。"))
                    pageLink(t("Change in General", "在“通用”中更改"), to: .general)
                }.font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                TextEditor(text: selectedPrompt).font(.system(size: 13, design: .monospaced))
                    .lineSpacing(5).scrollContentBackground(.hidden).padding(12).frame(height: 270)
                    .background(SayoStyle.paper, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(promptDestination == .primary ? t("First-language prompt", "第一语言提示词") : t("Second-language prompt", "第二语言提示词"))
                HStack {
                    Text(t("Keep “return only the final text” for clean replacements.", "建议要求模型只返回最终文本。")) .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                    Spacer()
                    if promptDestination == .secondary {
                        Button(t("Copy first prompt", "复制第一语言提示词")) { model.settings.secondaryPrompt = model.settings.prompt }
                    }
                    Button(t("Restore default", "恢复默认")) { selectedPrompt.wrappedValue = AppSettings.defaultPrompt }
                }
                DisclosureGroup(t("Effective prompt preview", "实际提示词预览")) {
                    Text(model.settings.effectivePrompt(for: promptDestination))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            if model.supportsFocusedInput {
            SayoCard {
                sectionLabel(t("REPLACEMENT", "替换方式"))
                toggleRow(t("Character-by-character replacement", "逐字替换动画"), isOn: $model.settings.inputAnimationEnabled, detail: t(
                    "Reveal whole-input replacements gradually in supported apps. Selected text and terminal drafts are replaced instantly. Respects macOS Reduce Motion.",
                    "在支持的应用中逐字显示整段替换结果。选区和终端草稿仍一次性回填，并遵循 macOS 的“减少动态效果”设置。"
                ))
                Divider()
                toggleRow(t("Copy/Paste compatibility fallback", "复制/粘贴兼容模式"), isOn: $model.settings.copyPasteCompatibilityEnabled, detail: t(
                    "For apps whose input cannot be read normally. An explicit shortcut copies the current selection, then pastes the rewrite back after checking the app and window.",
                    "用于无法正常读取输入框的应用。快捷键会复制当前选区，并在核对应用和窗口后粘贴改写结果。"
                ))
            }
            }
        }
    }
    private var selectedPrompt: Binding<String> {
        promptDestination == .primary ? $model.settings.prompt : $model.settings.secondaryPrompt
    }
    private var selectedPromptLanguage: TargetLanguage { model.settings.targetLanguage(for: promptDestination) }
    private var shortcuts: some View {
        SayoCard {
            HStack(spacing: 6) {
                let mode = model.settings.mode.title(language: model.settings.interfaceLanguage)
                Text(t("Available actions follow the working mode: \(mode).", "可用操作随工作模式变化，当前为“\(mode)”。"))
                pageLink(t("Change", "更改"), to: .rewriting)
            }.font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            if model.settings.mode.showsInvokeShortcut {
                Divider()
                shortcutRow(t("Invoke Sayo", "唤起 Sayo"), shortcut: $model.settings.invokeShortcut)
            }
            if model.settings.mode.showsCopyShortcut {
                Divider()
                shortcutRow(t("Copy result", "复制结果"), shortcut: $model.settings.copyShortcut)
            }
            Divider()
            shortcutRow(
                model.settings.mode == .silent ? t("Rewrite and replace", "改写并替换") : t("Replace result", "替换结果"),
                shortcut: $model.settings.replaceShortcut
            )
            Divider()
            shortcutRow(t("Translate to second language", "翻译为第二语言"), shortcut: $model.settings.secondaryShortcut)
            Text(t("Unset by default. Only this shortcut starts a second-language translation; it follows the working mode.", "默认未设置。仅此快捷键可触发第二语言翻译，并遵循工作模式。"))
                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
        }
    }
    private var appAccess: some View {
        SayoCard {
            ApplicationFilterSettingsView(
                mode: $model.settings.applicationFilterMode,
                selectedBundleIDs: $model.settings.applicationBundleIDs,
                language: model.settings.interfaceLanguage
            )
        }
    }
    /// Inline jump for settings that are related but live on another page.
    private func pageLink(_ title: String, to target: SettingsPage) -> some View {
        Button(title) { page = target; model.notice = "" }
            .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(SayoStyle.accent)
    }
    private func toggleRow(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        SayoSettingRow(title: title, detail: detail) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }
    private var terminal: some View {
        Group {
            SayoCard {
                sectionLabel(t("SHELL INTEGRATION", "Shell 集成"))
                Text(t("Rewrite commands with your Sayo shortcut.", "使用 Sayo 快捷键改写命令。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                ForEach(TerminalShell.allCases) { shell in
                    Divider()
                    terminalIntegrationRow(
                        shell.name,
                        installed: model.terminalInstalled[shell.rawValue] == true,
                        install: { model.installTerminal(shell.rawValue) },
                        reset: { model.uninstallTerminal(shell.rawValue) }
                    )
                }
            }
            SayoCard {
                sectionLabel(t("CLI EDITORS", "CLI 编辑器"))
                Text(t("Install Sayo for each CLI whose drafts you want to rewrite. Restart your terminal after installation for the integration to take effect.",
                       "为需要使用 Sayo 改写草稿的 CLI 安装集成。安装后需要重启终端才能生效。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                ForEach(CLIEditorProgram.allCases, id: \.self) { program in
                    Divider()
                    terminalIntegrationRow(
                        program.name,
                        installed: model.cliEditorInstalled[program.rawValue] == true,
                        install: { model.configureCLIEditor(program.rawValue, install: true) },
                        reset: { model.configureCLIEditor(program.rawValue, install: false) }
                    )
                }
            }
        }.onAppear {
            model.refreshAction?()
            model.loadCLIEditors()
        }
    }
    private func terminalIntegrationRow(_ name: String, installed: Bool,
                                        install: @escaping () -> Void, reset: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(installed ? t("Installed", "已安装") : t("Default behavior", "默认行为"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
            Spacer()
            Button(installed ? t("Reinstall", "重新安装") : t("Install", "安装"), action: install)
                .accessibilityLabel((installed ? t("Reinstall ", "重新安装 ") : t("Install ", "安装 ")) + name)
            if installed {
                Button(t("Reset to default", "恢复默认"), action: reset)
                    .accessibilityLabel(t("Reset ", "恢复 ") + name + t(" to default", " 默认行为"))
            }
        }.padding(.vertical, 5)
    }
    private var about: some View {
        Group {
            SayoCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("Change how you say it,\nnot what you mean.", "改变表达，\n不改变你想表达的。"))
                        .font(.system(size: 28, weight: .semibold))
                        .accessibilityIdentifier("about-slogan")
                    Text(t(
                        "You don't have to learn before you begin writing. You truly learn through the act of writing, again and again.",
                        "你不必先学会，才开始落笔，你会在不断书写的过程中，真正学会。"
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(SayoStyle.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            SayoCard {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel(t("CURRENT VERSION", "当前版本"))
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                        Text(version)
                            .font(.system(size: 22, weight: .semibold))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("about-version")
                    }
                    Spacer(minLength: 8)
                }
            }
            SayoCard {
                sectionLabel(t("UPDATES", "更新"))
                Toggle(t("Automatically download updates", "自动下载更新"), isOn: $model.settings.automaticallyDownloadsUpdates)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("automatically-download-updates")
                Text(t("Download ahead of time. Install when ready, or when you quit Sayo.", "提前下载更新，准备好后可点击更新，或在退出 Sayo 时安装。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Divider()
                Toggle(t("Automatically check for updates", "自动检查更新"), isOn: $model.settings.automaticallyChecksForUpdates)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("automatically-check-updates")
                Text(t("Check when Sayo opens, at most once an hour. Manual checks always run immediately.", "打开 Sayo 时检查，每小时最多自动检查一次。手动检查始终立即执行。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
            SayoCard {
                Text(t("QUESTIONS & ANSWERS", "问与答"))
                    .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                aboutQuestion(
                    t("Where does the icon come from?", "图标的来源？"),
                    answer: t(
                        "The icon is a little chameleon. Among nature's light, shadows, and greenery, it quietly changes its appearance, but it is still a little chameleon.",
                        "图标是一只小变色龙，在大自然的光影和草木之间，它会悄悄改变自己的外表，但这不影响它依然是一只小变色龙"
                    ),
                    identifier: "about-question-icon"
                )
                Divider()
                aboutQuestion(
                    t("How is my data privacy protected?", "我的数据隐私如何保护"),
                    answer: t(
                        "Sayo is open source, and API keys are not saved in its configuration. Text you translate is sent to the model you configure, so that model's privacy policy applies. You can consider a local offline model, such as Chrome's built-in Gemini Nano or Hy-MT2-1.8B; both work well.",
                        "Sayo 是开源的，并且配置里不会保存 API KEY。翻译的内容会发送给用户配置的模型，所以遵循对应模型的隐私政策。可以考虑用本地的离线模型，例如Chrome自带的Gemini Nano，或者 Hy-MT2-1.8B，都有不错的效果。"
                    ),
                    identifier: "about-question-privacy"
                )
                Divider()
                aboutQuestion(
                    t("Does long-term use cost much?", "长期使用这个的话，费用高吗？"),
                    answer: t(
                        "If you choose the qwen-3.7-flash model, one million input tokens cost only ¥0.2, and each translation costs about ¥0.00003. At a normal typing pace, the estimated cost is less than ¥1 per year, making it exceptionally affordable.\n\nIf you want a completely free model whose data never leaves your computer, we recommend downloading the open-source Hy-MT2-1.8B Q4_K_M model. Once running, it uses very little memory and can keep translation times to around one second.",
                        "假设选择的是 qwen-3.7-flash 模型，每百万 token 的输入才0.2元，每次翻译大约花费 0.00003 元，估算下来正常打字使用的话 1 年不到 1 块钱，可以说非常非常划算了。\n\n如果想要完全免费且数据不离开电脑的模型，推荐下载 Hy-MT2-1.8B Q4_K_M 这个开源模型，运行之后很低的内存占用，且翻译速度可以保持在大约1秒内。"
                    ),
                    identifier: "about-question-cost"
                )
            }
            AboutAuthorView(language: model.settings.interfaceLanguage)
        }
    }
    private func aboutQuestion(_ question: String, answer: String, identifier: String) -> some View {
        DisclosureGroup {
            Text(answer)
                .font(.system(size: 12))
                .foregroundStyle(SayoStyle.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            Text(question)
                .font(.system(size: 13, weight: .medium))
        }
        .accessibilityIdentifier(identifier)
        .disclosureGroupStyle(AboutDisclosureStyle())
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SayoStyle.muted)
    }
    private var diagnostics: some View {
        DiagnosticAnalysisView(model: model).task {
            while !Task.isCancelled {
                if NSApp.windows.contains(where: { $0.identifier?.rawValue == "sayo.settings" && $0.isVisible }) {
                    model.refreshDiagnostics()
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func shortcutRow(_ title: String, shortcut: Binding<Shortcut?>) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            ShortcutControls(isSet: shortcut.wrappedValue != nil, label: title,
                             language: model.settings.interfaceLanguage, clear: { shortcut.wrappedValue = nil }) {
                ShortcutRecorder(shortcut: shortcut, language: model.settings.interfaceLanguage, accessibilityLabel: title)
            }
        }
    }
    private func t(_ english: String, _ simplifiedChinese: String) -> String {
        model.text(english, simplifiedChinese)
    }
}

private struct AboutDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SayoStyle.muted)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, model, rewriting, shortcuts, appAccess, terminal, about, diagnostics
    var id: String { rawValue }
    var requiresDeveloperMode: Bool { self == .diagnostics }
    static let developerPages = allCases.filter(\.requiresDeveloperMode)
    /// Keep primary writing controls near the top of the sidebar.
    static func standardPages(for features: Set<AppFeature>) -> [SettingsPage] {
        let order: [SettingsPage] = [.general, .model, .rewriting, .shortcuts, .appAccess, .terminal, .about]
        return order.filter { $0.isAvailable(in: features) }
    }
    func isAvailable(in features: Set<AppFeature>) -> Bool {
        switch self {
        case .shortcuts, .appAccess: return features.contains(.focusedInput)
        case .terminal: return features.contains(.terminalIntegration)
        default: return true
        }
    }

    func title(language: InterfaceLanguage) -> String {
        switch self {
        case .general: return language.text("General", "通用")
        case .model: return language.text("Language Model", "语言模型")
        case .rewriting: return language.text("Rewriting", "改写")
        case .shortcuts: return language.text("Shortcuts", "快捷键")
        case .appAccess: return language.text("App Access", "应用范围")
        case .terminal: return language.text("Terminal", "终端")
        case .about: return language.text("About Sayo", "关于 Sayo")
        case .diagnostics: return language.text("Quick Troubleshooting", "快速排查")
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .model: "cpu"
        case .rewriting: "text.alignleft"
        case .shortcuts: "keyboard"
        case .appAccess: "square.grid.2x2"
        case .terminal: "terminal"
        case .about: "leaf"
        case .diagnostics: "doc.text.magnifyingglass"
        }
    }
    func subtitle(language: InterfaceLanguage) -> String {
        switch self {
        case .general: return language.text("Make Sayo feel at home in your workflow.", "让语言和日常习惯，都按你的方式来。")
        case .model: return language.text("Choose the model behind your words.", "选择你的模型，连接更自然的表达。")
        case .rewriting: return language.text("Fine-tune how your thoughts become words.", "调整改写方式，让每次表达更贴近你的习惯。")
        case .shortcuts: return language.text("Your favorite actions, a keystroke away.", "把常用操作，变成顺手的快捷键。")
        case .appAccess: return language.text("Choose where Sayo lends a hand.", "选择 Sayo 可以帮忙的应用。")
        case .terminal: return language.text("Bring clearer writing to your command line.", "在终端与命令行工具中，继续流畅表达。")
        case .about: return language.text("A small companion for your words.", "一个安静陪伴你表达的小工具。")
        case .diagnostics: return language.text("Connection status and recent activity, in one place.", "查看运行状态，快速定位问题。")
        }
    }
}

struct ModelConfigurationView: View {
    @ObservedObject var model: AppViewModel
    @State private var confirmingDeletion = false
    @State private var showingProviderSwitcher = false
    var showsOnboardingGuide = false
    @State private var showingProviderPicker = false
    @State private var showingModelSwitcher = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsOnboardingGuide { onboardingGuide }
            HStack(spacing: 8) {
                Text(t("\(model.configuredModelProfiles.count) saved models", "\(model.configuredModelProfiles.count) 个已配置模型"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Spacer(minLength: 8)
                Button { showingProviderPicker = true } label: {
                    Label(t("Add provider", "新增供应商"), systemImage: "plus")
                }
                .buttonStyle(SayoButtonStyle(prominent: true))
                .accessibilityIdentifier("add-model-profile")
                .popover(isPresented: $showingProviderPicker, arrowEdge: .bottom) {
                    ModelProfilePickerView(profiles: model.availableModelProfiles,
                                           language: model.settings.interfaceLanguage, adding: true) { profile in
                        showingProviderPicker = false
                        model.openModelEditorAction?(profile.id)
                    }
                }
                Button { model.openModelEditorAction?(model.settings.activeModelProfileID) } label: {
                    Label(t("Edit", "编辑"), systemImage: "pencil")
                }
                .accessibilityIdentifier("edit-model-profile")
                Button(role: .destructive) { confirmingDeletion = true } label: {
                    Label(t("Delete", "删除"), systemImage: "trash")
                }
                .disabled(!model.configuredModelProfiles.contains { $0.id == model.settings.activeModelProfileID })
                .accessibilityIdentifier("delete-model-profile")
            }
            .fixedSize(horizontal: false, vertical: true)
            SayoCard(spacing: 17) {
                Button { showingProviderSwitcher = true } label: {
                    HStack(spacing: 14) {
                        ProviderBadge(provider: model.settings.llm.provider, size: 44)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(t("Current provider", "当前供应商"))
                                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                            Text(currentProfileName).font(.system(size: 19, weight: .semibold))
                        }
                        Spacer(minLength: 8)
                        switchHint(t("Click to switch provider", "点击切换供应商"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("Switch provider", "切换供应商"))
                .accessibilityValue(currentProfileName)
                .accessibilityIdentifier("switch-model-profile")
                .popover(isPresented: $showingProviderSwitcher, arrowEdge: .bottom) {
                    ModelProfilePickerView(profiles: model.configuredModelProfiles,
                                           language: model.settings.interfaceLanguage,
                                           selectedID: model.settings.activeModelProfileID) { profile in
                        model.changeModelProfile(profile.id)
                        showingProviderSwitcher = false
                    }
                }
                Divider()
                Button { openModelSwitcher() } label: {
                    HStack(spacing: 18) {
                        Text(t("Current model", "当前模型"))
                            .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                            .frame(width: 96, alignment: .leading)
                        Text(model.settings.llm.model.isEmpty
                            ? t("No model selected", "尚未选择模型") : model.settings.llm.model)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if canSwitchModel {
                            switchHint(t("Click to switch model", "点击切换模型"))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchModel)
                .accessibilityLabel(t("Switch model", "切换模型"))
                .accessibilityValue(model.settings.llm.model)
                .accessibilityIdentifier("switch-active-model")
                .popover(isPresented: $showingModelSwitcher, arrowEdge: .bottom) {
                    ModelNamePickerView(names: modelChoices,
                                        language: model.settings.interfaceLanguage,
                                        selected: model.settings.llm.model,
                                        status: model.modelListResult,
                                        loading: model.loadingModels) { name in
                        model.changeActiveModel(name)
                        showingModelSwitcher = false
                    }
                }
            }
            .confirmationDialog(t("Delete this model profile?", "删除当前模型配置？"), isPresented: $confirmingDeletion) {
                Button(t("Delete model profile", "删除模型配置"), role: .destructive) {
                    _ = model.deleteModelProfile(model.settings.activeModelProfileID)
                }
            } message: {
                Text(t("Its settings and API key will be removed.", "此配置及其 API Key 将被移除。"))
            }
            SayoCard {
                HStack {
                    Text(t("Connection", "接入信息")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let website = model.settings.llm.provider.homepageURL {
                        Link(destination: website) {
                            Label(t("Provider website", "供应商官网"), systemImage: "arrow.up.right")
                                .font(.system(size: 11))
                        }
                    }
                }
                if model.settings.llm.provider != .chromeNano {
                    detailRow(t("API format", "API 格式"), model.settings.llm.resolvedAPIFormat.displayName)
                    HStack(alignment: .center, spacing: 18) {
                        Text("Base URL").font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                            .frame(width: 96, alignment: .leading)
                        if model.settings.llm.baseURL.isEmpty {
                            Text(t("Not configured", "尚未配置")).font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                        } else {
                            SayoCopyValue(value: model.settings.llm.baseURL, language: model.settings.interfaceLanguage)
                        }
                    }
                    detailRow("API Key", model.apiKey.isEmpty ? t("Not set", "未填写") : t("Stored in Keychain", "已保存至钥匙串"))
                } else {
                    detailRow(t("Connection", "连接方式"), t("On-device in Chrome · No API key", "Chrome 本机推理 · 无需 API Key"))
                }
            }
            SayoCard { ModelConnectionTestView(model: model) }
        }
        .buttonStyle(SayoButtonStyle())
        .onAppear { model.refreshModelsIfConfigured() }
    }
    private var onboardingGuide: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(t("Author's suggestion: start with 千问AI平台", "作者建议：从千问AI平台开始"))
                .font(.system(size: 14, weight: .semibold))
            Text(t("You can also choose another provider or set up a model later.", "也可以选择其他服务商，或稍后再配置模型。"))
                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t("1. Register or sign in.", "1. 注册或登录平台。"))
                Link(t("Open 千问AI平台", "打开千问AI平台"), destination: URL(string: "https://www.qianwenai.com/")!)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t("2. Create an API Key and copy it when it appears.", "2. 创建 API Key，并在生成后立即复制。"))
                Link(t("Get API Key", "获取 API Key"), destination: URL(string: "https://platform.qianwenai.com/home/api-keys")!)
            }
            Text(t("3. Select 千问AI平台 below, paste the key, check the model name, and test the connection.",
                   "3. 在下方选择“千问AI平台”，粘贴 Key、确认模型名称，再测试连接。"))
            Button(t("Select 千问AI平台", "选用千问AI平台")) {
                model.openModelEditorAction?("template:qwen")
            }
                .controlSize(.small)
                .accessibilityIdentifier("select-qwen-onboarding")
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(SayoStyle.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("onboarding-model-guide")
    }
    private func t(_ english: String, _ simplifiedChinese: String) -> String {
        model.text(english, simplifiedChinese)
    }
    private var currentProfileName: String {
        model.configuredModelProfiles.first { $0.id == model.settings.activeModelProfileID }?
            .displayName(language: model.settings.interfaceLanguage)
            ?? model.settings.llm.provider.displayName
    }
    private var canSwitchModel: Bool { model.settings.llm.provider != .chromeNano }
    private var modelChoices: [String] {
        var names = model.availableModels
        if let recommended = model.settings.llm.provider.recommendedModel,
           !names.contains(recommended) {
            names.insert(recommended, at: 0)
        }
        let current = model.settings.llm.model
        if !current.isEmpty, !names.contains(current) {
            names.insert(current, at: 0)
        }
        return names
    }
    private func openModelSwitcher() {
        guard canSwitchModel else { return }
        showingModelSwitcher = true
        if model.availableModels.isEmpty { model.refreshModelsIfConfigured() }
    }
    private func switchHint(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(SayoStyle.muted)
        }
    }
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title).font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                .frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(SayoStyle.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    let language: InterfaceLanguage
    let accessibilityLabel: String
    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton(language: language, accessibilityLabel: accessibilityLabel)
        view.onRecord = { shortcut = $0 }
        view.update(shortcut)
        return view
    }
    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onRecord = { shortcut = $0 }
        nsView.setLanguage(language, accessibilityLabel: accessibilityLabel)
        nsView.update(shortcut)
    }
}

private final class RecorderButton: NSButton {
    var onRecord: ((Shortcut?) -> Void)?
    private var recording = false
    private var value: Shortcut?
    private var language: InterfaceLanguage
    override var acceptsFirstResponder: Bool { true }
    init(language: InterfaceLanguage, accessibilityLabel: String) {
        self.language = language
        super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(record)
        setAccessibilityLabel(accessibilityLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setLanguage(_ language: InterfaceLanguage, accessibilityLabel: String) {
        self.language = language
        setAccessibilityLabel(accessibilityLabel)
        if !recording { updateTitle() }
    }
    func update(_ shortcut: Shortcut?) { value = shortcut; if !recording { updateTitle() } }
    @objc private func record() {
        recording = true
        title = language.text("Press shortcut…", "请按快捷键…")
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; update(value); return }
        if event.keyCode == 51 || event.keyCode == 117 {
            recording = false
            value = nil
            onRecord?(value)
            updateTitle()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            title = language.text("Use ⌘, ⌃ or ⌥", "请使用 ⌘、⌃ 或 ⌥")
            return
        }
        let value = Shortcut(keyCode: UInt32(event.keyCode), command: flags.contains(.command), option: flags.contains(.option), control: flags.contains(.control), shift: flags.contains(.shift))
        recording = false
        self.value = value; onRecord?(value); update(value)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { recording = false; update(value); return super.resignFirstResponder() }
    private func updateTitle() {
        title = value?.displayLabel(language: language) ?? language.text("Not set", "未设置")
    }
}

/// Shared control sizing and clear affordance for global shortcuts.
private struct ShortcutControls<Content: View>: View {
    let isSet: Bool
    let label: String
    let language: InterfaceLanguage
    let clear: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8) {
            content().frame(width: 155, height: 32)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(SayoStyle.muted)
                .disabled(!isSet)
                .accessibilityLabel(language.text("Clear ", "清除 ") + label + language.text(" shortcut", " 快捷键"))
                .help(language.text("Clear shortcut", "清除快捷键"))
        }
    }
}
