import Foundation

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var timestamp: String
    public var event: String
    public var fields: [String: String]
    public init(timestamp: String, event: String, fields: [String: String]) {
        self.timestamp = timestamp; self.event = event; self.fields = fields
    }
    public var date: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
    public var rawText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? event
    }
    public func explanation(_ language: InterfaceLanguage) -> String {
        func t(_ en: String, _ zh: String) -> String { language.text(en, zh) }
        let f = fields
        switch event {
        case "invocation_started": return t("Rewrite invoked via \(f["trigger"] ?? "unknown").", "开始唤起：\(Self.triggerName(f["trigger"], language)).")
        case "input_captured": return t("Captured \(f["sourceLength"] ?? "?") UTF-16 units for rewriting (\(f["scope"] ?? "unknown")).", "已读取待改写文案，共 \(f["sourceLength"] ?? "?") 个 UTF-16 单位，范围：\(f["scope"] == "selection" ? "选中文字" : "整个输入框")。")
        case "rewrite_requested": return t("Requested a rewrite from the configured model.", "已向配置的模型请求改写。")
        case "rewrite_ready": return t("Received a rewrite (\(f["resultLength"] ?? "?") UTF-16 units); waiting to apply it.", "已收到改写结果（\(f["resultLength"] ?? "?") 个 UTF-16 单位），等待应用。")
        case "invocation_ignored":
            return t("Skipped: the input is empty.", "当前输入为空，本次唤起未请求模型。")
        case "invocation_cancelled": return t("Cancelled because input, focus, configuration, or the active request changed.", "输入、焦点、配置或当前请求已变化，本次操作取消。")
        case "replacement_requested": return t("Applying the rewrite after rechecking the original input.", "开始应用结果，并重新核对原文及输入框。")
        case "transaction_started": return t("Replacement target \(f["targetRange"] ?? "?"); \(f["prefersPaste"] == "true" ? "clipboard paste preferred" : "Accessibility writes preferred").", "目标选区 \(f["targetRange"] ?? "?")；\(f["prefersPaste"] == "true" ? "优先使用粘贴" : "优先使用辅助功能写入")。")
        case "selection_requested":
            let method = f["method"] == "select_all_shortcut" ? t("Select All shortcut", "全选快捷键") : t("Accessibility", "辅助功能接口")
            return f["accepted"] == "true" ? t("\(method) accepted the selection request; it still needs read-back verification.", "\(method)已接受设置选区请求，仍需回读确认生效。") : t("\(method) could not set the selection.", "\(method)无法设置目标选区。")
        case "selection_verified": return t("Selection verified as \(f["range"] ?? "?") after \(f["samples"] ?? "?") checks.", "回读 \(f["samples"] ?? "?") 次后，确认选区为 \(f["range"] ?? "?")。")
        case "selection_timeout": return t("Selection did not change after 26 checks: wanted \(f["targetRange"] ?? "?"), observed \(f["actualRange"] ?? "?").", "回读 26 次后选区仍未生效：期望 \(f["targetRange"] ?? "?")，实际 \(f["actualRange"] ?? "?")。")
        case "selection_unavailable": return t("The required replacement selection could not be established.", "无法建立替换所需的选区。")
        case "selection_changed_unexpectedly": return t("Selection or text changed unexpectedly; stopped to avoid editing the wrong text.", "选区或正文意外变化，为避免编辑错误位置而停止。")
        case "replacement_read_failed":
            let reasons = ["focus_changed": "输入焦点已离开原控件", "secure_input": "输入变为安全控件", "value_or_range_unavailable": "无法回读正文或有效选区"]
            return t("Could not verify the input: \(f["reason"] ?? "unknown").", "无法核验输入：\(reasons[f["reason"] ?? ""] ?? "未知原因")。")
        case "ax_write": return t("Accessibility setter \(f["attribute"] ?? "?") returned status \(f["status"] ?? "?") (0 means the API accepted the request).", "辅助功能写入 \(f["attribute"] ?? "?") 返回状态码 \(f["status"] ?? "?")；0 只表示接口接受请求。")
        case "direct_write": return t("Direct write through \(f["method"] ?? "?"): \(f["accepted"] == "true" ? "accepted; verifying content" : "rejected").", "通过 \(f["method"] == "selected_text" ? "选中文字属性" : "整个输入框属性")写入：\(f["accepted"] == "true" ? "请求已接受，正在核对正文" : "请求被拒绝")。")
        case "direct_write_unchanged": return t("The direct write was ignored; retrying a verified paste at the original selection.", "直接写入未生效；正在原选区重试一次可核验的粘贴替换。")
        case "clipboard_prepared": return t("Prepared a temporary clipboard lease for pasting.", "已暂存剪贴板并准备粘贴结果。")
        case "paste_sent": return t("Sent paste to the target selection \(f["targetRange"] ?? "?"); verifying the resulting text.", "已向选区 \(f["targetRange"] ?? "?")发送粘贴，正在核对实际正文。")
        case "clipboard_restore_attempted": return t("Released the temporary clipboard lease; newer user clipboard changes are preserved.", "已结束临时剪贴板使用；若期间复制了其他内容，会保留较新的剪贴板。")
        case "compatibility_capture_started": return t("Accessibility input was unavailable; preparing the opt-in Copy/Paste compatibility capture.", "辅助功能无法读取输入框，开始使用已启用的复制/粘贴兼容捕获。")
        case "compatibility_copy_sent": return t("Sent Copy to capture the current selection; waiting for a new clipboard value.", "已发送复制快捷键以捕获当前选区，正在等待新的剪贴板内容。")
        case "compatibility_capture_succeeded": return t("Captured \(f["sourceLength"] ?? "?") UTF-16 units through the compatibility path.", "已通过兼容模式读取 \(f["sourceLength"] ?? "?") 个 UTF-16 单位。")
        case "compatibility_capture_failed": return t("Compatibility capture stopped: \(f["reason"] ?? "unknown").", "兼容模式捕获已停止：\(f["reason"] ?? "未知原因")。")
        case "compatibility_paste_sent": return t("Sent Paste to the same foreground application and window.", "已向同一个前台应用和窗口发送粘贴替换。")
        case "write_verified": return t("Expected text remained stable for 7 consecutive checks; write verified.", "实际正文连续 7 次回读均与预期一致，写入已确认。")
        case "write_unchanged": return t("After 51 checks, the original text was still unchanged; replacement had no effect.", "回读 51 次后原文仍未改变，替换写入没有生效。")
        case "write_changed_unexpectedly": return t("Text changed unexpectedly or reverted after a result appeared. Stopped without appending.", "正文出现非预期变化，或结果出现后又回退；已停止，不继续追加。")
        case "fallback_started": return Self.fallbackExplanation(f["reason"], language)
        case "fallback_position": return t("Preparing fallback insertion at \(f["targetRange"] ?? "?").", "准备在原光标位置 \(f["targetRange"] ?? "?")追加结果。")
        case "selection_collapse": return t("Used Right Arrow to collapse the verified selection without deleting it.", "通过右方向键收起已核验的选区，不删除原文。")
        case "replacement_noop": return t("The result already matches the original; no write was necessary.", "结果与原文相同，无需写入。")
        case "replacement_finished", "invocation_completed":
            return f["outcome"] == "inserted_at_caret" ? t("Inserted at the original caret; original text was kept.", "已追加到原光标位置，原文保留。") : t("Replacement completed.", "已完成替换。")
        case "replacement_failed", "invocation_failed": return Self.errorExplanation(f["error"], language)
        case "input":
            switch f["reason"] {
            case "placeholder_containment_length": return t("Filtered placeholder: the value contains it and is no longer than twice its length (\(f["rawLength"] ?? "?") → 0).", "文案包含 placeholder，且长度不超过其两倍，已按空内容处理（\(f["rawLength"] ?? "?") → 0）。")
            case "placeholder_filtered": return t("Identified placeholder decoration and treated it as empty input.", "识别为占位提示，按空输入处理。")
            case "value_preserved": return t("Read actual input: \(f["rawLength"] ?? "?") → \(f["resolvedLength"] ?? "?") UTF-16 units.", "保留输入正文：原始长度 \(f["rawLength"] ?? "?") → 识别长度 \(f["resolvedLength"] ?? "?")。")
            case "empty_value": return t("The focused input is empty.", "当前输入框为空。")
            case "secure_input_skipped": return t("Skipped a secure input without reading its text.", "当前为密码等安全输入框，未读取正文。")
            case "terminal_or_excluded_app", "sayo_settings": return t("This application is excluded or uses terminal integration.", "当前应用被排除，或需要走终端集成。")
            case "no_focused_element": return t("No focused input was exposed by the app.", "应用没有提供当前聚焦的输入控件。")
            case "unsupported_role": return t("Focused control \(f["role"] ?? "?") is not a supported text input.", "当前聚焦的 \(f["role"] ?? "?") 控件不是支持的文本输入框。")
            default: return t("Input read was unavailable: \(f["reason"] ?? "unknown").", "未能读取输入，原因：\(f["reason"] ?? "未知")。")
            }
        case "bubble": return t("Bubble state: \(f["phase"] ?? "unknown").", "气泡状态：\(Self.phaseName(f["phase"], language))。")
        case "launch": return t("Sayo started (process \(f["pid"] ?? "?")).", "Sayo 已启动，进程编号 \(f["pid"] ?? "?")。")
        case "shutdown": return t("Sayo exited.", "Sayo 已退出。")
        case "diagnostic_options": return t("Text snippets \(f["textSnippets"] == "true" ? "enabled" : "disabled").", "文本片段记录已\(f["textSnippets"] == "true" ? "开启" : "关闭")。")
        case "pause": return t("Sayo pause state: \(f["paused"] ?? "?").", "Sayo 已\(f["paused"] == "true" ? "暂停" : "恢复")。")
        default: return t("Diagnostic event: \(event). See raw fields for details.", "诊断事件：\(event)，可展开原始字段查看。")
        }
    }
    public static func fallbackExplanation(_ reason: String?, _ language: InterfaceLanguage) -> String {
        switch reason {
        case "replacement_unchanged": return language.text("Replacement left the original unchanged. Sayo will recheck the original before attempting insertion.", "替换后原文一直未改变；将重新确认原文完整，再尝试在光标位置追加。")
        case "replacement_unsupported": return language.text("The app could not support the required replacement operation. Sayo will recheck the original before attempting insertion.", "目标应用无法完成所需的替换操作；将重新确认原文完整，再尝试在光标位置追加。")
        default: return language.text("These logs do not contain the reason for insertion. Reproduce once with the updated version to capture it.", "这组日志没有记录追加原因。请用更新后的版本再复现一次。")
        }
    }
    public static func triggerName(_ trigger: String?, _ language: InterfaceLanguage) -> String {
        switch trigger {
        case "automatic": return language.text("typing pause", "停止输入后自动唤起")
        case "bubble": return language.text("bubble click", "点击气泡")
        case "shortcut": return language.text("keyboard shortcut", "快捷键")
        case "terminal": return language.text("terminal", "终端")
        case "copy_paste_compatibility": return language.text("Copy/Paste compatibility", "复制/粘贴兼容模式")
        default: return language.text("direct invocation", "直接唤起")
        }
    }
    public static func phaseName(_ phase: String?, _ language: InterfaceLanguage) -> String {
        let names = ["hidden": "隐藏", "idle": "等待操作", "loading": "请求模型中", "ready": "结果已就绪", "replacing": "应用结果中", "replaced": "操作已完成", "failed": "失败"]
        return language.text(phase ?? "unknown", names[phase ?? ""] ?? "未知")
    }
    public static func errorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? SayoError else { return "external_error" }
        switch error {
        case .network: return "network"
        default: return String(describing: error)
        }
    }
    public static func errorExplanation(_ code: String?, _ language: InterfaceLanguage) -> String {
        let reasons = ["staleInput": "原文、选区或输入焦点已变化", "unsupportedInput": "输入框不支持所需操作", "replacementFailed": "无法确认写入结果", "noInput": "没有可读取的输入框", "emptyInput": "输入为空", "noSelection": "没有捕获到选中文字", "compatibilitySelectionRequired": "当前应用不支持直接替换，需要先选中内容", "permissionRequired": "缺少辅助功能权限", "invalidSelection": "选区无效", "missingConfiguration": "缺少模型配置", "invalidResponse": "模型没有返回有效结果", "network": "模型请求失败", "cancelled": "操作已取消", "sensitiveInput": "当前为安全输入框", "inputTooLong": "输入超出长度限制"]
        return language.text("Operation stopped: \(code ?? "unknown error").", "操作停止：\(reasons[code ?? ""] ?? "未分类错误（\(code ?? "unknown")）")。")
    }
}

