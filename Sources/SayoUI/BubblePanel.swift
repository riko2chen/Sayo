import AppKit
import OSLog
import SwiftUI
import SayoCore
import SayoApplication

@MainActor private final class BubbleViewModel: ObservableObject {
    @Published var state = BubbleState()
    @Published var panelSize = NSSize(width: 34, height: 34)
    @Published var interfaceLanguage: InterfaceLanguage = .system
    @Published var copyShortcut: Shortcut?
    @Published var replaceShortcut: Shortcut? = .controlG
    var onRewrite: (() -> Void)?
    var onReplace: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCopy: (() -> Void)?
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A non-activating panel keeps the insertion point in the user's application.
@MainActor public final class BubblePanelController {
    private let logger = Logger(subsystem: "com.sayo.app", category: "bubble")
    private let model = BubbleViewModel()
    private let panel: NSPanel
    private var lastLoggedPhase: BubblePhase = .hidden
    private var lastLoggedFrame: NSRect?
    public var onRewrite: (() -> Void)? { get { model.onRewrite } set { model.onRewrite = newValue } }
    public var onReplace: (() -> Void)? { get { model.onReplace } set { model.onReplace = newValue } }
    public var onDismiss: (() -> Void)? { get { model.onDismiss } set { model.onDismiss = newValue } }
    public var onCopy: (() -> Void)? { get { model.onCopy } set { model.onCopy = newValue } }
    public init() {
        panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hostingView = NSHostingView(rootView: BubbleView(model: model))
        // The panel owns its size; SwiftUI's ideal error-text height must not enlarge it.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setAccessibilityLabel("Sayo rewrite")
    }
    public func update(_ state: BubbleState) {
        model.state = state
        let phaseChanged = state.phase != lastLoggedPhase
        if state.phase == .hidden {
            if phaseChanged { logger.info("panel hidden") }
            lastLoggedPhase = state.phase
            panel.orderOut(nil)
            return
        }
        let expanded = state.expanded
        let notice = state.presentation == .notice
        let noticeCardWidth: CGFloat = 318
        let width: CGFloat = !expanded ? 34 : notice ? noticeCardWidth + 16 : 334
        let height: CGFloat
        if !expanded { height = 34 }
        else if notice {
            let messageHeight = (state.message as NSString).boundingRect(
                with: NSSize(width: noticeCardWidth - 28, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            ).height
            let cardHeight = min(72, max(48, ceil(messageHeight) + 24))
            height = cardHeight + 16
        }
        else if state.phase == .failed {
            let messageHeight = (state.message as NSString).boundingRect(with: NSSize(width: 294, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 12)]).height
            height = 100 + min(64, max(16, ceil(messageHeight))) + (state.result.isEmpty ? 0 : 100)
        }
        else if state.phase == .ready || state.phase == .replacing {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            let textHeight = (state.result as NSString).boundingRect(with: NSSize(width: 294, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]).height
            height = min(360, max(120, ceil(textHeight) + 100))
        } else { height = state.phase == .loading || state.phase == .replaced ? 96 : 120 }
        let size = NSSize(width: width, height: height)
        model.panelSize = size
        let anchor = state.context?.caret.map { NSPoint(x: $0.x, y: $0.y + $0.height) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: anchor.x + 5, y: anchor.y + 5)
        if origin.y + size.height > visible.maxY - 8 { origin.y = anchor.y - size.height - 23 }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if lastLoggedFrame != panel.frame {
            logger.debug("panel frame=\(String(describing: self.panel.frame), privacy: .public)")
            lastLoggedFrame = panel.frame
        }
        if phaseChanged {
            logger.info("panel shown phase=\(String(describing: state.phase), privacy: .public) x=\(origin.x, privacy: .public) y=\(origin.y, privacy: .public) width=\(size.width, privacy: .public) height=\(size.height, privacy: .public) caret=\(state.context?.caret != nil, privacy: .public)")
        }
        lastLoggedPhase = state.phase
    }
    public func configure(
        interfaceLanguage: InterfaceLanguage,
        copyShortcut: Shortcut?,
        replaceShortcut: Shortcut?
    ) {
        model.interfaceLanguage = interfaceLanguage
        model.copyShortcut = copyShortcut
        model.replaceShortcut = replaceShortcut
        panel.setAccessibilityLabel(interfaceLanguage.text("Sayo rewrite", "Sayo 改写"))
    }
}

private struct BubbleView: View {
    @ObservedObject var model: BubbleViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if !model.state.expanded {
                if [.loading, .replacing, .replaced].contains(model.state.phase) {
                    compactBubbleShell(diameter: 28) {
                        CompactRewriteStatus(
                            completed: model.state.phase == .replaced,
                            size: 16
                        )
                    }
                    .accessibilityLabel(model.state.phase == .replaced
                        ? t("Rewrite complete", "改写完成")
                        : t("Rewriting", "正在改写"))
                } else {
                    Button { model.onRewrite?() } label: {
                        compactBubbleShell {
                            Image(systemName: "sparkle")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(SayoStyle.accent, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        }
                    }.buttonStyle(.plain).accessibilityLabel(t("Rewrite with Sayo", "使用 Sayo 改写"))
                }
            } else {
                if model.state.presentation == .notice {
                    Text(model.state.message)
                        .font(.system(size: 13))
                        .foregroundStyle(SayoStyle.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SayoStyle.line))
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .accessibilityLabel(model.state.message)
                        .padding(8)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Button { model.onDismiss?() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .contentShape(Circle())
                                .background(Color.white, in: Circle())
                                .overlay(Circle().stroke(SayoStyle.line))
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SayoStyle.ink.opacity(0.62))
                        .accessibilityLabel(t("Close", "关闭"))
                        .help(t("Close", "关闭"))

                        VStack(alignment: .leading, spacing: 8) {
                            switch model.state.phase {
                            case .loading:
                                HStack(spacing: 10) {
                                    MaterialLoadingIndicator(size: 16)
                                    Text(t("Finding your words…", "正在整理表达…"))
                                        .font(.system(size: 13)).foregroundStyle(SayoStyle.muted)
                                }.padding(.vertical, 6)
                            case .ready, .replacing:
                                resultText
                            case .failed:
                                if !model.state.result.isEmpty { resultText }
                                ScrollView {
                                    Text(model.state.message)
                                        .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxHeight: 64)
                            case .replaced:
                                Label(model.state.message.isEmpty ? t("Replaced—keep writing.", "已替换，继续写吧。") : model.state.message, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12)).foregroundStyle(SayoStyle.green).padding(.vertical, 6)
                            default:
                                Text(t("A clearer way to say it.", "换一种更清晰的表达。"))
                                    .font(.system(size: 13)).foregroundStyle(SayoStyle.muted)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SayoStyle.line))
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                        floatingActions
                    }.padding(8)
                }
            }
        }.frame(width: model.panelSize.width, height: model.panelSize.height)
            .tint(SayoStyle.accent).foregroundStyle(SayoStyle.ink).preferredColorScheme(.light)
    }
    private var resultText: some View {
        ScrollView {
            TypewriterText(
                text: model.state.result,
                animated: !reduceMotion
            )
            .font(.system(size: 14))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var floatingActions: some View {
        switch model.state.phase {
        case .ready, .replacing:
            HStack(spacing: 8) {
                floatingButton(t("Copy", "复制"), shortcut: model.copyShortcut) { model.onCopy?() }
                Spacer(minLength: 8)
                floatingButton(t("Replace", "替换"), shortcut: model.replaceShortcut, prominent: true) { model.onReplace?() }
            }
            .disabled(model.state.phase == .replacing)
        case .failed:
            HStack(spacing: 8) {
                floatingButton(t("Try again", "重试"), prominent: true) { model.onRewrite?() }
            }
        case .idle:
            floatingButton(t("Rewrite", "改写"), prominent: true) { model.onRewrite?() }
        default:
            EmptyView()
        }
    }
    private func floatingButton(_ title: String, shortcut: Shortcut? = nil, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, shortcut: shortcut)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .foregroundStyle(prominent ? Color.white : SayoStyle.ink)
                .background(prominent ? SayoStyle.accent : Color.white, in: Capsule())
                .overlay(Capsule().stroke(SayoStyle.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
    }
    private func compactBubbleShell<Content: View>(diameter: CGFloat = 30, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: diameter, height: diameter)
            .background(Color.white, in: Circle())
            .overlay(Circle().stroke(SayoStyle.line))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .frame(width: 34, height: 34)
    }
    @ViewBuilder private func actionLabel(_ title: String, shortcut: Shortcut?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let shortcut {
                Text(shortcut.displayLabel(language: model.interfaceLanguage))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .opacity(0.65)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }
    private func t(_ english: String, _ simplifiedChinese: String) -> String {
        model.interfaceLanguage.text(english, simplifiedChinese)
    }
}

private struct CompactRewriteStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let completed: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            MaterialLoadingIndicator(size: size)
                .opacity(completed ? 0 : 1)
                .scaleEffect(completed ? 0.72 : 1)

            Circle()
                .fill(SayoStyle.green)
                .frame(width: size + 3, height: size + 3)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.52, weight: .bold))
                        .foregroundStyle(.white)
                }
                .opacity(completed ? 1 : 0)
                .scaleEffect(completed ? 1 : 0.58)
        }
        .frame(width: size + 4, height: size + 4)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.32, dampingFraction: 0.72),
            value: completed
        )
    }
}

