import SwiftUI
import SayoCore

/// Local, evidence-based grouping. Old uncorrelated records are never presented as a traced invocation.
struct DiagnosticAnalysisView: View {
    @ObservedObject var model: AppViewModel
    @State private var category: DiagnosticCategory = .invocation
    @State private var application = ""
    @State private var outcome = ""
    @State private var selectedID: String?
    @State private var showingAIDiagnosticResult = false
    private var language: InterfaceLanguage { model.settings.interfaceLanguage }
    private func t(_ en: String, _ zh: String) -> String { model.text(en, zh) }
    private var categoryGroups: [DiagnosticGroup] { model.diagnosticAnalysis.groups.filter { $0.category == category } }
    private var applications: [(key: String, name: String)] {
        var names: [String: String] = [:]
        for group in categoryGroups { names[group.applicationKey] = group.application }
        return names.map { (key: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var groups: [DiagnosticGroup] {
        categoryGroups.filter { (application.isEmpty || $0.applicationKey == application) && (outcome.isEmpty || $0.outcome == outcome) }
    }
    private var selected: DiagnosticGroup? { groups.first { $0.id == selectedID } ?? groups.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            aiDiagnosis
            Picker(t("Category", "记录分类"), selection: $category) {
                ForEach(DiagnosticCategory.allCases, id: \.self) { Text($0.title(language)).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: category) { application = ""; outcome = ""; selectedID = nil }
            HStack {
                Picker(t("Application", "应用"), selection: $application) {
                    Text(t("All applications", "全部应用")).tag("")
                    ForEach(applications, id: \.key) { Text($0.name).tag($0.key) }
                }.frame(maxWidth: 230)
                if category == .invocation {
                    Picker(t("Outcome", "结果"), selection: $outcome) {
                        Text(t("All outcomes", "全部结果")).tag("")
                        Text(t("Inserted", "发生追加")).tag("inserted_at_caret")
                        Text(t("Failed", "操作失败")).tag("failed")
                        Text(t("Replaced", "替换成功")).tag("replaced")
                    }.frame(maxWidth: 210)
                }
                Spacer(minLength: 0)
                Button { model.refreshDiagnostics() } label: { Image(systemName: "arrow.clockwise") }
                    .help(t("Refresh", "刷新分析"))
            }.font(.system(size: 12))
            Text(model.diagnosticStatus).font(.system(size: 10, design: .monospaced)).foregroundStyle(SayoStyle.muted)
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(groups) { group in
                            Button { selectedID = group.id } label: { row(group) }
                                .buttonStyle(.plain)
                        }
                    }.padding(8)
                }.frame(width: 190)
                Divider()
                if let selected {
                    detail(selected).id(selected.id)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "text.magnifyingglass").font(.title2)
                        Text(t("No matching records", "暂无匹配记录")).font(.headline)
                        Text(t("Invoke Sayo in the target app, then return here; earlier logs remain under Input observations and Unlinked history.", "在目标应用唤起 Sayo 后返回这里；旧日志仍可在「输入观察」和「历史未关联记录」查看。"))
                            .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 365).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SayoStyle.green.opacity(0.15)))
            if model.diagnosticAnalysis.unreadableLines > 0 {
                Text(t("Skipped \(model.diagnosticAnalysis.unreadableLines) unreadable log lines.", "已跳过 \(model.diagnosticAnalysis.unreadableLines) 条无法解析的日志。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(t("Recording and export", "记录选项与导出")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("Sayo analyzes all retained files, gives each invocation a restart-scoped ID, and keeps four rotating 512 KB files.", "Sayo 会分析全部保留日志，为每次唤起分配随重启重置的 ID，并轮转保留四个 512 KB 文件。"))
                    Toggle(t("Retain diagnostic logs", "保留诊断日志"), isOn: $model.settings.retainDiagnosticLogs)
                    Text(t("Disabling stops new records while keeping existing files available for export or removal.", "关闭后将停止新增记录，已有文件仍可导出或手动删除。"))
                        .foregroundStyle(SayoStyle.muted)
                    Toggle(t("Include text snippets for this session (up to 120 characters)", "本次运行记录文本片段（最多 120 字符）"), isOn: Binding(
                        get: { model.diagnosticTextSnippetsEnabled },
                        set: { model.diagnosticTextSnippetsEnabled = $0; model.diagnosticSnippetsAction?($0) }
                    )).disabled(!model.settings.retainDiagnosticLogs)
                    Text(t("Text logging is off by default and resets on restart without removing existing snippets.", "正文记录默认关闭且重启后重置，但不会删除已有片段。"))
                        .foregroundStyle(SayoStyle.muted)
                    Text(model.diagnosticPath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button(t("Open log folder", "打开日志文件夹")) { model.openDiagnostics() }
                        Button(t("Export all retained logs…", "导出全部保留日志…")) { model.exportDiagnosticsAction?() }
                    }
                }.font(.system(size: 11)).padding(.top, 8)
            }.font(.system(size: 12))
        }
        .sheet(isPresented: $showingAIDiagnosticResult) {
            VStack(alignment: .leading, spacing: 16) {
                Text(t("Analysis result", "分析结果")).font(.title2.bold())
                ScrollView {
                    Text(model.aiDiagnosticResult)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(SayoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
                Text(t("The saved file includes the analysis and the redacted evidence sent to the model.",
                       "保存的文件包含分析结果，以及发送给模型的脱敏数据。"))
                    .font(.caption).foregroundStyle(SayoStyle.muted)
                HStack {
                    Button(t("Save result file…", "保存结果文件…")) { model.saveAIDiagnosticReport() }
                    Spacer()
                    Button(t("Done", "完成")) { showingAIDiagnosticResult = false }
                        .keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 640, height: 480)
        }
    }
    private var aiDiagnosis: some View {
        SayoCard {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(t("AI DIAGNOSIS · EXPERIMENTAL", "AI 自诊断 · 实验性功能"))
                        .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                    Text(t(
                        "Scan failed cases from the past 30 minutes, then select which ones to analyze. Only after you authorize analysis will the redacted cases be sent to your configured language model. Input text, rewritten text, API keys, and prompts are excluded.",
                        "先检测过去 30 分钟内的失败案例，再勾选需要分析的案例。授权后才会将所选案例的脱敏数据发送给已配置的大模型，不包含输入原文、改写结果、API Key 和提示词。"
                    ))
                    .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    model.prepareAIDiagnostics()
                } label: {
                    Text(model.aiDiagnosticCandidates == nil
                         ? t("Scan failed cases", "检测错误案例") : t("Scan again", "重新检测"))
                }
                .disabled(model.aiDiagnosticRunning)
                .accessibilityIdentifier("start-ai-diagnosis")
            }
            if !model.aiDiagnosticStatus.isEmpty {
                Text(model.aiDiagnosticStatus)
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                    .textSelection(.enabled)
            }
            if let candidates = model.aiDiagnosticCandidates, !candidates.isEmpty, model.aiDiagnosticResult.isEmpty {
                aiDiagnosticSelection(candidates)
            }
            if !model.aiDiagnosticResult.isEmpty {
                Divider()
                HStack {
                    Button(t("View analysis result", "查看分析结果")) { showingAIDiagnosticResult = true }
                        .accessibilityIdentifier("view-ai-diagnosis")
                    Button(t("Report an issue to the author", "给作者提 issue")) { model.openAIDiagnosticIssue() }
                        .accessibilityIdentifier("report-ai-diagnosis-issue")
                    Spacer()
                }
                Text(t("Opens a GitHub draft containing the redacted analysis and selected cases. Review it on GitHub before submitting.",
                       "将在 GitHub 打开含脱敏分析结果与所选案例的 issue 草稿，由你检查后提交。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
        }
    }
    private func aiDiagnosticSelection(_ candidates: AIDiagnosticEvidence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Selected \(model.aiDiagnosticSelectedCases.count) of \(candidates.failures.count)",
                       "已选 \(model.aiDiagnosticSelectedCases.count) / \(candidates.failures.count) 个案例"))
                Spacer()
                Button(t("Select all", "全选")) { model.selectAllAIDiagnosticCases() }
                Button(t("Invert selection", "反选")) { model.invertAIDiagnosticSelection() }
            }.font(.system(size: 11))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(candidates.failures.enumerated()), id: \.offset) { index, failure in
                        Toggle(isOn: Binding(
                            get: { model.aiDiagnosticSelectedCases.contains(index) },
                            set: { model.selectAIDiagnosticCase(index, selected: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("#\(index + 1) · " + failure.application)
                                    .font(.system(size: 12, weight: .medium))
                                Text(time(DiagnosticEvent(timestamp: failure.failedAt, event: "", fields: [:]).date, date: true))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(SayoStyle.muted)
                                if let event = failure.events.last(where: { $0.event == "invocation_failed" || $0.event == "replacement_failed" }) {
                                    Text(DiagnosticEvent(timestamp: event.timestamp, event: event.event, fields: event.fields).explanation(language))
                                        .font(.system(size: 11)).foregroundStyle(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }.toggleStyle(.checkbox)
                            .accessibilityIdentifier("ai-diagnostic-case-\(index)")
                        Divider()
                    }
                }.padding(10)
            }
            .frame(height: min(200, CGFloat(candidates.failures.count) * 88))
            .background(SayoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 10) {
                if model.aiDiagnosticRunning { ProgressView().controlSize(.small) }
                Button(model.aiDiagnosticRunning
                       ? t("Analyzing…", "分析中…")
                       : t("Next: authorize analysis with the configured model", "下一步：授权使用已配置的大模型进行分析")) {
                    model.runAIDiagnostics()
                }
                .disabled(model.aiDiagnosticSelectedCases.isEmpty || model.aiDiagnosticRunning)
                .accessibilityIdentifier("authorize-ai-diagnosis")
            }
        }.disabled(model.aiDiagnosticRunning)
    }
    private func row(_ group: DiagnosticGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.category == .invocation ? "#\(group.ordinal ?? "—")" : group.category.title(language))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(SayoStyle.muted)
                Spacer()
                Text(time(group.category == .invocation ? group.startedAt : group.lastEventAt, date: false))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(SayoStyle.muted)
            }
            Text(group.application).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(group.summary(language)).font(.system(size: 11)).foregroundStyle(color(group)).lineLimit(2)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected?.id == group.id ? SayoStyle.green.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
    private func detail(_ group: DiagnosticGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(group.application).font(.system(size: 17, weight: .semibold))
                Text(time(group.category == .invocation ? group.startedAt : group.lastEventAt, date: true) + (group.category == .invocation ? " · " + DiagnosticEvent.triggerName(group.trigger, language) : ""))
                    .font(.system(size: 10)).foregroundStyle(SayoStyle.muted)
                Text(group.summary(language)).font(.system(size: 14, weight: .medium)).foregroundStyle(color(group))
                if group.fallbackReason != nil || group.outcome == "inserted_at_caret" {
                    Text(DiagnosticEvent.fallbackExplanation(group.fallbackReason, language))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                if group.outcome == "failed", let failure = group.events.last(where: { $0.event == "invocation_failed" || $0.event == "replacement_failed" }) {
                    Text(failure.explanation(language)).font(.system(size: 12)).foregroundStyle(.red)
                }
                if group.incomplete || group.category == .history {
                    Text(t("This incomplete or older record cannot be reconstructed into a full sequence.", "这条不完整或较旧的记录无法还原完整过程。"))
                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                }
                HStack {
                    Text(group.category == .invocation ? t("Timeline", "过程时间线") : t("Events · newest first", "事件 · 最新在上")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(t("Export this record…", "导出本次记录…")) { model.exportDiagnosticGroupAction?(group) }
                        .font(.system(size: 10))
                }
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(displayedEvents(group).enumerated()), id: \.offset) { index, event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1) · " + time(event.date, date: false) + (event.fields["elapsedMs"].map { " · +\($0) ms" } ?? ""))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(SayoStyle.muted)
                            Text(event.explanation(language)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup(t("Raw fields", "原始字段")) {
                                Text(event.rawText).font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.font(.system(size: 10)).foregroundStyle(SayoStyle.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider().opacity(0.5)
                    }
                }
            }.textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func displayedEvents(_ group: DiagnosticGroup) -> [DiagnosticEvent] {
        group.category == .invocation ? group.events.filter { $0.event != "bubble" } : Array(group.events.reversed())
    }
    private func color(_ group: DiagnosticGroup) -> Color {
        group.outcome == "failed" ? .red : group.outcome == "inserted_at_caret" ? .orange : SayoStyle.green
    }
    private func time(_ date: Date?, date includeDate: Bool) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter(); formatter.timeZone = .current
        formatter.dateFormat = includeDate ? "MM-dd HH:mm:ss ZZZZZ" : "HH:mm:ss"
        return formatter.string(from: date)
    }
}