public enum DiagnosticCategory: String, CaseIterable, Sendable {
    case invocation, input, system, history
    public func title(_ language: InterfaceLanguage) -> String {
        switch self {
        case .invocation: return language.text("Invocations", "唤起记录")
        case .input: return language.text("Input observations", "输入观察")
        case .system: return language.text("System", "系统事件")
        case .history: return language.text("Unlinked history", "历史未关联记录")
        }
    }
}

public struct DiagnosticGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: DiagnosticCategory
    public var events: [DiagnosticEvent]
    public var application: String { events.first(where: { $0.event == "input_captured" })?.fields["app"] ?? events.compactMap { $0.fields["app"] }.first(where: { !$0.isEmpty && $0 != "none" }) ?? "Sayo" }
    public var applicationKey: String { events.compactMap { $0.fields["bundleID"] }.first ?? application }
    public var startedAt: Date? { events.first?.date }
    public var lastEventAt: Date? { events.last?.date }
    public var trigger: String? { events.first(where: { $0.event == "invocation_started" })?.fields["trigger"] }
    public var ordinal: String? { events.first(where: { $0.event == "invocation_started" })?.fields["ordinal"] }
    public var incomplete: Bool { category == .invocation && !events.contains(where: { $0.event == "invocation_started" }) }
    public var outcome: String? {
        events.last(where: { ["invocation_completed", "replacement_finished", "invocation_failed", "replacement_failed", "invocation_cancelled", "invocation_ignored", "rewrite_ready", "rewrite_requested"].contains($0.event) }).map {
            switch $0.event {
            case "invocation_failed", "replacement_failed": return "failed"
            case "invocation_cancelled": return "cancelled"
            case "invocation_ignored": return "ignored"
            case "rewrite_ready": return "ready"
            case "rewrite_requested": return "loading"
            default: return $0.fields["outcome"] ?? "unknown"
            }
        }
    }
    public var fallbackReason: String? { events.last(where: { $0.event == "fallback_started" })?.fields["reason"] }
    public func summary(_ language: InterfaceLanguage) -> String {
        switch outcome {
        case "inserted_at_caret": return language.text("Inserted at caret", "已追加，原文保留")
        case "replaced": return language.text("Replaced successfully", "已成功替换")
        case "failed": return language.text("Failed", "操作失败")
        case "cancelled": return language.text("Cancelled", "已取消")
        case "ignored": return language.text("Skipped", "未触发改写")
        case "ready": return language.text("Result ready; not yet applied", "结果已就绪，尚未应用")
        case "loading": return language.text("Request started; no completion recorded", "已发起请求，尚无完成记录")
        default: return category == .invocation ? language.text("No outcome recorded", "暂无结果记录") : language.text("\(events.count) events", "\(events.count) 条事件")
        }
    }
}

