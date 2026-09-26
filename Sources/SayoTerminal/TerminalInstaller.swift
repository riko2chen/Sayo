import Darwin
import Foundation
import SayoCore

private extension TerminalShell {
    var scriptFilename: String { "sayo.\(rawValue)" }
    var configFilename: String { "config.\(rawValue)" }
}

public final class TerminalInstaller {
    public typealias Shell = TerminalShell

    public enum Status: Equatable, Sendable {
        case installed
        case notInstalled
    }

    private static let startMarker = "# >>> Sayo Terminal Integration >>>"
    private static let endMarker = "# <<< Sayo Terminal Integration <<<"

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let installDirectory: URL
    private let resourceDirectory: URL
    private let cliURL: URL

    public convenience init() throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundledResourceURL: URL?
        let packagedBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("Sayo_SayoTerminal.bundle", isDirectory: true)
        if let packagedBundleURL,
           let packagedBundle = Bundle(url: packagedBundleURL),
           let packagedResources = packagedBundle.resourceURL {
            bundledResourceURL = packagedResources
        } else {
            #if SWIFT_PACKAGE
            bundledResourceURL = Bundle.module.resourceURL
            #else
            bundledResourceURL = Bundle.main.resourceURL
            #endif
        }
        guard let bundleResources = bundledResourceURL else {
            throw InstallerError.missingResources
        }
        let copiedResources = bundleResources.appendingPathComponent("Resources", isDirectory: true)
        let resourceDirectory = fileManager.fileExists(atPath: copiedResources.path)
            ? copiedResources
            : bundleResources

        let appBundle = Bundle.main.bundleURL
        let cliURL = appBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("sayo", isDirectory: false)

