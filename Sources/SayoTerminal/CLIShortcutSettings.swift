import Foundation
import SayoCore

/// Native CLI bindings. JSON edits preserve unrelated settings; a journal permits
/// restoring only our change and detects subsequent user edits before overwriting.
public struct CLIShortcutSettings {
    private let home: URL
    private let manager = FileManager.default
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { home = homeDirectory }

    public var codexOverrideURL: URL { home.appendingPathComponent("Library/Application Support/Sayo/CLI/codex-shortcut") }
    private func stateURL(_ program: CLIEditorProgram) -> URL {
        home.appendingPathComponent("Library/Application Support/Sayo/CLI/\(program.rawValue)-shortcut.json")
    }
    private func configURL(_ program: CLIEditorProgram) -> URL {
        home.appendingPathComponent(program == .agy ? ".gemini/antigravity-cli/keybindings.json" : ".claude/keybindings.json")
    }
    public func status(_ program: CLIEditorProgram) throws -> (value: String, managed: Bool, description: String) {
        if program == .codex {
            let value = try read(codexOverrideURL).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            if value == "disabled" { return ("", true, "Unbound / 未绑定") }
            return (value ?? CLIShortcut.defaultKey, value != nil, value == nil ? "Ctrl+G (default / 默认)" : "Sayo: \(value!)")
        }
        let config = try object(configURL(program))
        let state = try object(stateURL(program))
        let keys: [String]
        if program == .agy {
            keys = config["edit.open_editor"] as? [String] ?? (config["edit.open_editor"] == nil ? ["ctrl+g"] : [])
        } else {
            var bindings: [String: String] = ["ctrl+g": "chat:externalEditor"]
            for block in try blocks(config) where block["context"] as? String == "Chat" {
                for (key, value) in block["bindings"] as? [String: Any] ?? [:] { bindings[key] = value as? String }
            }
            keys = bindings.filter { $0.value == "chat:externalEditor" }.map(\.key).sorted()
        }
        return (state["key"] as? String ?? (keys.sorted().first ?? ""), !state.isEmpty,
                keys.isEmpty ? "Unbound / 未绑定" : keys.joined(separator: ", "))
    }

