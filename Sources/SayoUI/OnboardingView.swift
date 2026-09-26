import SwiftUI
import SayoCore

public struct OnboardingView: View {
    @ObservedObject var model: AppViewModel
    public init(model: AppViewModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) { SayoMark(size: 32); Text("Sayo").font(.system(size: 23, weight: .semibold, design: .rounded)) }
                Spacer()
                Picker("", selection: $model.settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { language in Text(language.displayName).tag(language) }
                }.labelsHidden().frame(width: 130)
            }.padding(.horizontal, 38).padding(.top, 29)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(eyebrow).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(SayoStyle.accent)
                    Text(title).font(.system(size: 34, weight: .semibold)).lineSpacing(3)
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(SayoStyle.muted).lineSpacing(4)
                    switch model.onboardingStep {
                    case 0: WelcomeDemo(model: model)
                    case 1: permission
                    case 2: ModelConfigurationView(model: model, showsOnboardingGuide: true)
                    default: finish
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 54).padding(.top, 45).padding(.bottom, 24)
            }
            HStack {
                HStack(spacing: 7) {
                    ForEach(steps, id: \.self) { index in Capsule().fill(index == model.onboardingStep ? SayoStyle.accent : SayoStyle.accent.opacity(0.15)).frame(width: index == model.onboardingStep ? 23 : 6, height: 6) }
                }
                Spacer()
                if model.onboardingStep > 0 { Button(t("Back", "返回")) { model.onboardingStep -= 1 }.buttonStyle(.plain).padding(.trailing, 16) }
                if model.onboardingStep == 2 {
                    Button(t("Set up later", "稍后配置")) {
                        advance()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SayoStyle.muted)
                    .padding(.trailing, 16)
                    .accessibilityIdentifier("skip-model-configuration")
                }
                Button(isLastStep ? t("Start writing", "开始使用") : t("Continue", "继续"), action: advance)
                    .buttonStyle(SayoButtonStyle(prominent: true)).controlSize(.large)
            }.padding(.horizontal, 54).padding(.top, 16).padding(.bottom, 28)
        }.frame(width: 740, height: 760).background(SayoStyle.paper).foregroundStyle(SayoStyle.ink)
            .tint(SayoStyle.accent).preferredColorScheme(.light)
            .buttonStyle(SayoButtonStyle())
    }
    private var steps: [Int] { [0, 1, 2, 3] }
    private var isLastStep: Bool { model.onboardingStep == steps.last }
    private func advance() {
        if isLastStep {
            model.settings.onboardingCompleted = true
            if model.save() { model.finishOnboardingAction?() }
        } else if model.onboardingStep == 2 {
            if model.save() { model.onboardingStep += 1 }
        } else { model.onboardingStep += 1 }
    }
    private var eyebrow: String {
        return [t("01 / MEET SAYO", "01 / 认识 SAYO"), t("02 / MAKE YOURSELF AT HOME", "02 / 准备就绪"),
         t("03 / BRING YOUR MODEL", "03 / 连接你的模型"), t("04 / FIND YOUR RHYTHM", "04 / 找到你的节奏")][model.onboardingStep]
    }
    private var title: String {
        return [t("Think in many languages.\nWrite in one clear voice.", "用多种语言思考，\n清晰地表达出来。"),
         t("Right where\nyour words happen.", "就在你\n输入文字的地方。"),
         t("Your model.\nYour target language.", "你的模型，\n你的目标语言。"),
         t("A small bubble.\nA smoother day.", "一个小气泡，\n让表达更顺畅。")][model.onboardingStep]
    }
    private var subtitle: String {
        return [t("Mix languages naturally and let Sayo rewrite the whole thought in your selected language beside the input.", "按你的习惯混合语言输入，Sayo 会在输入框旁将整段内容改写成目标语言。"),
         t("Give Sayo access to the active text field, so it can place a small bubble by your cursor and replace text when you choose.", "允许 Sayo 访问当前文本框，它就能在光标旁显示小气泡，并在你确认后替换文字。"),
         t("Connect a language model so text goes directly to it while the API key stays in macOS Keychain.", "连接语言模型后，文本会直接发送到该服务，API Key 保存在 macOS 钥匙串中。"),
         t("Choose a starting mode and change it, shortcuts, languages, or the prompt any time.", "选择初始工作模式后，仍可随时修改模式、快捷键、语言和提示词。")][model.onboardingStep]
    }
    private var permission: some View {
        SayoCard {
            HStack(spacing: 16) {
                Image(systemName: model.accessibilityGranted ? "checkmark.shield" : "hand.raised").font(.system(size: 33)).foregroundStyle(SayoStyle.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Accessibility", "辅助功能")).font(.system(size: 17, weight: .semibold))
                    Text(model.accessibilityGranted ? t("Sayo is connected and can follow your cursor.", "Sayo 已连接，可以跟随你的光标。") : t("Enable one permission in System Settings.", "请在系统设置中开启一项权限。"))
                        .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                }
                Spacer()
            }
            Divider()
            Text(t("1. Open Accessibility settings below.\n2. Drag Sayo from the floating guide into the app list.\n3. Approve macOS and switch Sayo on. We’ll check automatically.", "1. 打开下方的辅助功能设置。\n2. 从浮动引导中把 Sayo 拖入应用列表。\n3. 按 macOS 提示授权并打开 Sayo，我们会自动检查。"))
                .font(.system(size: 13)).lineSpacing(9)
            HStack {
                Button(model.accessibilityGranted ? t("Open System Settings", "打开系统设置") : t("Open & drag Sayo…", "打开并拖入 Sayo…")) { model.permissionAction?() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button(t("Check again", "再次检查")) { model.refreshAction?() }
            }
            Text(t("Secure fields are excluded, and Settings controls which apps can use Sayo.", "安全输入框会自动排除，你可以在设置中选择 Sayo 启用的应用。"))
                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
        }
    }
    private var finish: some View {
        VStack(spacing: 15) {
            ForEach(WorkingMode.allCases, id: \.self) { mode in
                Button { model.settings.mode = mode } label: {
                    HStack(spacing: 15) {
                        Image(systemName: mode.symbol).font(.system(size: 19)).frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mode.title(language: model.settings.interfaceLanguage)).font(.system(size: 14, weight: .semibold))
                            Text(mode.detail(language: model.settings.interfaceLanguage)).font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                        }
                        Spacer()
                        Image(systemName: model.settings.mode == mode ? "checkmark.circle.fill" : "circle").foregroundStyle(SayoStyle.accent.opacity(model.settings.mode == mode ? 1 : 0.3))
                    }.padding(17).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(model.settings.mode == mode ? SayoStyle.accent.opacity(0.5) : SayoStyle.line))
                }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb").foregroundStyle(SayoStyle.accent)
                Text(t("Choose a target language and type naturally in an input field. Trigger a rewrite with your selected mode; when a result bubble appears, copy or replace it. Silent mode replaces directly. If you have not connected a model, visit Settings → Language Model later.",
                       "选择目标语言，在输入框中自然输入，再按所选模式触发改写。出现结果气泡时可复制或替换；静默模式会直接替换。如尚未连接模型，可稍后前往“设置 → 语言模型”配置。"))
                    .font(.system(size: 12)).foregroundStyle(SayoStyle.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(SayoStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Write in the terminal, too", "终端里也能使用")).font(.system(size: 12, weight: .medium))
                    Text(t("Set up zsh now, or visit Settings → Terminal later.", "现在配置 zsh，或稍后前往“设置 → 终端”。")) .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                }
                Spacer()
                Button(t("Set up zsh", "配置 zsh")) { model.installTerminal(TerminalShell.zsh.rawValue) }.controlSize(.small)
            }.padding(.top, 6)
            if !model.notice.isEmpty { Text(model.notice).font(.system(size: 11)).foregroundStyle(model.noticeIsError ? .red : SayoStyle.muted) }
        }
    }
    private func t(_ english: String, _ simplifiedChinese: String) -> String { model.text(english, simplifiedChinese) }
}