        try self.init(
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            applicationSupportDirectory: support.appendingPathComponent("Sayo/Shell", isDirectory: true),
            cliURL: cliURL,
            resourceDirectory: resourceDirectory,
            fileManager: fileManager
        )
    }

    init(
        homeDirectory: URL,
        applicationSupportDirectory: URL,
        cliURL: URL,
        resourceDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        self.homeDirectory = homeDirectory
        self.installDirectory = applicationSupportDirectory
        self.cliURL = cliURL
        self.resourceDirectory = resourceDirectory
        self.fileManager = fileManager
    }

    public func status(shell: TerminalShell) -> Status {
        isInstalled(shell: shell) ? .installed : .notInstalled
    }

    public func status(for shell: TerminalShell) -> Status {
        status(shell: shell)
    }

    public func isInstalled(shell: TerminalShell) -> Bool {
        do {
            for url in try installationRCURLs(for: shell) {
                guard let contents = try readConfiguration(at: url),
                      extractMarkedBlock(from: contents) == markedBlock(for: shell) else { return false }
            }
        } catch {
            return false
        }
        return fileManager.isExecutableFile(atPath: cliURL.path)
            && fileManager.fileExists(atPath: installedScriptURL(for: shell).path)
            && fileManager.fileExists(atPath: installedConfigURL(for: shell).path)
    }

    public func install(shell: TerminalShell) throws {
        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw InstallerError.missingCLI(cliURL.path)
        }
        let source = resourceURL(for: shell)
        guard fileManager.fileExists(atPath: source.path) else {
            throw InstallerError.missingShellResource(shell.rawValue)
        }
        // Read every affected configuration before writing anything. An
        // unreadable file, dangling symlink or invalid UTF-8 must never become
        // an empty configuration that silently replaces the user's contents.
        let edits = try configurationEdits(
            at: installationRCURLs(for: shell), replacement: markedBlock(for: shell)
        )
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDirectory.path)
        try copyResource(from: source, to: installedScriptURL(for: shell))
        try writePrivate(configContents(for: shell), to: installedConfigURL(for: shell), permissions: 0o600)
        try applyConfigurationEdits(edits)
    }

    public func uninstall(shell: TerminalShell) throws {
        // Remove our block even if a newly created profile has changed Bash's
        // startup preference since installation.
        let urls = [rcURL(for: shell)] + (shell == .bash ? bashLoginURLs : [])
        let edits = try configurationEdits(at: urls, replacement: nil)
        try applyConfigurationEdits(edits)
        try? fileManager.removeItem(at: installedScriptURL(for: shell))
        try? fileManager.removeItem(at: installedConfigURL(for: shell))
    }

    private func rcURL(for shell: TerminalShell) -> URL {
        switch shell {
        case .zsh:
            return homeDirectory.appendingPathComponent(".zshrc")
        case .bash:
            return homeDirectory.appendingPathComponent(".bashrc")
        case .fish:
            return homeDirectory.appendingPathComponent(".config/fish/config.fish")
        }
    }

    private var bashLoginURLs: [URL] {
        [".bash_profile", ".bash_login", ".profile"].map { homeDirectory.appendingPathComponent($0) }
    }

    private func installationRCURLs(for shell: TerminalShell) throws -> [URL] {
        let rc = rcURL(for: shell)
        guard shell == .bash else { return [rc] }
        for profile in bashLoginURLs {
            if try configurationExists(at: profile) { return [rc, profile] }
        }
        return [rc, bashLoginURLs[0]]
    }

    private func configurationExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func readConfiguration(at url: URL) throws -> String? {
        guard try configurationExists(at: url) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func configurationEdits(at urls: [URL], replacement: String?) throws -> [(URL, String)] {
        var edits: [(URL, String)] = []
        var resolvedPaths = Set<String>()
        for url in urls {
            let original = try readConfiguration(at: url) ?? ""
            let updated = replacingMarkedBlock(in: original, with: replacement)
            guard original != updated else { continue }
            // Atomic writes replace the destination inode. Resolve the target
            // first so dotfile symlinks remain intact on install and uninstall.
            let target = url.resolvingSymlinksInPath()
            if resolvedPaths.insert(target.path).inserted { edits.append((target, updated)) }
        }
        return edits
    }

    private func applyConfigurationEdits(_ edits: [(URL, String)]) throws {
        for (target, contents) in edits {
            try backupIfPresent(target)
            try writePreservingPermissions(contents, to: target)
        }
    }

    private func resourceURL(for shell: TerminalShell) -> URL {
        resourceDirectory.appendingPathComponent(shell.scriptFilename)
    }

    private func installedScriptURL(for shell: TerminalShell) -> URL {
        installDirectory.appendingPathComponent(shell.scriptFilename)
    }

    private func installedConfigURL(for shell: TerminalShell) -> URL {
        installDirectory.appendingPathComponent(shell.configFilename)
    }

    private func markedBlock(for shell: TerminalShell) -> String {
        if shell == .bash {
            return [
                Self.startMarker,
                "if [ -n \"${BASH_VERSION-}\" ] && [ \"${__SAYO_BASH_LOADED-}\" != 1 ]; then",
                "  source \(quote(installedConfigURL(for: shell).path, for: shell))",
                "  source \(quote(installedScriptURL(for: shell).path, for: shell))",
                "fi",
                Self.endMarker
            ].joined(separator: "\n")
        }
        return [
            Self.startMarker,
            "source \(quote(installedConfigURL(for: shell).path, for: shell))",
            "source \(quote(installedScriptURL(for: shell).path, for: shell))",
            Self.endMarker
        ].joined(separator: "\n")
    }

    private func configContents(for shell: TerminalShell) -> String {
        switch shell {
        case .zsh:
            return "typeset -gx SAYO_CLI=\(quote(cliURL.path, for: shell))\n"
        case .bash:
            return "export SAYO_CLI=\(quote(cliURL.path, for: shell))\n"
        case .fish:
            return "set -gx SAYO_CLI \(quote(cliURL.path, for: shell))\n"
        }
    }

    private func quote(_ value: String, for shell: TerminalShell) -> String {
        switch shell {
        case .zsh, .bash:
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .fish:
            return "'" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'") + "'"
        }
    }

    private func replacingMarkedBlock(in contents: String, with replacement: String?) -> String {
        var result = contents
        if let start = result.range(of: Self.startMarker),
           let endMarkerRange = result.range(of: Self.endMarker, range: start.upperBound..<result.endIndex) {
            var removalEnd = endMarkerRange.upperBound
            if removalEnd < result.endIndex, result[removalEnd] == "\n" {
                removalEnd = result.index(after: removalEnd)
            }
            result.removeSubrange(start.lowerBound..<removalEnd)
        }

        guard let replacement else { return result }
        if !result.isEmpty && !result.hasSuffix("\n") { result.append("\n") }
        if !result.isEmpty && !result.hasSuffix("\n\n") { result.append("\n") }
        result.append(replacement)
        result.append("\n")
        return result
    }

    private func extractMarkedBlock(from contents: String) -> String? {
        guard let start = contents.range(of: Self.startMarker),
              let end = contents.range(of: Self.endMarker, range: start.upperBound..<contents.endIndex) else {
            return nil
        }
        return String(contents[start.lowerBound..<end.upperBound])
    }

    private func copyResource(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try writePrivate(data, to: destination, permissions: 0o600)
    }

    private func writePrivate(_ string: String, to url: URL, permissions: Int) throws {
        guard let data = string.data(using: .utf8) else { throw InstallerError.invalidEncoding }
        try writePrivate(data, to: url, permissions: permissions)
    }

    private func writePrivate(_ data: Data, to url: URL, permissions: Int) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func backupIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".sayo-backup-" + UUID().uuidString.lowercased()
        )
        try fileManager.copyItem(at: url, to: backup)
    }

    private func writePreservingPermissions(_ contents: String, to url: URL) throws {
        let oldAttributes = try configurationExists(at: url)
            ? fileManager.attributesOfItem(atPath: url.path) : nil
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let permissions = oldAttributes?[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}

public enum TerminalWidget {
    /// The bytes sent by the configurable macOS shortcut while a terminal is foreground.
    public static let keySequence = "\u{18}\u{12}" // Ctrl-X Ctrl-R
}

public enum InstallerError: LocalizedError, Equatable {
    case missingResources
    case missingShellResource(String)
    case missingCLI(String)
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .missingResources:
            return "The bundled terminal resources are missing."
        case .missingShellResource(let shell):
            return "The bundled \(shell) integration is missing."
        case .missingCLI(let path):
            return "The bundled sayo command is missing or is not executable at \(path)."
        case .invalidEncoding:
            return "The terminal integration could not be encoded."
        }
    }
}