    public static func validatedKey(_ input: String, program: CLIEditorProgram? = nil) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard CLIShortcut.isValid(key)
        else { throw CLIShortcutError("Use ctrl+letter, alt+letter, or f1–f12. Exit, flow-control, Tab and Return keys are reserved. / 请使用 ctrl+字母、alt+字母或 f1–f12；退出、流控制、Tab 和回车按键不可用。") }
        if program == .codex {
            guard CLIShortcut.codexOptions.contains(key) else {
                throw CLIShortcutError("Codex: use ctrl+g or f6–f12. Letter shortcuts can conflict with the native editor and prevent startup. / Codex 请使用 ctrl+g 或 f6–f12；字母组合可能与原生编辑操作冲突，导致无法启动。")
            }
        }
        return key
    }

    public func apply(_ program: CLIEditorProgram, key input: String) throws {
        let key = try Self.validatedKey(input, program: program)
        if program == .codex {
            try save(Data(key.utf8), to: codexOverrideURL)
            return
        }
        let url = configURL(program)
        var config = try object(url)
        let previous = try object(stateURL(program))
        if !previous.isEmpty { try removeOverride(program, config: &config, state: previous) }
        var state: [String: Any] = ["key": key]
        if program == .agy {
            for (action, value) in config where action != "edit.open_editor" {
                if (value as? [String])?.contains(key) == true || value as? String == key { throw conflict(key) }
            }
            state["original"] = config["edit.open_editor"] ?? NSNull()
            config["edit.open_editor"] = [key]
        } else {
            var entries = try blocks(config)
            for entry in entries where ["Chat", "Global"].contains(entry["context"] as? String ?? "") {
                if let action = (entry["bindings"] as? [String: Any])?[key] as? String,
                   action != "chat:externalEditor" { throw conflict(key) }
            }
            let entry: [String: Any] = ["context": "Chat", "bindings": [key: "chat:externalEditor"]]
            entries.append(entry)
            state["entry"] = entry
            state["index"] = entries.count - 1
            config["bindings"] = entries
        }
        try commit(config, state: state, program: program)
    }

    /// Explicitly unbinds the action, rather than falling back to Ctrl+G.
    public func disable(_ program: CLIEditorProgram) throws {
        if program == .codex {
            try save(Data("disabled".utf8), to: codexOverrideURL)
            return
        }
        var config = try object(configURL(program))
        let previous = try object(stateURL(program))
        if !previous.isEmpty { try removeOverride(program, config: &config, state: previous) }
        var state: [String: Any] = ["key": ""]
        if program == .agy {
            state["original"] = config["edit.open_editor"] ?? NSNull()
            config["edit.open_editor"] = [String]()
        } else {
            var entries = try blocks(config)
            var effective: [String: Any] = ["ctrl+g": "chat:externalEditor", "ctrl+x ctrl+e": "chat:externalEditor"]
            for entry in entries where ["Global", "Chat"].contains(entry["context"] as? String ?? "") {
                for (key, action) in entry["bindings"] as? [String: Any] ?? [:] { effective[key] = action }
            }
            let unbindings = effective.filter { $0.value as? String == "chat:externalEditor" }
                .mapValues { _ in NSNull() }
            let entry: [String: Any] = ["context": "Chat", "bindings": unbindings]
            entries.append(entry)
            state["entry"] = entry; state["index"] = entries.count - 1
            config["bindings"] = entries
        }
        try commit(config, state: state, program: program)
    }

    public func restore(_ program: CLIEditorProgram) throws {
        if program == .codex {
            if try read(codexOverrideURL) != nil { try manager.removeItem(at: codexOverrideURL.resolvingSymlinksInPath()) }
            return
        }
        let state = try object(stateURL(program))
        guard !state.isEmpty else { return }
        var config = try object(configURL(program))
        try removeOverride(program, config: &config, state: state)
        try commit(config, state: [:], program: program)
    }

    private func removeOverride(_ program: CLIEditorProgram, config: inout [String: Any], state: [String: Any]) throws {
        if program == .agy {
            guard let key = state["key"] as? String, config["edit.open_editor"] as? [String] == (key.isEmpty ? [] : [key]),
                  let original = state["original"] else { throw changed() }
            config["edit.open_editor"] = original is NSNull ? nil : original
        } else {
            var entries = try blocks(config)
            guard let index = state["index"] as? Int, entries.indices.contains(index),
                  let entry = state["entry"] as? [String: Any], NSDictionary(dictionary: entries[index]).isEqual(to: entry)
            else { throw changed() }
            entries.remove(at: index)
            config["bindings"] = entries
        }
    }
    private func blocks(_ object: [String: Any]) throws -> [[String: Any]] {
        guard let value = object["bindings"] else { return [] }
        guard let blocks = value as? [[String: Any]], blocks.allSatisfy({ $0["context"] is String && $0["bindings"] is [String: Any] })
        else { throw CLIShortcutError("Invalid CLI bindings; file unchanged. / CLI 快捷键格式无效，未修改文件。") }
        return blocks
    }
    private func object(_ url: URL) throws -> [String: Any] {
        guard let data = try read(url) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIShortcutError("Expected a JSON object: \(url.path) / 配置必须为 JSON 对象。")
        }
        return object
    }
    private func read(_ url: URL) throws -> Data? {
        do { _ = try manager.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try Data(contentsOf: url) // Reject unreadable files and dangling symlinks.
    }
    private func commit(_ config: [String: Any], state: [String: Any], program: CLIEditorProgram) throws {
        let url = configURL(program), journal = stateURL(program)
        let old = try read(url)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let journalData = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        // Preflight journal readability before modifying the CLI file.
        _ = try read(journal)
        try save(data, to: url)
        do { try save(journalData, to: journal) }
        catch {
            if let old { try old.write(to: url.resolvingSymlinksInPath(), options: .atomic) }
            else { try manager.removeItem(at: url) }
            throw error
        }
    }
    private func save(_ data: Data, to url: URL) throws {
        let old = try read(url)
        guard old != data else { return }
        let target = url.resolvingSymlinksInPath()
        let permissions = old == nil ? 0o600 : (try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if old != nil { try manager.copyItem(at: target, to: target.appendingPathExtension("sayo-backup-" + UUID().uuidString)) }
        try data.write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }
    private func conflict(_ key: String) -> CLIShortcutError { CLIShortcutError("\(key) is already assigned in your CLI configuration. / 该按键已在 CLI 配置中用于其他操作。") }
    private func changed() -> CLIShortcutError { CLIShortcutError("The CLI binding was edited outside Sayo. Keep the external changes and resolve the binding manually. / CLI 快捷键已在 Sayo 之外修改，请手动处理，现有配置未覆盖。") }
}
private struct CLIShortcutError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
