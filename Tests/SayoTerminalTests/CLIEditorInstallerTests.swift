import Foundation
import XCTest
import SayoCore
@testable import SayoTerminal

final class CLIEditorInstallerTests: XCTestCase {
    private func withFixture(_ body: (URL, CLIEditorInstaller) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = home.appendingPathComponent("sayo binary's test")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 7\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try body(home, CLIEditorInstaller(homeDirectory: home, cliURL: cli))
    }

    func testIndependentInstallResetPreservesRCAndNeverWritesCLIPreferences() throws {
        try withFixture { home, installer in
            let rc = home.appendingPathComponent(".zshrc")
            let original = "export USER_SETTING=yes\n"
            try original.write(to: rc, atomically: true, encoding: .utf8)
            var configurations: [URL: Data] = [:]
            for path in [".gemini/antigravity-cli/settings.json", ".claude/settings.json", ".codex/config.toml"] {
                let file = home.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data("leave these bytes untouched".utf8)
                try data.write(to: file); configurations[file] = data
            }
            for program in CLIEditorProgram.allCases {
                try installer.install(program)
                XCTAssertTrue(try installer.isInstalled(program))
            }
            let installed = try Data(contentsOf: rc)
            try installer.install(.agy)
            XCTAssertEqual(try Data(contentsOf: rc), installed)
            try installer.reset(.codex)
            XCTAssertFalse(try installer.isInstalled(.codex))
            XCTAssertTrue(try installer.isInstalled(.agy))
            XCTAssertTrue(try installer.isInstalled(.claude))
            try installer.reset(.agy); try installer.reset(.claude)
            XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), original)
            for (file, data) in configurations { XCTAssertEqual(try Data(contentsOf: file), data) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli/keybindings.json").path))
            let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix(".zshrc.sayo-backup-") }
            XCTAssertFalse(backups.isEmpty)
        }
    }

    func testShellExecutionPreservesArgumentsStatusAndParentEnvironment() throws {
        try withFixture { home, installer in
            let rc = home.appendingPathComponent(".zshrc")
            let bin = home.appendingPathComponent("mock-bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for program in CLIEditorProgram.allCases {
                let mock = bin.appendingPathComponent(program.rawValue)
                try "#!/bin/sh\nprintf '%s\\n' \"$VISUAL\" \"$EDITOR\" \"$@\"\nexit 7\n".write(to: mock, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
                try installer.install(program)
            }
            for program in CLIEditorProgram.allCases {
                let result = try run("source \"$1\"; \(program.rawValue) 'two words' '中文'; print status=$?; print \"$VISUAL|$EDITOR\"", args: [rc.path], path: bin.path)
                let lines = result.components(separatedBy: "\n")
                let helper = home.appendingPathComponent(".local/bin/" + (program == .claude ? "sayo-claude-code-editor" : "sayo-editor")).path
                XCTAssertEqual(Array(lines.prefix(6)), [helper, helper, "two words", "中文", "status=7", "original-visual|original-editor"])
                let helperResult = try run("\"$1\" 'draft with spaces'; print status=$?", args: [helper], path: bin.path)
                XCTAssertEqual(helperResult, "edit\ndraft with spaces\nstatus=7\n")
                try installer.reset(program)
                let reset = try run("source \"$1\"; \(program.rawValue) hi; print status=$?", args: [rc.path], path: bin.path)
                XCTAssertTrue(reset.hasPrefix("original-visual\noriginal-editor\nhi\n"))
            }
        }
    }

    func testCodexNativeShortcutArgumentPreservesUserArgumentsAndRestore() throws {
        try withFixture { home, installer in
            let bin = home.appendingPathComponent("mock-bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let mock = bin.appendingPathComponent("codex")
            try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: mock, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
            try installer.install(.codex)
            let settings = CLIShortcutSettings(homeDirectory: home)
            try settings.apply(.codex, key: "f6")
            let rc = home.appendingPathComponent(".zshrc")
            XCTAssertEqual(try run("source \"$1\"; codex resume 'two words'", args: [rc.path], path: bin.path),
                           "-c\ntui.keymap.global.open_external_editor=\"f6\"\nresume\ntwo words\n")
            try settings.disable(.codex)
            XCTAssertEqual(try run("source \"$1\"; codex resume", args: [rc.path], path: bin.path),
                           "-c\ntui.keymap.global.open_external_editor=[]\nresume\n")
            try settings.restore(.codex)
            XCTAssertEqual(try run("source \"$1\"; codex resume", args: [rc.path], path: bin.path), "resume\n")
        }
    }

    func testExistingCustomFunctionTakesPriority() throws {
        try withFixture { home, installer in
            let rc = home.appendingPathComponent(".zshrc")
            try "function codex() { print custom; }\n".write(to: rc, atomically: true, encoding: .utf8)
            try installer.install(.codex)
            XCTAssertEqual(try run("source \"$1\"; codex", args: [rc.path]), "custom\n")
        }
    }

    func testMalformedAndInvalidUTF8RCIsNotChanged() throws {
        try withFixture { home, installer in
            let rc = home.appendingPathComponent(".zshrc")
            for bytes in [Data([0xff]), Data("# >>> Sayo CLI Editor: agy >>>\nuser stuff\n".utf8)] {
                try bytes.write(to: rc)
                XCTAssertThrowsError(try installer.install(.agy))
                XCTAssertThrowsError(try installer.reset(.agy))
                XCTAssertEqual(try Data(contentsOf: rc), bytes)
            }
        }
    }

    func testPreservesRCSymlinkPermissionsAndRejectsDanglingLink() throws {
        try withFixture { home, installer in
            let rc = home.appendingPathComponent(".zshrc"), target = home.appendingPathComponent("actual-zshrc")
            try "# personal\n".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: rc, withDestinationURL: target)
            try installer.install(.agy)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rc.path), target.path)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            try FileManager.default.removeItem(at: target)
            XCTAssertThrowsError(try installer.install(.agy))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    private func run(_ code: String, args: [String], path: String = "/usr/bin:/bin") throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", code, "sayo-test"] + args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment["VISUAL"] = "original-visual"; environment["EDITOR"] = "original-editor"
        process.environment = environment; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