public struct DiagnosticAnalysis: Equatable, Sendable {
    public var groups: [DiagnosticGroup] = []
    public var unreadableLines = 0
    public init(jsonLines: String = "") {
        var groups: [DiagnosticGroup] = []
        var indices: [String: Int] = [:]
        var order: [String: Int] = [:]
        var position = 0
        let decoder = JSONDecoder()
        for line in jsonLines.split(separator: "\n") {
            guard let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)) else { unreadableLines += 1; continue }
            let category: DiagnosticCategory
            let key: String
            if let invocation = event.fields["invocationID"], !invocation.isEmpty {
                category = .invocation; key = "invocation:\(invocation)"
            } else if event.event == "input" {
                category = .input; key = "input:\(event.fields["bundleID"] ?? event.fields["app"] ?? "unknown"):\(event.fields["inputID"] ?? "unavailable")"
            } else if event.event == "bubble" {
                category = .history; key = "history:\(event.fields["app"] ?? "unknown"):\(event.fields["inputID"] ?? "unknown")"
            } else {
                category = .system; key = "system:\(event.timestamp.prefix(10))"
            }
            if category != .invocation || order[key] == nil { order[key] = position }
            position += 1
            if let index = indices[key] { groups[index].events.append(event) }
            else { indices[key] = groups.count; groups.append(.init(id: key, category: category, events: [event])) }
        }
        // File order is authoritative, including when the wall clock changes.
        self.groups = groups.sorted { (order[$0.id] ?? 0) > (order[$1.id] ?? 0) }
    }
}

