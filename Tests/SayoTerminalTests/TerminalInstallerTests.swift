import Darwin
import Foundation
@testable import SayoTerminal
import XCTest
import SayoCore

final class TerminalInstallerTests: XCTestCase {
    func testInstallIsIdempotentBacksUpAndUninstallPreservesUserContent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let rc = home.appendingPathComponent(".zshrc")
        try "export USER_SETTING=yes\n".write(to: rc, atomically: true, encoding: .utf8)
        let cli = try makeExecutable(in: root)
        let installer = try TerminalInstaller(
            homeDirectory: home,
            applicationSupportDirectory: support,
            cliURL: cli,
            resourceDirectory: sourceResources
        )

        try installer.install(shell: .zsh)
        let once = try String(contentsOf: rc, encoding: .utf8)
        try installer.install(shell: .zsh)
        let twice = try String(contentsOf: rc, encoding: .utf8)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.components(separatedBy: "# >>> Sayo Terminal Integration >>>").count - 1, 1)
        XCTAssertTrue(once.contains("export USER_SETTING=yes"))
        XCTAssertTrue(once.contains("source '" + support.path))
        XCTAssertTrue(installer.isInstalled(shell: .zsh))
        XCTAssertEqual(try backupFiles(nextTo: rc).count, 1)

        try installer.uninstall(shell: .zsh)
        let uninstalled = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertTrue(uninstalled.contains("export USER_SETTING=yes"))
        XCTAssertFalse(uninstalled.contains("Sayo Terminal Integration"))
        XCTAssertFalse(installer.isInstalled(shell: .zsh))
        XCTAssertEqual(try backupFiles(nextTo: rc).count, 2)
    }

    func testEveryShellUsesItsOwnRCAndQuotedCLIPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("Support Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let cli = try makeExecutable(in: root, name: "sayo command")
        let installer = try TerminalInstaller(
            homeDirectory: home,
            applicationSupportDirectory: support,
            cliURL: cli,
            resourceDirectory: sourceResources
        )

        for shell in TerminalShell.allCases {
            try installer.install(shell: shell)
            XCTAssertEqual(installer.status(shell: shell), .installed)
            let config = try String(
                contentsOf: support.appendingPathComponent("config.\(shell.rawValue)"),
                encoding: .utf8
            )
            XCTAssertTrue(config.contains(cli.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".bashrc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/fish/config.fish").path))
    }

    func testBundledZshAndBashResourcesParse() throws {
        try assertSyntax(executable: "/bin/zsh", resource: "sayo.zsh")
        try assertSyntax(executable: "/bin/bash", resource: "sayo.bash")
        for resource in ["sayo.zsh", "sayo.bash", "sayo.fish"] {
            let contents = try String(contentsOf: sourceResources.appendingPathComponent(resource), encoding: .utf8)
            XCTAssertFalse(contents.contains("--pid"), "\(resource) must let the CLI capture the foreground GUI PID")
        }
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish") {
            try assertSyntax(executable: "/opt/homebrew/bin/fish", arguments: ["-n"], resource: "sayo.fish")
        }
    }

    func testBashAddsNonloginAndPreferredLoginBlocksWithoutShadowingProfiles() throws {
        let cases: [([String], String)] = [
            ([], ".bash_profile"),
            ([".profile"], ".profile"),
            ([".bash_login", ".profile"], ".bash_login"),
            ([".bash_profile", ".bash_login", ".profile"], ".bash_profile")
        ]
        for (existingProfiles, preferred) in cases {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for name in existingProfiles {
                try "# user \(name)\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let installer = try makeInstaller(home: root)
            try installer.install(shell: .bash)
            XCTAssertTrue(installer.isInstalled(shell: .bash))
            for name in [".bashrc", preferred] {
                let url = root.appendingPathComponent(name)
                let first = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(first.contains("${BASH_VERSION-}"))
                XCTAssertTrue(first.contains("${__SAYO_BASH_LOADED-}"))
                try installer.install(shell: .bash)
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first)
            }
            for name in [".bash_profile", ".bash_login", ".profile"] where name != preferred {
                let url = root.appendingPathComponent(name)
                if existingProfiles.contains(name) {
                    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# user \(name)\n")
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Must not shadow the preferred profile")
                }
            }
            if existingProfiles.contains(preferred) {
                let backups = try backupFiles(nextTo: root.appendingPathComponent(preferred))
                XCTAssertEqual(backups.count, 1)
                XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), "# user \(preferred)\n")
            }
            try installer.uninstall(shell: .bash)
            for name in [".bashrc", preferred] {
                let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                XCTAssertFalse(text.contains("Sayo Terminal Integration"))
                if existingProfiles.contains(name) { XCTAssertTrue(text.contains("# user \(name)\n")) }
            }
        }
    }

    func testZshInstallAndUninstallPreserveSymlinkAndBackUpTargetContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("zshrc")
        let link = root.appendingPathComponent(".zshrc")
        let original = "export MY_DOTFILE_SETTING='keep me'\n"
        try original.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/zshrc")
        let installer = try makeInstaller(home: root)
        try installer.install(shell: .zsh)
        try installer.install(shell: .zsh)
        XCTAssertTrue(installer.isInstalled(shell: .zsh))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "dotfiles/zshrc")
        let backups = try backupFiles(nextTo: target)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backups.first), encoding: .utf8), original)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("Sayo Terminal Integration"))
        try installer.uninstall(shell: .zsh)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "dotfiles/zshrc")
        let result = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(result.hasPrefix(original))
        XCTAssertFalse(result.contains("Sayo Terminal Integration"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try backupFiles(nextTo: target).count, 2)
    }

    func testBashProfileThatAlreadySourcesRCLoadsIntegrationOnlyOnce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("mock resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        // Test the installer's guards independently of the machine's Bash
        // version. The real Bash 3 rejection is tested by the widget suite.
        try "SAYO_TEST_LOADS=$(( ${SAYO_TEST_LOADS:-0} + 1 ))\n__SAYO_BASH_LOADED=1\n"
            .write(to: resources.appendingPathComponent("sayo.bash"), atomically: true, encoding: .utf8)
        let profile = root.appendingPathComponent(".bash_profile")
        try "source \"$SAYO_TEST_HOME/.bashrc\"\n"
            .write(to: profile, atomically: true, encoding: .utf8)
        let installer = try TerminalInstaller(
            homeDirectory: root,
            applicationSupportDirectory: root.appendingPathComponent("support"),
            cliURL: makeExecutable(in: root),
            resourceDirectory: resources
        )
        try installer.install(shell: .bash)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "source \"$SAYO_TEST_HOME/.bash_profile\"; printf %s \"$SAYO_TEST_LOADS\""]
        process.environment = ["PATH": "/usr/bin:/bin", "SAYO_TEST_HOME": root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, Data("1".utf8))
    }

    func testInvalidOrUnreadableConfigurationThrowsBeforeAnyConfigurationWrites() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = try makeInstaller(home: root)
        let profile = root.appendingPathComponent(".bash_profile")
        let rc = root.appendingPathComponent(".bashrc")
        let original = "export KEEP=yes\n"
        try original.write(to: rc, atomically: true, encoding: .utf8)
        let invalidUTF8 = Data([0xff, 0xfe, 0xff])
        try invalidUTF8.write(to: profile)
        XCTAssertThrowsError(try installer.install(shell: .bash))
        XCTAssertThrowsError(try installer.uninstall(shell: .bash))
        XCTAssertEqual(try String(contentsOf: rc, encoding: .utf8), original)
        XCTAssertEqual(try Data(contentsOf: profile), invalidUTF8)
        XCTAssertTrue(try backupFiles(nextTo: rc).isEmpty)

        let zshrc = root.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(atPath: zshrc.path, withDestinationPath: "missing-dotfile")
        XCTAssertThrowsError(try installer.install(shell: .zsh))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path), "missing-dotfile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing-dotfile").path))
    }

    private func makeInstaller(home: URL) throws -> TerminalInstaller {
        try TerminalInstaller(
            homeDirectory: home,
            applicationSupportDirectory: home.appendingPathComponent("Sayo Support"),
            cliURL: makeExecutable(in: home),
            resourceDirectory: sourceResources
        )
    }

    private var sourceResources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SayoTerminal/Resources", isDirectory: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(in directory: URL, name: String = "sayo") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
        return url
    }

    private func backupFiles(nextTo rc: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rc.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(rc.lastPathComponent + ".sayo-backup-") }
    }

    private func assertSyntax(executable: String, arguments: [String] = ["-n"], resource: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [sourceResources.appendingPathComponent(resource).path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(resource) did not parse")
    }
}
