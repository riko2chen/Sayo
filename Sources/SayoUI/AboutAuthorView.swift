import AppKit
import SwiftUI
import SayoCore

struct AboutAuthorView: View {
    let language: InterfaceLanguage
    @State private var showingEmail = false
    @State private var copiedEmail = false
    private let email = "symeonchen@gmail.com"

    var body: some View {
        SayoCard(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("ABOUT THE AUTHOR", "关于作者"))
                    .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                    .foregroundStyle(SayoStyle.muted)
                Text("Riko Lab")
                    .font(.system(size: 20, weight: .semibold))
                Text(t("Follow along for new tools and updates, or get in touch by email.",
                       "关注新工具与更新，也欢迎通过邮箱交流。"))
                    .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                Button { showingEmail = true } label: {
                    contactRow(t("Email the author", "联系作者"), detail: email,
                               symbol: "envelope", trailingSymbol: "chevron.right")
                }
                .accessibilityIdentifier("author-email")
                .accessibilityHint(t("Show and copy the email address", "查看并复制邮箱地址"))
                .popover(isPresented: $showingEmail, arrowEdge: .top) { emailPopover }
                contactDivider
                contactLink(t("Project homepage", "项目主页"), detail: "sayo.rikolab.com",
                            symbol: "globe", url: "https://sayo.rikolab.com/", identifier: "author-homepage")
                contactDivider
                contactLink(t("Source code", "源代码"), detail: "GitHub · riko2chen/Sayo",
                            symbol: "chevron.left.forwardslash.chevron.right",
                            url: "https://github.com/riko2chen/Sayo", identifier: "author-github")
                contactDivider
                contactLink("X", detail: "@rikolabdotcom", symbol: "at",
                            url: "https://x.com/intent/follow?screen_name=rikolabdotcom", identifier: "author-x")
                contactDivider
                contactLink(t("Xiaohongshu", "小红书"), detail: t("Follow Riko Lab", "关注 Riko Lab"),
                            symbol: "heart", url: "https://www.xiaohongshu.com/user/profile/67348b6a000000001d02e658",
                            identifier: "author-xiaohongshu")
            }
            // Buttons and links share the same row treatment, including hover and press feedback.
            .buttonStyle(AuthorContactStyle())
        }
    }

    private var contactDivider: some View {
        Rectangle().fill(SayoStyle.line.opacity(0.65)).frame(height: 1)
            .padding(.leading, 56).padding(.trailing, 10)
            .accessibilityHidden(true)
    }

    private func contactRow(_ title: String, detail: String, symbol: String,
                            trailingSymbol: String = "arrow.up.right") -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SayoStyle.accent)
                .frame(width: 34, height: 34)
                .background(SayoStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SayoStyle.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: trailingSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SayoStyle.muted)
                .frame(width: 16)
                .accessibilityHidden(true)
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func contactLink(_ title: String, detail: String, symbol: String,
                             url: String, identifier: String) -> some View {
        Link(destination: URL(string: url)!) {
            contactRow(title, detail: detail, symbol: symbol)
        }
        .accessibilityIdentifier(identifier)
        .accessibilityHint(t("Open in your browser", "在浏览器中打开"))
    }

    private var emailPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Email the author", "联系作者"))
                    .font(.system(size: 15, weight: .semibold))
                Text(t("Feedback, ideas, or just a hello.", "反馈、建议，或只是打个招呼。"))
                    .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
            }
            Text(email)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(SayoStyle.field, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("author-email-address")
            Button {
                NSPasteboard.general.clearContents()
                copiedEmail = NSPasteboard.general.setString(email, forType: .string)
            } label: {
                Label(copiedEmail ? t("Copied", "已复制") : t("Copy email address", "复制邮箱地址"),
                      systemImage: copiedEmail ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SayoButtonStyle())
            .accessibilityIdentifier("copy-author-email")
        }
        .padding(20).frame(width: 300)
        .foregroundStyle(SayoStyle.ink)
        .onAppear { copiedEmail = false }
    }

    private func t(_ english: String, _ chinese: String) -> String { language.text(english, chinese) }
}

private struct AuthorContactStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContactBody(configuration: configuration)
    }

    private struct ContactBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(SayoStyle.accent.opacity(configuration.isPressed ? 0.11 : isHovered ? 0.055 : 0),
                            in: RoundedRectangle(cornerRadius: 10))
                .onHover { isHovered = $0 }
        }
    }
}
