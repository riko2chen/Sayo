import AppKit
import ApplicationServices
import Foundation
import SayoCore

public struct TerminalForegroundCommand: Equatable, Sendable {
    public let program: CLIEditorProgram
    public let tty: String?

    public init(program: CLIEditorProgram, tty: String?) {
        self.program = program
        self.tty = tty
    }
}

public enum TerminalForegroundRoute: Equatable, Sendable {
    case cli(TerminalForegroundCommand)
    case shell
    case unknown
}

struct TerminalProcessRecord: Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let processGroupID: pid_t
    let foregroundProcessGroupID: pid_t
    let tty: String
    let command: String
    let arguments: String
}

public enum TerminalForegroundProcessDetector {
    public static func detect(in application: NSRunningApplication) -> TerminalForegroundRoute {
        guard let records = processSnapshot() else { return .unknown }
        let context = accessibilityContext(for: application.processIdentifier)
        return detect(
            records: records,
            terminalPID: application.processIdentifier,
            focusedTTY: tty(in: context.value),
            focusedText: context.value,
            focusedTitle: context.title
        )
    }

    static func detect(
        records: [TerminalProcessRecord],
        terminalPID: pid_t,
        focusedTTY: String?,
        focusedText: String = "",
        focusedTitle: String = ""
    ) -> TerminalForegroundRoute {
        var descendants: Set<pid_t> = [terminalPID]
        var changed = true
        while changed {
            changed = false
            for record in records where descendants.contains(record.parentPID) && !descendants.contains(record.pid) {
                descendants.insert(record.pid)
                changed = true
            }
        }

        let terminalRecords = records.filter { descendants.contains($0.pid) }
        let foreground = terminalRecords.filter {
            $0.tty != "??" && $0.tty != "-" && $0.foregroundProcessGroupID > 0
                && $0.processGroupID == $0.foregroundProcessGroupID
        }
        let candidates = foreground.compactMap { record -> (TerminalProcessRecord, CLIEditorProgram)? in
            guard let program = program(for: record) else { return nil }
            return (record, program)
        }

        // Ghostty retains scrollback in AXValue, including stale "Last login … on
        // ttysNNN" lines. Its focused window title follows the running full-screen
        // CLI, so a supported title is stronger evidence than a scrollback TTY.
        if let titledProgram = program(inTitle: focusedTitle) {
            let matches = candidates.filter { $0.1 == titledProgram }
            let ttys = Set(matches.map(\.0.tty))
            if !matches.isEmpty {
                return .cli(.init(program: titledProgram, tty: ttys.count == 1 ? ttys.first : nil))
            }
        }

        if let focusedTTY {
            return route(for: candidates.filter { $0.0.tty == focusedTTY }, tty: focusedTTY)
        }

        let mentionedPrograms = Set(candidates.map(\.1).filter { program in
            switch program {
            case .codex: return focusedText.localizedCaseInsensitiveContains("codex")
            case .claude: return focusedText.localizedCaseInsensitiveContains("claude")
            case .agy:
                return focusedText.localizedCaseInsensitiveContains("agy")
                    || focusedText.localizedCaseInsensitiveContains("antigravity")
            }
        })
        if mentionedPrograms.count == 1, let program = mentionedPrograms.first,
           let tty = candidates.first(where: { $0.1 == program })?.0.tty {
            return .cli(.init(program: program, tty: tty))
        }

        let sessionTTYs = Set(terminalRecords.map(\.tty).filter { $0 != "??" && $0 != "-" })
        if sessionTTYs.count == 1, let tty = sessionTTYs.first {
            return route(for: candidates.filter { $0.0.tty == tty }, tty: tty)
        }

        // No supported foreground CLI exists in any of this terminal application's
        // sessions, so the focused session can safely use the shell widget route.
        return candidates.isEmpty ? .shell : .unknown
    }

    private static func route(
        for candidates: [(TerminalProcessRecord, CLIEditorProgram)],
        tty: String
    ) -> TerminalForegroundRoute {
        let programs = Set(candidates.map(\.1))
        if programs.isEmpty { return .shell }
        guard programs.count == 1, let program = programs.first else { return .unknown }
        return .cli(.init(program: program, tty: tty))
    }

    static func parseProcessSnapshot(_ output: String) -> [TerminalProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 6, whereSeparator: \.isWhitespace)
            guard fields.count == 7,
                  let pid = pid_t(fields[0]),
                  let parentPID = pid_t(fields[1]),
                  let processGroupID = pid_t(fields[2]),
                  let foregroundProcessGroupID = pid_t(fields[3])
            else { return nil }
            return TerminalProcessRecord(
                pid: pid,
                parentPID: parentPID,
                processGroupID: processGroupID,
                foregroundProcessGroupID: foregroundProcessGroupID,
                tty: String(fields[4]),
                command: String(fields[5]),
                arguments: String(fields[6])
            )
        }
    }

    private static func processSnapshot() -> [TerminalProcessRecord]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-axo", "pid=,ppid=,pgid=,tpgid=,tty=,comm=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parseProcessSnapshot(String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    private static func program(for record: TerminalProcessRecord) -> CLIEditorProgram? {
        let launchTokens = [record.command] + record.arguments.split(whereSeparator: \.isWhitespace).prefix(5).map(String.init)
        let components = launchTokens.flatMap { token in
            token.lowercased().split(separator: "/").map(String.init)
        }.map { name in
            [".js", ".mjs", ".cjs", ".exe"].reduce(name) { result, suffix in
                result.hasSuffix(suffix) ? String(result.dropLast(suffix.count)) : result
            }
        }
        if components.contains(where: { $0 == "codex" || $0.hasPrefix("codex-") }) { return .codex }
        if components.contains(where: { $0 == "claude" || $0.hasPrefix("claude-code") }) { return .claude }
        if components.contains(where: { $0 == "agy" || $0.hasPrefix("antigravity") }) { return .agy }
        return nil
    }

    private static func program(inTitle title: String) -> CLIEditorProgram? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.range(of: #"(?:^|\W)codex(?:\W|$)"#, options: .regularExpression) != nil { return .codex }
        if normalized.range(of: #"(?:^|\W)claude(?:\W|$)"#, options: .regularExpression) != nil { return .claude }
        if normalized.range(of: #"(?:^|\W)agy(?:\W|$)|antigravity"#, options: .regularExpression) != nil { return .agy }
        return nil
    }

    private static func accessibilityContext(for pid: pid_t) -> (value: String, title: String) {
        let application = AXUIElementCreateApplication(pid)
        var value = ""
        var title = ""
        if let focused: AXUIElement = attribute(application, kAXFocusedUIElementAttribute as CFString),
           let focusedValue: String = attribute(focused, kAXValueAttribute as CFString) {
            value = focusedValue
        }
        if let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute as CFString),
           let windowTitle: String = attribute(window, kAXTitleAttribute as CFString) {
            title = windowTitle
        }
        return (value, title)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }

    static func tty(in text: String) -> String? {
        let pattern = #"(?:\bon\s+|/dev/)(ttys[0-9]+|tty[0-9A-Za-z._-]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).last.flatMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