private struct MaterialLoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: reduceMotion)) { timeline in
            let progress = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 - 0.5 * cos(progress * .pi * 2)
            let arcLength = reduceMotion ? 0.56 : 0.22 + pulse * 0.46
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.07), lineWidth: 1.55)
                Circle()
                    .trim(from: 0, to: arcLength)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0.26, green: 0.52, blue: 0.96),
                                Color(red: 0.92, green: 0.26, blue: 0.21),
                                Color(red: 0.98, green: 0.74, blue: 0.02),
                                Color(red: 0.20, green: 0.66, blue: 0.33),
                                Color(red: 0.26, green: 0.52, blue: 0.96)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.85, lineCap: .round)
                    )
                    .rotationEffect(.degrees(reduceMotion ? -45 : progress * 235))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct TypewriterText: View {
    let text: String
    let animated: Bool
    @State private var visibleCharacterCount = 0
    @State private var revealOpacity = 1.0

    var body: some View {
        Text(String(text.prefix(visibleCharacterCount)))
            .opacity(revealOpacity)
            .accessibilityLabel(text)
            .task(id: animationID) {
                guard animated else {
                    visibleCharacterCount = text.count
                    revealOpacity = 1
                    return
                }

                visibleCharacterCount = 0
                revealOpacity = 0
                withAnimation(.easeOut(duration: 0.16)) { revealOpacity = 1 }
                try? await Task.sleep(for: .milliseconds(90))

                let count = text.count
                guard count > 0 else { return }
                let steps = min(count, 120)
                let delay = max(12, min(28, 1_500 / steps))
                for step in 1...steps {
                    guard !Task.isCancelled else { return }
                    visibleCharacterCount = Int(ceil(Double(count * step) / Double(steps)))
                    if step < steps { try? await Task.sleep(for: .milliseconds(delay)) }
                }
            }
    }

    private var animationID: String { "\(animated):\(text)" }
}