/// A bounded, allow-listed view of recent failed invocations that is safe to
/// send to the user's configured model. The original retained log is never
/// mutated, and fields not explicitly listed here are omitted by default.
public struct AIDiagnosticEvidence: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var application: String
        public var bundleID: String?
        public var failedAt: String
        public var events: [Event]
    }

    public struct Event: Codable, Equatable, Sendable {
        public var timestamp: String
        public var event: String
        public var fields: [String: String]
    }

    public var generatedAt: String
    public var windowStart: String
    public var windowMinutes: Int
    public var failures: [Failure]

    public static let defaultWindow: TimeInterval = 10 * 60
    public static let maximumFailures = 20

    private static let safeFields: Set<String> = [
        "accepted", "actualLength", "actualRange", "alreadyPositioned", "app", "atomicFinish",
        "attribute", "bundleID", "canWriteSelected", "canWriteValue", "caretAvailable",
        "characterCount", "elapsedMs", "error", "expectedLength", "expanded",
        "explicitPlaceholderLength", "filteredPlaceholder", "frame", "frames",
        "inferredPlaceholderLength", "insertionRange", "length", "method", "mode",
        "operationElapsedMs", "originalLength", "outcome", "phase", "placeholderContainmentMatch",
        "placeholderMatchesValue", "placeholderSource", "prefersPaste", "range", "rawLength",
        "reason", "replacementLength", "resolvedLength", "resultLength", "revertedAfterResult",
        "role", "samples", "scope", "selection", "sequence", "sourceLength", "stableSamples",
        "status", "step", "targetRange", "textSnippets", "tree", "trigger", "webInput"
    ]

    public init(
        jsonLines: String,
        now: Date = Date(),
        window: TimeInterval = defaultWindow,
        maximumFailures: Int = maximumFailures
    ) {
        let cutoff = now.addingTimeInterval(-window)
        let analysis = DiagnosticAnalysis(jsonLines: jsonLines)
        let candidates = analysis.groups.compactMap { group -> (DiagnosticGroup, Date)? in
            guard group.category == .invocation, group.outcome == "failed",
                  let failedAt = group.events.last(where: {
                      $0.event == "invocation_failed" || $0.event == "replacement_failed"
                  })?.date,
                  failedAt >= cutoff, failedAt <= now
            else { return nil }
            return (group, failedAt)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(max(0, maximumFailures))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        generatedAt = formatter.string(from: now)
        windowStart = formatter.string(from: cutoff)
        windowMinutes = max(1, Int(window / 60))
        failures = candidates.map { group, failedAt in
            let bundleID = group.events.compactMap { $0.fields["bundleID"] }.first
            let events = group.events.filter { $0.event != "bubble" }.map { event in
                Event(timestamp: event.timestamp, event: event.event, fields: Self.sanitized(event.fields))
            }
            return Failure(
                application: group.application,
                bundleID: bundleID,
                failedAt: formatter.string(from: failedAt),
                events: events
            )
        }
    }

    public var isEmpty: Bool { failures.isEmpty }

    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private static func sanitized(_ fields: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in fields where safeFields.contains(key) {
            if key == "tree" {
                result[key] = value.components(separatedBy: " | ").map { node in
                    var redacted = node
                    if let classes = redacted.range(of: " classes=["),
                       let length = redacted.range(of: "] staticLength=", range: classes.upperBound..<redacted.endIndex) {
                        redacted.replaceSubrange(classes.upperBound..<length.lowerBound, with: "redacted")
                    }
                    if let preview = redacted.range(of: " preview=") {
                        redacted = String(redacted[..<preview.lowerBound]) + " preview=[redacted]"
                    }
                    return redacted
                }.joined(separator: " | ")
            } else {
                result[key] = value
            }
        }
        return result
    }
}
