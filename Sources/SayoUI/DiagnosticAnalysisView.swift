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
            Picker(t("Record type", "记录类型"), selection: $category) {
                ForEach(DiagnosticCategory.allCases, id: \.self) { Text($0.title(language)).tag($0) }
            }.pickerStyle(.segmented)
                .onChange(of: category) { application = ""; outcome = ""; selectedID = nil }
            HStack {
                Picker(t("Application", "应用"), selection: $application) {
                    Text(t("All applications", "全部应用")).tag("")
                    ForEach(applications, id: \.key) { Text($0.name).tag($0.key) }
                }.frame(maxWidth: 230)
                if category == .invocation {
                    Picker(t("Outcome", "操作结果"), selection: $outcome) {
                        Text(t("All outcomes", "全部结果")).tag("")
                        Text(t("Original kept", "保留原文")).tag("inserted_at_caret")
                        Text(t("Failed", "操作失败")).tag("failed")
                        Text(t("Replaced", "替换成功")).tag("replaced")
                    }.frame(maxWidth: 210)
                }
                Spacer(minLength: 0)
                Button { model.refreshDiagnostics() } label: { Image(systemName: "arrow.clockwise") }
                    .help(t("Refresh records", "刷新记录"))
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
                        Text(t("No matching records.", "没有符合条件的记录。")).font(.headline)
                        Text(t("Use Sayo once in the app you want to check.\nReturn here to view the record.\nEarlier records are under Input checks and Older records.", "在要检查的应用中使用一次。\n再回到这里查看记录。\n较早记录可在其他分类查看。"))
                            .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 365).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SayoStyle.green.opacity(0.15)))
            if model.diagnosticAnalysis.unreadableLines > 0 {
                Text(t("Skipped \(model.diagnosticAnalysis.unreadableLines) unreadable records.", "已跳过 \(model.diagnosticAnalysis.unreadableLines) 条无法读取的记录。"))
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(t("Recording settings", "记录设置")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("All saved records are analyzed.\nEach attempt has a number that resets on restart.\nUp to four 512 KB files are kept.\nNew records replace the oldest when full.", "分析全部保留记录。\n每次操作有独立编号，重启后重置。\n最多保留四个 512 KB 文件。\n文件满后，替换最早的记录。"))
                    Toggle(t("Keep records", "保留记录"), isOn: $model.settings.retainDiagnosticLogs)
                    Text(t("Turning this off stops new records.\nExisting records can still be exported or removed manually.", "关闭后，不再添加记录。\n已有记录仍可导出或手动删除。"))
                        .foregroundStyle(SayoStyle.muted)
                    Toggle(t("Record text snippets", "记录文字"), isOn: Binding(
                        get: { model.diagnosticTextSnippetsEnabled },
                        set: { model.diagnosticTextSnippetsEnabled = $0; model.diagnosticSnippetsAction?($0) }
                    )).disabled(!model.settings.retainDiagnosticLogs)
                    Text(t("Off by default. Records up to 120 characters.\nTurns off again when Sayo restarts.\nExisting text snippets are kept.", "默认关闭，最多记录 120 字符。\n重启后，自动关闭此选项。\n已有文字片段不会删除。"))
                        .foregroundStyle(SayoStyle.muted)
                    Text(model.diagnosticPath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button(t("Show files", "打开文件")) { model.openDiagnostics() }
                        Button(t("Export all…", "导出全部")) { model.exportDiagnosticsAction?() }
                    }
                }.font(.system(size: 11)).padding(.top, 8)
            }.font(.system(size: 12))
        }
        .sheet(isPresented: $showingAIDiagnosticResult) {
            VStack(alignment: .leading, spacing: 16) {
                Text(t("Troubleshooting result", "排查结果")).font(.title2.bold())
                ScrollView {
                    Text(model.aiDiagnosticResult)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(SayoStyle.paper, in: RoundedRectangle(cornerRadius: 9))
                Text(t("The file contains the analysis and the records sent.\nSensitive details in those records are hidden.", "文件包含分析结果和发送的记录。\n发送记录中的敏感信息已隐藏。"))
                    .font(.caption).foregroundStyle(SayoStyle.muted)
                HStack {
                    Button(t("Save result…", "保存结果")) { model.saveAIDiagnosticReport() }
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
                    Text(t("Assisted troubleshooting", "智能排查"))
                        .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                    Text(t(
                        "This feature is experimental.\nFind failed attempts from the last 30 minutes.\nSelect records, then allow them to be sent for analysis.\nSelected records go to your current service.\nSensitive details are hidden before sending.\nOriginal text, rewrites, keys, and instructions are excluded.", "此功能仍在试用。\n先查找近 30 分钟的失败记录。\n勾选记录后，可授权发送分析。\n所选记录会发送给当前服务。\n发送前会隐藏敏感信息。\n不发送原文、结果、密钥和改写要求。"
                    ))
                    .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    model.prepareAIDiagnostics()
                } label: {
                    Text(model.aiDiagnosticCandidates == nil
                         ? t("Find failed attempts", "查找失败") : t("Search again", "重新查找"))
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
                    Button(t("View result", "查看结果")) { showingAIDiagnosticResult = true }
                        .accessibilityIdentifier("view-ai-diagnosis")
                    Button(t("Report a problem", "反馈问题")) { model.openAIDiagnosticIssue() }
                        .accessibilityIdentifier("report-ai-diagnosis-issue")
                    Spacer()
                }
                Text(t("Open a feedback draft on GitHub.\nIt includes the analysis and selected records.\nSensitive details are hidden. Review it before submitting.", "在 GitHub 打开反馈草稿。\n包含分析结果和所选记录。\n敏感信息已隐藏，请检查后提交。"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
            }
        }
    }
    private func aiDiagnosticSelection(_ candidates: AIDiagnosticEvidence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Selected \(model.aiDiagnosticSelectedCases.count) of \(candidates.failures.count)", "已选 \(model.aiDiagnosticSelectedCases.count) / \(candidates.failures.count) 条"))
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
                       : t("Allow analysis", "授权分析")) {
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
                    Text(t("This older or incomplete record cannot show every step.", "记录较旧或不完整，无法还原过程。"))
                        .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                }
                HStack {
                    Text(group.category == .invocation ? t("Steps", "操作过程") : t("Newest first", "最新在上")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(t("Export this record…", "导出本次")) { model.exportDiagnosticGroupAction?(group) }
                        .font(.system(size: 10))
                }
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(displayedEvents(group).enumerated()), id: \.offset) { index, event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1) · " + time(event.date, date: false) + (event.fields["elapsedMs"].map { " · +\($0) ms" } ?? ""))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(SayoStyle.muted)
                            Text(event.explanation(language)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup(t("Details", "详细信息")) {
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
