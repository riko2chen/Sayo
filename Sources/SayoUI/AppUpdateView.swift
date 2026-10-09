import SwiftUI
import SayoCore

extension AppViewModel {
    public var updateActionTitle: String {
        switch updateState {
        case .notConfigured: return text("Unavailable", "暂不可用")
        case .checking: return text("Checking", "检查中")
        case .available: return text("Download update", "下载新版")
        case .information: return text("View Update", "查看更新")
        case .downloading(_, let progress):
            let title = text("Downloading", "下载中")
            if let progress { return "\(title) \(progress.formatted(.percent.precision(.fractionLength(0))))" }
            return "\(title)…"
        case .preparing: return text("Preparing", "准备中")
        case .readyToInstall: return text("Update now", "立即更新")
        case .installing: return text("Updating", "更新中")
        case .failed: return text("Retry update", "重试更新")
        case .unavailable: return text("Check again", "重新检查")
        case .upToDate: return text("Up to date", "已是最新")
        case .ready: return text("Check for Updates", "检查更新")
        }
    }

    var updateDetail: String {
        switch updateState {
        case .notConfigured: return text("The update service is not available yet.", "更新服务尚未开放。")
        case .ready: return text("Check for a newer version of Sayo.", "检查是否有新版 Sayo。")
        case .checking: return text("Looking for a new version of Sayo…", "正在检查新版 Sayo…")
        case .available(let version): return text("Version \(version) is ready to download.", "新版 \(version) 可以下载。")
        case .information(let version): return text("See what's new in \(version).", "查看 \(version) 的更新内容。")
        case .downloading(let version, _): return text("Downloading \(version).\nYou can keep using Sayo.", "正在下载 \(version)。\n你可以继续使用。")
        case .preparing(let version): return text("Checking and preparing \(version)…", "正在检查并准备 \(version)…")
        case .readyToInstall(let version): return text("Version \(version) is downloaded.\nUpdate now to restart Sayo.\nOr install when you quit.", "新版 \(version) 已下载。\n立即更新会重新启动应用。\n也可在退出时安装。")
        case .installing: return text("Sayo will restart to finish updating.", "应用将重启，完成更新。")
        case .upToDate: return text("You are using the latest version.", "你正在使用最新版本。")
        case .unavailable(let message): return message
        case .failed(let message): return text("Could not check or finish updating.\n\(message)", "无法检查或完成更新。\n\(message)")
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
