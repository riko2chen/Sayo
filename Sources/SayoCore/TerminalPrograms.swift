import Foundation

/// CLIs whose external-editor action Sayo can take over. Shared by the installer, the
/// foreground-process detector, and settings so names and lists cannot drift apart.
public enum CLIEditorProgram: String, CaseIterable, Hashable, Sendable {
    case agy, codex, claude

    public var name: String {
        switch self {
        case .agy: return "Antigravity CLI"
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        }
    }
}

/// Shells with a Sayo line-editor integration.
public enum TerminalShell: String, CaseIterable, Codable, Identifiable, Sendable {
    case zsh
    case bash
    case fish

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .zsh: return "Zsh"
        // macOS ships Bash 3.2, whose Readline cannot expose the edit buffer.
        case .bash: return "Bash 4+"
        case .fish: return "fish"
        }
    }
}
