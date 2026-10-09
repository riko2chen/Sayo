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
                Text(t("Saved", "已保存"))
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
            sidebarLabel(t("Everyday", "常用设置"))
            ForEach(SettingsPage.standardPages(for: model.features).filter { [.general, .model, .rewriting].contains($0) }) { item in
                sidebarButton(item)
            }
            sidebarLabel(t("Tools", "使用设置")).padding(.top, 20)
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
                        .help(t("Enable access…", "开启权限"))
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
            Text(model.accessibilityGranted ? t("Access enabled", "权限已开") : t("Access needed", "权限未开"))
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
                    SayoSettingRow(title: t("Text access", "输入权限"),
                                   detail: t("Allow Sayo to read and replace text where you type.", "开启后，可读取并替换输入内容。")) {
                        Button(t("Enable access…", "开启权限")) { model.permissionAction?() }
                            .buttonStyle(SayoButtonStyle(prominent: true))
                    }
                }
            }
            SayoCard {
                sectionLabel(t("Languages", "语言"))
                SayoSettingRow(title: t("Interface language", "界面语言"), detail: t("The language used for menus and buttons.", "菜单和按钮使用的语言。")) {
                    Picker("", selection: $model.settings.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }.labelsHidden().frame(width: 180)
                        .accessibilityLabel(t("Interface language", "界面语言"))
                }
                Divider()
                SayoSettingRow(title: t("Main language", "常用语言"), detail: t("Your usual language for translations and rewrites.", "平时翻译和改写成这种语言。")) {
                    Picker("", selection: $model.settings.targetLanguage) {
                        ForEach(TargetLanguage.allCases, id: \.self) { language in
                            Text(model.targetLanguageName(language)).tag(language)
                        }
                    }.labelsHidden().frame(width: 180)
                        .accessibilityLabel(t("Main language", "常用语言"))
                }
                if model.supportsFocusedInput {
                    Divider()
                    SayoSettingRow(title: t("Other language", "另一语言"), detail: t("Use a separate shortcut to translate into this language.", "按专用快捷键，翻译成这种语言。")) {
                        Picker("", selection: $model.settings.secondaryTargetLanguage) {
                            ForEach(TargetLanguage.allCases, id: \.self) { language in
                                Text(model.targetLanguageName(language)).tag(language)
                            }
                        }.labelsHidden().frame(width: 180)
                            .accessibilityLabel(t("Other language", "另一语言"))
                    }
                    HStack(spacing: 6) {
                        let shortcut = model.settings.secondaryShortcut?.displayLabel(language: model.settings.interfaceLanguage) ?? t("Not set", "未设置")
                        Image(systemName: "keyboard")
                        Text(t("Other-language shortcut: \(shortcut)", "专用快捷键：\(shortcut)"))
                        Spacer()
                        pageLink(t("Set shortcut", "设置按键"), to: .shortcuts)
                    }
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                    .padding(11).background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            SayoCard {
                sectionLabel(t("Startup and appearance", "启动外观"))
                toggleRow(t("Open at login", "登录启动"), isOn: $model.settings.launchAtLogin,
                          detail: t("Start Sayo when you log in to your Mac.", "登录电脑后，自动启动。"))
                Divider()
                SayoSettingRow(title: t("Menu bar icon", "菜单图标"),
                               detail: t("The monochrome icon follows your menu bar's appearance.", "单色图标随菜单栏深浅变化。")) {
                    Picker("", selection: $model.settings.statusBarIconStyle) {
                        Text(t("Chameleon", "变色龙")).tag(StatusBarIconStyle.brand)
                        Text(t("Monochrome", "单色")).tag(StatusBarIconStyle.monochrome)
                    }.labelsHidden().frame(width: 145)
                        .accessibilityLabel(t("Menu bar icon", "菜单图标"))
                    StatusIconPreview(style: $model.settings.statusBarIconStyle).frame(width: 44, height: 44)
                }
            }
            SayoCard {
                DisclosureGroup(t("More settings", "更多设置")) {
                    VStack(alignment: .leading, spacing: 16) {
                        SayoSettingRow(title: t("Settings file", "设置文件")) {
                            Button(t("Show in Finder", "打开位置")) { model.openConfigAction?() }
                        }
                        Text(model.configPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(SayoStyle.muted)
                        Text(t("Keys are stored separately in Keychain.\nTo move your settings, quit Sayo first.\nCopy this file to the same location on your new Mac.\nReopen Sayo and enter your keys again.", "密钥单独保存在系统钥匙串。\n换电脑前，请先退出应用。\n将设置文件复制到相同位置。\n重新启动后，再填写密钥。"))
                            .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                        Divider()
                        toggleRow(t("Troubleshooting tools", "排查工具"), isOn: $model.settings.developerMode,
                                  detail: t("Show Troubleshooting in the sidebar.", "在侧栏显示“问题排查”。"))
                        Divider()
                        Button(t("Getting started", "使用入门")) { model.showOnboardingAction?() }
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
                sectionLabel(t("How to rewrite", "操作方式"))
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
                sectionLabel(t("Rewrite instructions", "改写要求"))
                if model.supportsFocusedInput {
                    SayoSegmentedControl(title: t("Rewrite instructions", "改写要求"),
                        options: [TranslationDestination.primary, .secondary], selection: $promptDestination) {
                            $0 == .primary ? t("Main language", "常用语言") : t("Other language", "另一语言")
                        }.frame(width: 240)
                }
                HStack(spacing: 6) {
                    let language = model.targetLanguageName(selectedPromptLanguage)
                    Text(t("Rewrite in: \(language).\nThe language marker becomes your selected language.\nLanguage marker: ${targetLanguage}", "改写成：\(language)。\n语言标记会自动换成所选语言。\n语言标记：${targetLanguage}"))
                    pageLink(t("Change language", "更改语言"), to: .general)
                }.font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                TextEditor(text: selectedPrompt).font(.system(size: 13, design: .monospaced))
                    .lineSpacing(5).scrollContentBackground(.hidden).padding(12).frame(height: 270)
                    .background(SayoStyle.paper, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(promptDestination == .primary ? t("Main-language instructions", "常用要求") : t("Other-language instructions", "另一要求"))
                HStack {
                    Text(t("Ask for only the rewritten text, with no explanation.", "建议注明：只返回改写后的文字。")) .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                    Spacer()
                    if promptDestination == .secondary {
                        Button(t("Copy main instructions", "复制要求")) { model.settings.secondaryPrompt = model.settings.prompt }
                    }
                    Button(t("Restore default", "恢复默认")) { selectedPrompt.wrappedValue = AppSettings.defaultPrompt }
                }
                DisclosureGroup(t("View full instructions", "查看全文")) {
                    Text(model.settings.effectivePrompt(for: promptDestination))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            if model.supportsFocusedInput {
            SayoCard {
                sectionLabel(t("REPLACEMENT", "替换方式"))
                toggleRow(t("Show text gradually", "逐字显示"), isOn: $model.settings.inputAnimationEnabled, detail: t(
                    "Show whole-input replacements gradually where supported.\nSelected text and terminal drafts are replaced at once.\nFollows the macOS Reduce Motion setting.", "支持时，整段结果逐字显示。\n选中文字和终端草稿直接替换。\n跟随系统“减少动态效果”设置。"
                ))
                Divider()
                toggleRow(t("Use copy and paste", "复制粘贴"), isOn: $model.settings.copyPasteCompatibilityEnabled, detail: t(
                    "For apps where Sayo cannot read text directly.\nSelect text, then press your shortcut.\nSayo checks the app and window before pasting the result.", "用于无法直接读取文字的应用。\n先选中文字，再按快捷键。\n核对应用和窗口后，粘贴结果。"
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
                Text(t("Current mode: \(mode).\nAvailable shortcuts depend on this mode.", "当前方式：\(mode)。\n可设按键随操作方式变化。"))
                pageLink(t("Change mode", "更改方式"), to: .rewriting)
            }.font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            if model.settings.mode.showsInvokeShortcut {
                Divider()
                shortcutRow(t("Start rewriting", "开始改写"), shortcut: $model.settings.invokeShortcut)
            }
            if model.settings.mode.showsCopyShortcut {
                Divider()
                shortcutRow(t("Copy result", "复制结果"), shortcut: $model.settings.copyShortcut)
            }
            Divider()
            shortcutRow(
                model.settings.mode == .silent ? t("Rewrite and replace", "直接替换") : t("Replace original", "替换原文"),
                shortcut: $model.settings.replaceShortcut
            )
            Divider()
            shortcutRow(t("Translate to other language", "另一语言"), shortcut: $model.settings.secondaryShortcut)
            Text(t("Not set by default.\nOnly this shortcut translates into your other language.\nIt follows the same rewrite mode as your main language.", "默认未设置。\n仅此按键可翻译成另一语言。\n操作方式与常用语言相同。"))
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
                sectionLabel(t("Rewrite commands", "命令改写"))
                Text(t("Press your Sayo shortcut to rewrite a command as you type.", "按快捷键，改写正在输入的命令。"))
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
                sectionLabel(t("Rewrite drafts", "草稿改写"))
                Text(t("Install draft rewriting for each tool you use below.\nRestart your terminal after installation.", "为下列工具安装草稿改写功能。\n安装后，重启终端即可使用。"))
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
                Text(installed ? t("Installed", "已安装") : t("Not installed", "未安装"))
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
                    Text(t("New words. Same meaning.", "换种说法，心意如初。"))
                        .font(.system(size: 28, weight: .semibold))
                        .accessibilityIdentifier("about-slogan")
                    Text(t(
                        "Start writing. Get better as you go.", "从开始写，到越写越好。"
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
                sectionLabel(t("Software updates", "软件更新"))
                Toggle(t("Download automatically", "自动下载"), isOn: $model.settings.automaticallyDownloadsUpdates)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("automatically-download-updates")
                Text(t("Download updates ahead of time.\nInstall now, or when you quit Sayo.", "提前下载新版。\n可立即安装，或退出时安装。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Divider()
                Toggle(t("Check automatically", "自动检查"), isOn: $model.settings.automaticallyChecksForUpdates)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("automatically-check-updates")
                Text(t("Check on startup, at most once an hour.\nClick Check for Updates to check immediately.", "启动时检查，每小时最多一次。\n点击“检查更新”可立即检查。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
            SayoCard {
                Text(t("Common questions", "常见问题"))
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
        case .general: return language.text("Basics", "基本设置")
        case .model: return language.text("Text services", "翻译服务")
        case .rewriting: return language.text("Rewriting", "改写设置")
        case .shortcuts: return language.text("Shortcuts", "快捷键")
        case .appAccess: return language.text("App access", "使用范围")
        case .terminal: return language.text("Terminal", "终端")
        case .about: return language.text("About", "关于")
        case .diagnostics: return language.text("Troubleshooting", "问题排查")
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
        case .general: return language.text("Set your languages and everyday preferences.", "设置语言和使用习惯。")
        case .model: return language.text("Choose a service to process your text.", "选择处理文字的服务。")
        case .rewriting: return language.text("Choose how to rewrite and replace text.", "设置如何改写和替换文字。")
        case .shortcuts: return language.text("Use shortcuts for everyday actions.", "按快捷键，完成常用操作。")
        case .appAccess: return language.text("Choose which apps can use Sayo.", "选择在哪些应用中使用。")
        case .terminal: return language.text("Rewrite commands and drafts in your terminal.", "在终端里改写命令和草稿。")
        case .about: return language.text("View the version, updates, and author information.", "查看版本、更新和作者信息。")
        case .diagnostics: return language.text("View activity and find out why an action failed.", "查看使用记录，查找失败原因。")
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
                Text(t("\(model.configuredModelProfiles.count) services added", "已添加 \(model.configuredModelProfiles.count) 个服务"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Spacer(minLength: 8)
                Button { showingProviderPicker = true } label: {
                    Label(t("Add service", "添加服务"), systemImage: "plus")
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
                    Label(t("Edit service", "编辑服务"), systemImage: "pencil")
                }
                .accessibilityIdentifier("edit-model-profile")
                Button(role: .destructive) { confirmingDeletion = true } label: {
                    Label(t("Delete service", "删除服务"), systemImage: "trash")
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
                            Text(t("Current service", "当前服务"))
                                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                            Text(currentProfileName).font(.system(size: 19, weight: .semibold))
                        }
                        Spacer(minLength: 8)
                        switchHint(t("Switch service", "切换服务"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("Switch service", "切换服务"))
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
                            ? t("No model selected", "未选模型") : model.settings.llm.model)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if canSwitchModel {
                            switchHint(t("Switch model", "切换模型"))
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
            .confirmationDialog(t("Delete service?", "删除服务"), isPresented: $confirmingDeletion) {
                Button(t("Confirm deletion", "确认删除"), role: .destructive) {
                    _ = model.deleteModelProfile(model.settings.activeModelProfileID)
                }
            } message: {
                Text(t("This removes the service's settings and key.", "将删除此服务的设置和密钥。"))
            }
            SayoCard {
                HStack {
                    Text(t("Connection settings", "连接设置")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let website = model.settings.llm.provider.homepageURL {
                        Link(destination: website) {
                            Label(t("Official website", "官方网站"), systemImage: "arrow.up.right")
                                .font(.system(size: 11))
                        }
                    }
                }
                if model.settings.llm.provider != .chromeNano {
                    detailRow(t("Connection type", "连接类型"), model.settings.llm.resolvedAPIFormat.displayName)
                    HStack(alignment: .center, spacing: 18) {
                        Text(t("Service address", "服务地址")).font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                            .frame(width: 96, alignment: .leading)
                        if model.settings.llm.baseURL.isEmpty {
                            Text(t("No address entered", "未填地址")).font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                        } else {
                            SayoCopyValue(value: model.settings.llm.baseURL, language: model.settings.interfaceLanguage)
                        }
                    }
                    detailRow(t("Service key", "服务密钥"), model.apiKey.isEmpty ? t("No key entered", "未填密钥") : t("Saved in Keychain.", "已存入系统钥匙串。"))
                } else {
                    detailRow(t("Connection", "连接方式"), t("Processed on this Mac. No key needed.", "在本机处理，无需密钥。"))
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
        title = language.text("Press shortcut…", "按下按键")
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
            title = language.text("Use ⌘, ⌃ or ⌥", "搭配 ⌘、⌃ 或 ⌥")
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
                .help(language.text("Clear shortcut", "清除按键"))
        }
    }
}
