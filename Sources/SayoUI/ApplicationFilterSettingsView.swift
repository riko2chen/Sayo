import AppKit
import Foundation
import SwiftUI
import SayoCore

struct ApplicationFilterSettingsView: View {
    @Binding var mode: ApplicationFilterMode
    @Binding var selectedBundleIDs: [String]
    let language: InterfaceLanguage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var runningApplications: [SelectableApplication] = []
    @State private var installedApplications: [SelectableApplication] = []
    @State private var scanningInstalledApplications = false
    @State private var availablePage = 0
    @State private var selectedPage = 0
    @State private var availableTargeted = false
    @State private var selectedTargeted = false
    private let pageSize = 20

    private var catalog: [SelectableApplication] {
        (runningApplications + installedApplications).uniquedByBundleIdentifier().sortedByName()
    }

    private var availableApps: [SelectableApplication] {
        catalog.filter { !selectedBundleIDs.contains($0.id) }
    }

    private var selectedApps: [SelectableApplication] {
        let known = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        return Array(Set(selectedBundleIDs)).map { id in
            known[id] ?? SelectableApplication(
                bundleIdentifier: id,
                name: id,
                url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            )
        }.sortedByName()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The settings page title already names this section.
            Text(mode == .blacklist
                ? t("Sayo works everywhere except the apps you select.", "Sayo 会在除所选应用之外的所有应用中工作。")
                : t("Sayo works only in the apps you select.", "Sayo 只会在你选择的应用中工作。"))
                .font(.system(size: 12)).foregroundStyle(SayoStyle.muted)

            HStack(spacing: 12) {
                SayoSegmentedControl(title: t("App access mode", "应用范围模式"),
                    options: [ApplicationFilterMode.blacklist, .whitelist], selection: $mode) {
                        $0 == .blacklist ? t("Blacklist", "黑名单") : t("Whitelist", "白名单")
                    }
                .frame(width: 250)

                Spacer()

                Text(t("Selected: \(selectedBundleIDs.count)", "已选择：\(selectedBundleIDs.count)"))
                    .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                Button(t("Clear all", "全部清除"), role: .destructive) { selectedBundleIDs.removeAll() }
                    .disabled(selectedBundleIDs.isEmpty)
            }

            Text(t("Click or drag apps between columns. 20 apps per page.", "点按或拖动应用可在两列之间移动，每页 20 个。"))
                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)

