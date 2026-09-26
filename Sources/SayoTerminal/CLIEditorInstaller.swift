import Foundation
import SayoCore

/// Installs process-scoped editor overrides in zsh. Never writes CLI preferences.
public struct CLIEditorInstaller {
    private let homeDirectory: URL
    private let cliURL: URL
    private let manager = FileManager.default

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                cliURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sayo")) {
        self.homeDirectory = homeDirectory
        self.cliURL = cliURL
    }

    public func isInstalled(_ program: CLIEditorProgram) throws -> Bool {
        let contents = try readRC()
        // Presence controls Reset even if a helper is missing or the block is from an older version.
        return try blockRange(program, in: contents) != nil
    }

    public func install(_ program: CLIEditorProgram) throws {
        guard manager.isExecutableFile(atPath: cliURL.path) else { throw InstallerError.missingCLI(cliURL.path) }
        // Claude splits the editor command on spaces rather than shell-parsing it.
        guard !editorURL(program).path.contains(where: { $0.isWhitespace }) else {
            throw CLIEditorInstallError("The editor path contains whitespace. / 编辑器路径包含空格，当前 CLI 无法正确解析。")
        }
        let original = try readRC()
        let range = try blockRange(program, in: original)
        var updated = original
        if let range { updated.replaceSubrange(range, with: block(program) + "\n") }
        else {
            if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
            updated += block(program) + "\n"
        }
        // Generated helpers are Sayo-owned; no preferences under .gemini/.claude/.codex are changed.
        let helper = "#!/bin/sh\n# Sayo external editor. Claude's GUI adapter name intentionally contains code.\nexec "
            + quote(cliURL.path) + " edit \"$@\"\n"
        let helperURL = editorURL(program)
        if manager.fileExists(atPath: helperURL.path), try String(contentsOf: helperURL, encoding: .utf8) != helper {
            try manager.copyItem(at: helperURL, to: helperURL.appendingPathExtension("sayo-backup-" + UUID().uuidString))
        }
        try write(helper, to: helperURL, permissions: 0o700)
        if original != updated { try saveRC(updated) }
    }

    public func reset(_ program: CLIEditorProgram) throws {
        var contents = try readRC()
        guard let range = try blockRange(program, in: contents) else { return }
        contents.removeSubrange(range)
        try saveRC(contents)
        // Keep shared helpers: another CLI or an existing session may still use them.
    }

    private var rcURL: URL { homeDirectory.appendingPathComponent(".zshrc") }

    private func editorURL(_ program: CLIEditorProgram) -> URL {
        homeDirectory.appendingPathComponent(".local/bin/" + (program == .claude ? "sayo-claude-code-editor" : "sayo-editor"))
    }

    private func block(_ program: CLIEditorProgram) -> String {
        let name = program.rawValue
        let editor = quote(editorURL(program).path)
        let shortcutFile = quote(CLIShortcutSettings(homeDirectory: homeDirectory).codexOverrideURL.path)
        let invocation: String
        if program == .codex {
            invocation = """
            local sayo_editor_key
            if [[ -f \(shortcutFile) ]]; then
              sayo_editor_key=$(<\(shortcutFile))
              if [[ "$sayo_editor_key" == disabled ]]; then
                VISUAL=\(editor) EDITOR=\(editor) command codex -c 'tui.keymap.global.open_external_editor=[]' "$@"
              else
                VISUAL=\(editor) EDITOR=\(editor) command codex -c "tui.keymap.global.open_external_editor=\\\"${sayo_editor_key//+/-}\\\"" "$@"
              fi
            else
              VISUAL=\(editor) EDITOR=\(editor) command codex "$@"
            fi
            """
        } else {
            invocation = "VISUAL=\(editor) EDITOR=\(editor) command \(name) \"$@\""
        }
        return """
        # >>> Sayo CLI Editor: \(name) >>>
        # Open a new terminal tab after installing or resetting. Existing custom commands take priority.
        if (( ! ${+aliases[\(name)]} && ! ${+functions[\(name)]} )); then
          function \(name)() {
            \(invocation)
          }
        fi
        # <<< Sayo CLI Editor: \(name) <<<
        """
    }

    private func blockRange(_ program: CLIEditorProgram, in contents: String) throws -> Range<String.Index>? {
        let start = "# >>> Sayo CLI Editor: \(program.rawValue) >>>"
        let end = "# <<< Sayo CLI Editor: \(program.rawValue) <<<"
        let starts = contents.components(separatedBy: start).count - 1
        let ends = contents.components(separatedBy: end).count - 1
        guard starts == ends, starts <= 1 else { throw CLIEditorInstallError("Invalid Sayo markers in .zshrc; no changes made. / .zshrc 的 Sayo 标记不完整，未修改配置。") }
        guard starts == 1 else { return nil }
        guard let lower = contents.range(of: start), let upper = contents.range(of: end), lower.upperBound <= upper.lowerBound else {
            throw CLIEditorInstallError("Invalid Sayo block order in .zshrc. / .zshrc 的 Sayo 配置块顺序无效。")
        }
        var endIndex = upper.upperBound
        if endIndex < contents.endIndex && contents[endIndex] == "\n" { endIndex = contents.index(after: endIndex) }
        return lower.lowerBound..<endIndex
    }

    private func readRC() throws -> String {
        do { _ = try manager.attributesOfItem(atPath: rcURL.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return "" }
        return try String(contentsOf: rcURL, encoding: .utf8)
    }

    private func saveRC(_ contents: String) throws {
        let target = rcURL.resolvingSymlinksInPath()
        var permissions: Int = 0o600
        if manager.fileExists(atPath: target.path) {
            permissions = (try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            try manager.copyItem(at: target, to: target.appendingPathExtension("sayo-backup-" + UUID().uuidString))
        }
        try write(contents, to: target, permissions: permissions)
    }

    private func write(_ contents: String, to url: URL, permissions: Int) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct CLIEditorInstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
