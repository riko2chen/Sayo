import AppKit
import SwiftUI
import SayoCore

enum SayoStyle {
    static let ink = Color(red: 0.14, green: 0.15, blue: 0.19)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.55)
    static let paper = Color(red: 0.96, green: 0.96, blue: 0.975)
    static let field = Color(red: 0.945, green: 0.945, blue: 0.96)
    static let line = Color(red: 0.88, green: 0.885, blue: 0.915)
    static let accent = Color(red: 0.36, green: 0.39, blue: 0.80)
    static let green = Color(red: 0.13, green: 0.59, blue: 0.39)
}

struct SayoMark: View {
    var size: CGFloat = 38
    private static let logoImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "SayoLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let logoImage = Self.logoImage {
                Image(nsImage: logoImage).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.29))
        .accessibilityLabel("Sayo")
    }
}

struct SayoCard<Content: View>: View {
    var spacing: CGFloat = 18
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SayoStyle.line, lineWidth: 1))
            .shadow(color: SayoStyle.ink.opacity(0.015), radius: 2, y: 1)
    }
}

struct SayoButtonStyle: ButtonStyle {
    var prominent = false
    var progress: Double? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(prominent ? .white : configuration.role == .destructive ? Color.red : SayoStyle.ink)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(prominent ? SayoStyle.accent : Color.white)
                    if let progress {
                        GeometryReader { geometry in
                            Rectangle().fill(SayoStyle.green.opacity(0.24))
                                .frame(width: geometry.size.width * min(1, max(0, progress)))
                                .animation(.linear(duration: 0.2), value: progress)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .accessibilityHidden(true)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                progress != nil ? SayoStyle.green.opacity(0.45) : prominent ? SayoStyle.accent : SayoStyle.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
            .opacity(!isEnabled && progress == nil ? 0.45 : configuration.isPressed ? 0.65 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SayoFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SayoStyle.line.opacity(0.6)))
    }
}

struct SayoSettingRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            content
        }
        .padding(.vertical, 5)
    }
}

struct SayoSegmentedControl<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { value in
                Button { selection = value } label: {
                    Text(label(value))
                        .font(.system(size: 12, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? SayoStyle.ink : SayoStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(selection == value ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selection == value ? SayoStyle.line : .clear))
                        .shadow(color: .black.opacity(selection == value ? 0.06 : 0), radius: 2, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3).background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct ProviderBadge: View {
    let provider: ProviderKind
    var size: CGFloat = 38
    private var symbol: String {
        switch provider {
        case .anthropic: return "asterisk"
        case .gemini, .chromeNano: return "sparkles"
        case .magpie: return "bird"
        case .localModel: return "desktopcomputer"
        case .custom: return "slider.horizontal.3"
        case .openRouter: return "arrow.triangle.branch"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        default: return "cpu"
        }
    }
    private var color: Color {
        switch provider {
        case .anthropic: return Color(red: 0.77, green: 0.43, blue: 0.32)
        case .gemini, .chromeNano, .deepSeek: return Color(red: 0.30, green: 0.43, blue: 0.87)
        case .localModel, .internAI: return SayoStyle.green
        case .magpie: return SayoStyle.ink
        default: return SayoStyle.accent
        }
    }
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.085), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct SayoCopyValue: View {
    let value: String
    let language: InterfaceLanguage
    @State private var copied = false
    var body: some View {
        HStack(spacing: 10) {
            Text(value).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12)).foregroundStyle(copied ? SayoStyle.green : SayoStyle.muted)
            }
            .buttonStyle(.plain)
            .help(language.text("Copy", "复制"))
            .accessibilityLabel(language.text("Copy Base URL", "复制 Base URL"))
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The same searchable list is used for saved configurations and provider templates.
struct ModelProfilePickerView: View {
    let profiles: [ModelProfileOption]
    let language: InterfaceLanguage
    var selectedID: String? = nil
    var adding = false
    let onSelect: (ModelProfileOption) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filteredProfiles: [ModelProfileOption] {
        profiles.filter { query.isEmpty ||
            ($0.displayName(language: language) + " " + $0.model).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(adding ? language.text("Add provider", "新增供应商") : language.text("Switch provider", "切换供应商"))
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(SayoStyle.muted)
                TextField(language.text("Search providers or models", "搜索供应商或模型"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($searchFocused)
                    .accessibilityIdentifier("model-profile-search")
            }
            .padding(10).background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredProfiles) { profile in
                        Button { onSelect(profile) } label: {
                            HStack(spacing: 11) {
                                ProviderBadge(provider: profile.provider, size: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.displayName(language: language))
                                        .font(.system(size: 13, weight: .medium))
                                    if !profile.model.isEmpty {
                                        Text(profile.model).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: adding ? "plus" : profile.id == selectedID ? "checkmark.circle.fill" : "chevron.right")
                                    .font(.system(size: 12)).foregroundStyle(profile.id == selectedID ? SayoStyle.accent : SayoStyle.muted)
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(profile.id == selectedID ? SayoStyle.accent.opacity(0.07) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredProfiles.isEmpty {
                        Text(language.text("No matching providers", "没有匹配的供应商"))
                            .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                            .padding(.vertical, 24)
                    }
                }
            }
            .frame(height: min(320, CGFloat(max(1, profiles.count)) * 58))
        }
        .padding(16).frame(width: 340)
        .foregroundStyle(SayoStyle.ink)
        .background(.white)
        .onAppear { searchFocused = true }
    }
}

struct ModelNamePickerView: View {
    let names: [String]
    let language: InterfaceLanguage
    var selected: String? = nil
    var status = ""
    var loading = false
    var showsTitle = true
    let onSelect: (String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var filtered: [String] {
        names.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Text(language.text("Switch model", "切换模型"))
                    .font(.system(size: 15, weight: .semibold))
            }
            TextField(language.text("Search models", "搜索模型"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { name in
                        Button { onSelect(name) } label: {
                            HStack(spacing: 8) {
                                Text(name).font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if name == selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12)).foregroundStyle(SayoStyle.accent)
                                }
                            }
                            .padding(10).contentShape(Rectangle())
                            .background(name == selected ? SayoStyle.accent.opacity(0.07) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if filtered.isEmpty {
                        Text(status.isEmpty
                             ? language.text("No matching models", "没有匹配的模型")
                             : status)
                            .font(.system(size: 12)).foregroundStyle(SayoStyle.muted).padding(10)
                    }
                }
            }.frame(height: 280)
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("Loading models…", "正在加载模型…"))
                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                }
            } else if !status.isEmpty, !filtered.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
        }.padding(16).frame(width: 340)
            .foregroundStyle(SayoStyle.ink)
            .background(.white)
            .onAppear { searchFocused = true }
    }
}