            HStack(alignment: .top, spacing: 12) {
                appColumn(title: t("Available apps", "可选应用"), apps: availableApps,
                          page: $availablePage, selected: false, targeted: $availableTargeted)
                appColumn(title: mode == .blacklist ? t("Blacklist", "黑名单") : t("Whitelist", "白名单"),
                          apps: selectedApps, page: $selectedPage, selected: true, targeted: $selectedTargeted)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32),
                       value: selectedBundleIDs)
        }
        .onChange(of: mode) { _, _ in
            availablePage = 0
            selectedPage = 0
        }
        .onChange(of: availableApps.count) { _, count in
            availablePage = min(availablePage, max(0, (count - 1) / pageSize))
        }
        .onChange(of: selectedApps.count) { _, count in
            selectedPage = min(selectedPage, max(0, (count - 1) / pageSize))
        }
        .onAppear {
            scanRunningApplications()
            scanInstalledApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            scanRunningApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            scanRunningApplications()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scanRunningApplications()
            scanInstalledApplications()
        }
    }

    private func appColumn(title: String, apps: [SelectableApplication], page: Binding<Int>,
                           selected: Bool, targeted: Binding<Bool>) -> some View {
        let pageCount = max(1, (apps.count + pageSize - 1) / pageSize)
        let currentPage = min(page.wrappedValue, pageCount - 1)
        let runningIDs = Set(runningApplications.map(\.id))
        let running = apps.filter { runningIDs.contains($0.id) }
        let other = apps.filter { !runningIDs.contains($0.id) }
        let visibleApps = Array((running + other).dropFirst(currentPage * pageSize).prefix(pageSize))
        let visibleRunning = visibleApps.filter { runningIDs.contains($0.id) }
        let visibleOther = visibleApps.filter { !runningIDs.contains($0.id) }
        return VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(apps.count)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SayoStyle.muted)
            }.padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if visibleApps.isEmpty {
                        Text(selected
                             ? t("Click or drag apps here to add them.", "点按左侧应用或拖到此处添加。")
                             : scanningInstalledApplications
                                ? t("Scanning applications…", "正在扫描应用…")
                                : t("No available apps.", "暂无可选应用。"))
                            .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .transition(.opacity)
                    }
                    if !visibleRunning.isEmpty || (currentPage == 0 && !apps.isEmpty) {
                        sectionHeader(t("Running now", "正在运行"), count: running.count)
                        if visibleRunning.isEmpty {
                            Text(t("No running apps in this list.", "此列表暂无正在运行的应用。"))
                                .font(.system(size: 11)).foregroundStyle(SayoStyle.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        ForEach(visibleRunning) { app in appRow(app, selected: selected) }
                    }
                    if !visibleOther.isEmpty {
                        sectionHeader(t("All apps (excluding running)", "全部应用（不含正在运行）"), count: other.count)
                        ForEach(visibleOther) { app in appRow(app, selected: selected) }
                    }
                }.padding(4)
            }
            .frame(height: 330)
            .id(currentPage)
            Divider()
            HStack {
                Button { page.wrappedValue = currentPage - 1 } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)
                .accessibilityLabel(t("Previous page", "上一页"))
                Spacer(minLength: 4)
                Text(t("\(currentPage + 1) / \(pageCount)", "第 \(currentPage + 1) / \(pageCount) 页"))
                    .font(.system(size: 11)).monospacedDigit()
                Spacer(minLength: 4)
                Button { page.wrappedValue = currentPage + 1 } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage + 1 >= pageCount)
                .accessibilityLabel(t("Next page", "下一页"))
            }.controlSize(.small).padding(10)
        }
        .frame(maxWidth: .infinity)
        .background(SayoStyle.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(targeted.wrappedValue ? SayoStyle.accent : SayoStyle.line,
                                                         lineWidth: targeted.wrappedValue ? 2 : 1))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            let source = selected ? availableApps : selectedApps
            let validIDs = Set(source.map(\.id))
            let ids = items.compactMap { item -> String? in
                guard item.hasPrefix("sayo-app:" ) else { return nil }
                let id = String(item.dropFirst("sayo-app:".count))
                return validIDs.contains(id) ? id : nil
            }
            for id in ids { move(id, toSelected: selected) }
            return !ids.isEmpty
        } isTargeted: { targeted.wrappedValue = $0 }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold))
            Spacer()
            Text("\(count)").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(SayoStyle.muted)
        .padding(.horizontal, 8).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SayoStyle.line.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
    }

    private func appRow(_ app: SelectableApplication, selected: Bool) -> some View {
        Button {
            move(app.id, toSelected: !selected)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: icon(for: app)).resizable().interpolation(.high)
                    .frame(width: 26, height: 26)
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: selected ? "arrow.left.circle" : "arrow.right.circle")
                    .foregroundStyle(SayoStyle.muted)
            }
            .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t(selected ? "Remove \(app.name)" : "Add \(app.name)", selected ? "移除 \(app.name)" : "添加 \(app.name)"))
        .draggable("sayo-app:\(app.id)")
        .transition(reduceMotion ? .opacity : .offset(x: selected ? -32 : 32).combined(with: .opacity))
    }

    private func icon(for app: SelectableApplication) -> NSImage {
        guard let url = app.url else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func move(_ bundleIdentifier: String, toSelected: Bool) {
        if toSelected {
            if !selectedBundleIDs.contains(bundleIdentifier) { selectedBundleIDs.append(bundleIdentifier) }
        } else {
            selectedBundleIDs.removeAll { $0 == bundleIdentifier }
        }
    }

    private func scanRunningApplications() {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleIdentifier = application.bundleIdentifier,
                      bundleIdentifier != ownBundleIdentifier,
                      let url = application.bundleURL else { return nil }
                return SelectableApplication(
                    bundleIdentifier: bundleIdentifier,
                    name: application.localizedName ?? url.deletingPathExtension().lastPathComponent,
                    url: url
                )
            }
            .uniquedByBundleIdentifier()
            .sortedByName()
    }

    private func scanInstalledApplications() {
        guard !scanningInstalledApplications else { return }
        scanningInstalledApplications = true
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        Task {
            let applications = await Task.detached(priority: .userInitiated) {
                ApplicationCatalog.installedApplications(excluding: ownBundleIdentifier)
            }.value
            installedApplications = applications
            scanningInstalledApplications = false
        }
    }

    private func t(_ english: String, _ simplifiedChinese: String) -> String {
        language.text(english, simplifiedChinese)
    }
}

private struct SelectableApplication: Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL?
    var id: String { bundleIdentifier }
}

private enum ApplicationCatalog {
    static func installedApplications(excluding ownBundleIdentifier: String?) -> [SelectableApplication] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var applications: [SelectableApplication] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      bundleIdentifier != ownBundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                applications.append(.init(bundleIdentifier: bundleIdentifier, name: name, url: url))
            }
        }
        return applications.uniquedByBundleIdentifier().sortedByName()
    }
}

private extension Array where Element == SelectableApplication {
    func uniquedByBundleIdentifier() -> [SelectableApplication] {
        var seen = Set<String>()
        return filter { seen.insert($0.bundleIdentifier).inserted }
    }

    func sortedByName() -> [SelectableApplication] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
