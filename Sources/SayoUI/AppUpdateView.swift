import SwiftUI
import SayoCore

extension AppViewModel {
    public var updateActionTitle: String {
        switch updateState {
        case .notConfigured: return text("Updates Unavailable", "更新不可用")
        case .checking: return text("Checking for Updates…", "检查更新中")
        case .available: return text("Download Update", "下载更新")
        case .information: return text("View Update", "查看更新")
        case .downloading(_, let progress):
            let title = text("Downloading", "下载中")
            if let progress { return "\(title) \(progress.formatted(.percent.precision(.fractionLength(0))))" }
            return "\(title)…"
        case .preparing: return text("Preparing…", "正在准备…")
        case .readyToInstall: return text("Update Now", "点击更新")
        case .installing: return text("Updating…", "正在更新…")
        case .failed: return text("Update Failed · Retry", "更新失败 · 重试")
        case .unavailable: return text("Update Unavailable · Retry", "更新不可用 · 重试")
        case .upToDate: return text("Up to Date", "已是最新版本")
        case .ready: return text("Check for Updates", "检查更新")
        }
    }

    var updateDetail: String {
        switch updateState {
        case .notConfigured: return text("The update service is not available yet.", "更新服务尚未开放。")
        case .ready: return text("Check for a newer version of Sayo.", "检查是否有新版 Sayo。")
        case .checking: return text("Looking for a new version of Sayo…", "正在检查新版 Sayo…")
        case .available(let version): return text("Sayo \(version) is available to download.", "Sayo \(version) 已发布，可以下载更新。")
        case .information(let version): return text("Learn more about Sayo \(version).", "查看 Sayo \(version) 的更新信息。")
        case .downloading(let version, _): return text("Downloading Sayo \(version). You can keep using Sayo.", "正在下载 Sayo \(version)，你可以继续使用 Sayo。")
        case .preparing(let version): return text("Verifying and preparing Sayo \(version)…", "正在验证并准备 Sayo \(version)…")
        case .readyToInstall(let version): return text("Sayo \(version) is downloaded. Update and restart now, or install when you quit Sayo.", "Sayo \(version) 已下载。点击更新并重新启动，或在退出 Sayo 时安装。")
        case .installing: return text("Sayo will restart to complete the update.", "Sayo 将重新启动以完成更新。")
        case .upToDate: return text("You’re using the latest version of Sayo.", "你使用的已是最新版本的 Sayo。")
        case .unavailable(let message): return message
        case .failed(let message): return text("Couldn’t check or complete the update. \(message)", "无法检查或完成更新。\(message)")
        }
    }
}

public struct AppUpdateStatusButton: View {
    @ObservedObject var model: AppViewModel
    public init(model: AppViewModel) { self.model = model }

    public var body: some View {
        Button { model.checkForUpdates() } label: {
            Label {
                Text(model.updateActionTitle).monospacedDigit()
            } icon: {
                if model.updateState == .checking {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 1) * 360))
                    }
                    .frame(width: 14, height: 14)
                } else {
                    Image(systemName: statusSymbol)
                }
            }
        }
        .buttonStyle(SayoButtonStyle(progress: downloadProgress))
        .disabled(!model.canRequestUpdateCheck)
        .help(model.updateDetail)
        .accessibilityIdentifier("check-for-updates")
    }

    private var downloadProgress: Double? {
        guard case .downloading(_, let progress) = model.updateState else { return nil }
        return progress ?? 0
    }

    private var statusSymbol: String {
        switch model.updateState {
        case .available, .downloading: return "arrow.down.circle"
        case .readyToInstall: return "arrow.up.circle"
        case .upToDate: return "checkmark.circle"
        case .notConfigured, .failed, .unavailable: return "exclamationmark.triangle"
        default: return "arrow.clockwise"
        }
    }
}

public struct AppUpdatePromptView: View {
    @ObservedObject var model: AppViewModel
    public init(model: AppViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.text("Sayo Updates", "Sayo 更新"))
                .font(.system(size: 23, weight: .semibold))
            Text(model.updateDetail)
                .font(.system(size: 13)).foregroundStyle(SayoStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("update-status")
            if case .downloading(_, let progress) = model.updateState {
                if let progress {
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                } else { ProgressView().controlSize(.small) }
            } else if model.updateState == .checking {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button(model.text("Close", "关闭")) { model.dismissUpdatePromptAction?() }
                    .keyboardShortcut(.cancelAction)
                if model.updateState != .upToDate, !isDownloading {
                    Button(model.updateActionTitle) { model.checkForUpdates() }
                        .disabled(!model.canRequestUpdateCheck)
                        .buttonStyle(SayoButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("update-primary-action")
                }
            }
        }
        .padding(28).frame(width: 440, alignment: .leading)
        .background(SayoStyle.paper).foregroundStyle(SayoStyle.ink)
        .tint(SayoStyle.accent).preferredColorScheme(.light)
        .buttonStyle(SayoButtonStyle())
    }

    private var isDownloading: Bool {
        if case .downloading = model.updateState { return true }
        return false
    }
}