private struct WelcomeDemo: View {
    @ObservedObject var model: AppViewModel
    @State private var text = ""
    @State private var phase = 0
    private var result: String {
        switch model.settings.targetLanguage {
        case .english: return "I like this product."
        case .simplifiedChinese: return "我喜欢这个产品。"
        case .traditionalChinese: return "我喜歡這個產品。"
        case .japanese: return "この製品が好きです。"
        case .korean: return "이 제품이 마음에 들어요."
        case .spanish: return "Me gusta este producto."
        case .french: return "J’aime ce produit."
        case .german: return "Ich mag dieses Produkt."
        case .portuguese: return "Gosto deste produto."
        case .italian: return "Mi piace questo prodotto."
        case .russian: return "Мне нравится этот продукт."
        case .arabic: return "أعجبني هذا المنتج."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(t("LET’S TRY IT", "试试看")).font(.system(size: 10, weight: .semibold)).tracking(1.5)
                Spacer()
                Text(t("Interactive local demo", "本地交互演示")).font(.system(size: 10)).foregroundStyle(SayoStyle.muted)
            }
            HStack {
                Text(t("Target", "目标语言")).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Spacer()
                Picker("", selection: $model.settings.targetLanguage) {
                    ForEach(TargetLanguage.allCases, id: \.self) { language in
                        Text(model.targetLanguageName(language)).tag(language)
                    }
                }.labelsHidden().frame(width: 190)
            }
            HStack(spacing: 5) {
                Text(t("Type:", "输入：")).foregroundStyle(SayoStyle.muted)
                Text("I like 这个产品").fontWeight(.medium).textSelection(.enabled)
                Spacer()
                Button(t("Use example", "使用示例")) { text = "I like 这个产品" }.buttonStyle(.link).font(.system(size: 11))
            }.font(.system(size: 13))
            HStack(alignment: .top) {
                TextField(t("Your thought goes here…", "在这里输入你的想法…"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 20)).lineLimit(2...3)
                    .accessibilityLabel("Try typing I like 这个产品")
                if !text.isEmpty {
                    Image(systemName: phase == 3 ? "checkmark" : "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(SayoStyle.accent, in: Circle()).padding(.top, 4)
                }
            }.padding(19).background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SayoStyle.accent.opacity(0.18)))
            if phase == 1 {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(t("Finding your words…", "正在整理表达…")).font(.system(size: 12)).foregroundStyle(SayoStyle.muted) }.frame(height: 40)
            } else if phase == 2 {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(t("YOUR WORDS, IN \(model.settings.targetLanguage.promptName.uppercased())", "目标语言：\(model.targetLanguageName(model.settings.targetLanguage))")).font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(SayoStyle.accent)
                        Text(result).font(.system(size: 16))
                    }
                    Spacer()
                    Button(replaceButtonLabel) {
                        phase = 3; text = result
                    }.buttonStyle(.borderedProminent)
                }.padding(17).background(SayoStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            } else if phase == 3 {
                Label(t("Your thought is now rewritten fluently.", "你的想法已经被流畅地改写。"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(SayoStyle.green).frame(height: 40)
            } else {
                Text(t("Pause for two seconds to see a local rewrite, then replace it.", "停顿两秒即可看到本地改写结果，然后替换原文。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted).frame(height: 40)
            }
        }.padding(24).background(SayoStyle.accent.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(SayoStyle.line))
            .task(id: text) {
                guard text == "I like 这个产品" else { if phase != 3 { phase = 0 }; return }
                phase = 0
                do {
                    try await Task.sleep(for: .seconds(2)); phase = 1
                    try await Task.sleep(for: .milliseconds(600)); phase = 2
                } catch {}
            }
    }
    private var replaceButtonLabel: String {
        let title = t("Replace", "替换")
        guard let shortcut = model.settings.replaceShortcut else { return title }
        return "\(title) \(shortcut.displayLabel(language: model.settings.interfaceLanguage))"
    }
    private func t(_ english: String, _ simplifiedChinese: String) -> String { model.text(english, simplifiedChinese) }
}
