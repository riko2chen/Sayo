import Foundation
import XCTest
import SayoCore
@testable import SayoTerminal

final class CLIShortcutSettingsTests: XCTestCase {
    private func fixture(_ body: (URL, CLIShortcutSettings) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, CLIShortcutSettings(homeDirectory: home))
    }
    private func write(_ value: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: url)
    }
    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testDisablePersistsAndCanBeReboundForEveryCLI() throws {
        try fixture { home, settings in
            for program in CLIEditorProgram.allCases {
                try settings.apply(program, key: "f6")
                try settings.disable(program)
                let reloaded = CLIShortcutSettings(homeDirectory: home)
                XCTAssertEqual(try reloaded.status(program).value, "")
                XCTAssertTrue(try reloaded.status(program).managed)
                try reloaded.disable(program) // Idempotent clearing.
                try reloaded.apply(program, key: "ctrl+g")
                XCTAssertEqual(try reloaded.status(program).value, "ctrl+g")
            }
        }
    }
    func testDisableWritesNativeUnbindingsAndPreservesOtherActions() throws {
        try fixture { home, settings in
            let agy = home.appendingPathComponent(".gemini/antigravity-cli/keybindings.json")
            try write(["edit.open_editor": ["f6"], "other": ["f7"]], agy)
            try settings.disable(.agy)
            XCTAssertEqual(try read(agy)["edit.open_editor"] as? [String], [])
            XCTAssertEqual(try read(agy)["other"] as? [String], ["f7"])
            let claude = home.appendingPathComponent(".claude/keybindings.json")
            try write(["bindings": [["context": "Chat", "bindings": ["f8": "chat:externalEditor", "f9": "chat:submit"]]]], claude)
            XCTAssertFalse(try settings.status(.claude).value.isEmpty)
            try settings.disable(.claude)
            let entries = try XCTUnwrap(try read(claude)["bindings"] as? [[String: Any]])
            let bindings = try XCTUnwrap(entries.last?["bindings"] as? [String: Any])
            for key in ["ctrl+g", "ctrl+x ctrl+e", "f8"] { XCTAssertTrue(bindings[key] is NSNull) }
            XCTAssertNil(bindings["f9"])
            try settings.restore(.claude)
            XCTAssertEqual((try read(claude)["bindings"] as? [[String: Any]])?.count, 1)
        }
    }
    func testFreshInstallDefaultsToControlGForEveryCLI() throws {
        try fixture { _, settings in
            for program in CLIEditorProgram.allCases {
                XCTAssertEqual(try settings.status(program).value, "ctrl+g")
                XCTAssertFalse(try settings.status(program).managed)
            }
        }
    }
    func testAgyRestoresPreviousBindingsAndPreservesUnrelatedEdits() throws {
        try fixture { home, settings in
            let url = home.appendingPathComponent(".gemini/antigravity-cli/keybindings.json")
            try write(["edit.open_editor": ["ctrl+g", "f9"], "other": ["f8"]], url)
            try settings.apply(.agy, key: " F6 ")
            XCTAssertEqual(try settings.status(.agy).value, "f6")
            var changed = try read(url); changed["new.action"] = ["f10"]; try write(changed, url)
            try settings.apply(.agy, key: "alt+g")
            try settings.restore(.agy)
            let restored = try read(url)
            XCTAssertEqual(restored["edit.open_editor"] as? [String], ["ctrl+g", "f9"])
            XCTAssertEqual(restored["other"] as? [String], ["f8"])
            XCTAssertEqual(restored["new.action"] as? [String], ["f10"])
            XCTAssertFalse(try settings.status(.agy).managed)
        }
    }
    func testClaudeAddsAlternativeAndRestoresOnlyOwnBlock() throws {
        try fixture { home, settings in
            let url = home.appendingPathComponent(".claude/keybindings.json")
            let original: [String: Any] = ["$schema": "keep", "bindings": [["context": "Chat", "bindings": ["ctrl+e": "chat:externalEditor", "ctrl+r": "history:search"]]]]
            try write(original, url)
            try settings.apply(.claude, key: "f6")
            XCTAssertTrue(try settings.status(.claude).description.contains("f6"))
            XCTAssertTrue(try settings.status(.claude).description.contains("ctrl+e"))
            try settings.apply(.claude, key: "f7")
            let entries = try read(url)["bindings"] as? [[String: Any]]
            XCTAssertEqual(entries?.count, 2)
            try settings.restore(.claude)
            XCTAssertTrue(NSDictionary(dictionary: try read(url)).isEqual(to: original))
        }
    }
    func testConflictsAndExternalChangesNeverOverwriteFiles() throws {
        try fixture { home, settings in
            for program in [CLIEditorProgram.agy, .claude] {
                let url = home.appendingPathComponent(program == .agy ? ".gemini/antigravity-cli/keybindings.json" : ".claude/keybindings.json")
                let config: [String: Any] = program == .agy ? ["other": ["f6"]] : ["bindings": [["context": "Global", "bindings": ["f6": "app:exit"]]]]
                try write(config, url)
                let before = try Data(contentsOf: url)
                XCTAssertThrowsError(try settings.apply(program, key: "f6"))
                XCTAssertEqual(try Data(contentsOf: url), before)
                try settings.apply(program, key: "f7")
                try write(config, url)
                XCTAssertThrowsError(try settings.restore(program))
                XCTAssertThrowsError(try settings.apply(program, key: "f8"))
                XCTAssertEqual(try Data(contentsOf: url), before)
            }
        }
    }
    func testMalformedJSONAndDanglingSymlinkAreNotReplaced() throws {
        try fixture { home, settings in
            let url = home.appendingPathComponent(".claude/keybindings.json")
            try write([:], url)
            for data in [Data([0xff]), Data("[]".utf8), Data("{invalid}".utf8), Data("{\"bindings\": 7}".utf8)] {
                try data.write(to: url)
                XCTAssertThrowsError(try settings.apply(.claude, key: "f6"))
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: home.appendingPathComponent("missing"))
            XCTAssertThrowsError(try settings.apply(.claude, key: "f6"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("missing").path))
        }
    }
    func testSymlinkAndPermissionsSurviveApplyRestore() throws {
        try fixture { home, settings in
            let url = home.appendingPathComponent(".claude/keybindings.json"), target = home.appendingPathComponent("actual.json")
            try write([:], url); try FileManager.default.removeItem(at: url)
            try write(["unrelated": "kept"], target)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            try settings.apply(.claude, key: "f6"); try settings.restore(.claude)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber, 0o640)
            XCTAssertEqual(try read(target)["unrelated"] as? String, "kept")
        }
    }
    func testCodexOverrideLifecycleDoesNotChangeNativeConfig() throws {
        try fixture { home, settings in
            let config = home.appendingPathComponent(".codex/config.toml")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("# preserved\n[tui]\nalternate_screen = 'never'\n".utf8)
            try bytes.write(to: config)
            XCTAssertFalse(try settings.status(.codex).managed)
            XCTAssertThrowsError(try settings.apply(.codex, key: "ctrl+e"))
            try settings.apply(.codex, key: "F6")
            XCTAssertEqual(try settings.status(.codex).value, "f6")
            try settings.restore(.codex)
            XCTAssertFalse(try settings.status(.codex).managed)
            XCTAssertEqual(try Data(contentsOf: config), bytes)
        }
    }
    func testInputValidation() throws {
        for key in ["ctrl+c", "ctrl+d", "ctrl+j", "ctrl+s", "cmd+g", "f13", "f6;echo hi", "g", "ctrl+g\nf6"] {
            XCTAssertThrowsError(try CLIShortcutSettings.validatedKey(key))
        }
        for key in ["ctrl+e", "ctrl+g", "alt+g", "f6", "f12"] {
            XCTAssertEqual(try CLIShortcutSettings.validatedKey(key), key)
        }
    }
}
