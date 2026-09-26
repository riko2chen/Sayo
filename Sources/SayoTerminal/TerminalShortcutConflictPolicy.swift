import Foundation
import SayoCore

/// Keeps user-facing Sayo shortcuts separate from the keystrokes Sayo relays
/// inside shells and supported CLI editors.
public enum TerminalShortcutConflictPolicy {
    public static let shellRelayKeys = ["ctrl+x", "ctrl+r"]

    public static func validateGlobalShortcuts(
        _ shortcuts: [Shortcut],
        shellIntegrationInstalled: Bool,
        cliShortcuts: [CLIEditorProgram: String]
    ) throws {
        let keys = Set(shortcuts.compactMap(CLIShortcut.key(for:)))

        if shellIntegrationInstalled,
           let conflict = shellRelayKeys.first(where: keys.contains) {
            throw TerminalShortcutConflict.shell(key: conflict)
        }

        for program in CLIEditorProgram.allCases {
            guard let key = cliShortcuts[program], !key.isEmpty, keys.contains(key) else { continue }
            throw TerminalShortcutConflict.cli(program: program, key: key)
        }
    }

    public static func validateCLIShortcut(
        _ key: String,
        program: CLIEditorProgram,
        globalShortcuts: [Shortcut]
    ) throws {
        guard globalShortcuts.contains(where: { CLIShortcut.key(for: $0) == key }) else { return }
        throw TerminalShortcutConflict.sayo(program: program, key: key)
    }
}

public enum TerminalShortcutConflict: LocalizedError, Equatable {
    case shell(key: String)
    case cli(program: CLIEditorProgram, key: String)
    case sayo(program: CLIEditorProgram, key: String)

    public var errorDescription: String? {
        switch self {
        case .shell(let key):
            return "\(CLIShortcut.label(key)) is used internally by the Shell integration. Choose a different Sayo shortcut. / \(CLIShortcut.label(key)) 是 Shell 集成的内部转发键，请选择其他 Sayo 快捷键。"
        case .cli(let program, let key):
            return "\(CLIShortcut.label(key)) is used internally by \(program.name). Choose a different Sayo shortcut. / \(CLIShortcut.label(key)) 是 \(program.name) 的内部转发键，请选择其他 Sayo 快捷键。"
        case .sayo(let program, let key):
            return "\(CLIShortcut.label(key)) is already a Sayo global shortcut. Choose a different \(program.name) internal shortcut. / \(CLIShortcut.label(key)) 已是 Sayo 全局快捷键，请为 \(program.name) 选择其他内部快捷键。"
        }
    }
}
