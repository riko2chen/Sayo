import SwiftUI
import SayoCore

/// Shared by the selected model page and the configuration editor.
struct ModelConnectionTestView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("Connection test", "连接测试")).font(.system(size: 13, weight: .semibold))
                    Text(t("Check the response and measure total latency.", "检查模型响应，并测量完整请求耗时。"))
                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                }
                Spacer(minLength: 8)
                Button { model.testConnection() } label: {
                    Label(model.testingConnection ? t("Testing…", "测试中…") : t("Test connection", "测试连接"),
                          systemImage: "waveform.path.ecg")
                }
                .disabled(model.testingConnection || model.connectingNano)
                .accessibilityIdentifier("test-model-connection")
            }
            if model.settings.llm.provider == .chromeNano {
                HStack(spacing: 8) {
                    Text(t("Current connection status:", "当前连接状态："))
                    Text(model.nanoConnected ? t("Connected", "已连接") : t("Not connected", "未连接"))
                        .foregroundStyle(model.nanoConnected ? SayoStyle.green : SayoStyle.muted)
                        .accessibilityIdentifier("nano-connection-status")
                    Button { model.refreshNanoConnection() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(t("Refresh connection status", "刷新连接状态"))
                    .accessibilityLabel(t("Refresh connection status", "刷新连接状态"))
                    .accessibilityIdentifier("refresh-nano-connection")
                }
                .font(.system(size: 12))
                Button(t("Connect Chrome…", "连接 Chrome…")) { model.connectNano() }
                    .disabled(model.connectingNano || model.testingConnection)
                    .accessibilityIdentifier("connect-chrome-nano")
            }
            if model.testingConnection || !model.connectionResult.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if model.testingConnection {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.connectionSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.connectionSucceeded ? SayoStyle.green : Color.orange)
                    }
                    Text(model.testingConnection ? t("Waiting for the model…", "正在等待模型响应…") : model.connectionResult)
                        .font(.system(size: 12)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connection-test-result")
                    Spacer(minLength: 0)
                    if let milliseconds = model.connectionLatencyMilliseconds {
                        Text(elapsedDescription(milliseconds))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(SayoStyle.muted)
                            .monospacedDigit().fixedSize()
                            .accessibilityIdentifier("connection-elapsed-time")
                    }
                }
                .padding(12)
                .background((model.connectionSucceeded ? SayoStyle.green : SayoStyle.muted).opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 9))
            }
            if !model.connectionOriginal.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    sentence(t("Original", "原语句"), model.connectionOriginal, id: "connection-original")
                    Divider()
                    sentence(t("Processed", "处理后"), model.testingConnection ? t("Processing…", "处理中…") :
                             model.connectionSucceeded ? model.connectionOutput : t("No result (test failed)", "未生成（测试失败）"),
                             id: "connection-output")
                }
                .padding(14).background(SayoStyle.field.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            }
            if model.settings.llm.provider == .chromeNano, !model.nanoConnectionError.isEmpty {
                Text(model.nanoConnectionError).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(SayoButtonStyle())
        .task(id: model.settings.llm.provider) {
            guard model.settings.llm.provider == .chromeNano else { return }
            // Only read the in-memory heartbeat while this connection section is visible.
            while !Task.isCancelled {
                model.refreshNanoConnection()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func elapsedDescription(_ milliseconds: UInt64) -> String {
        if milliseconds < 1_000 { return t("Elapsed: \(milliseconds) ms", "耗时：\(milliseconds) 毫秒") }
        let seconds = String(format: "%.2f", Double(milliseconds) / 1_000)
        return t("Elapsed: \(seconds) s", "耗时：\(seconds) 秒")
    }

    private func sentence(_ title: String, _ content: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium).foregroundStyle(SayoStyle.muted)
            Text(content).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func t(_ english: String, _ chinese: String) -> String { model.text(english, chinese) }
}
