import AppKit
import Darwin
import Foundation
import SayoCore
import SayoTerminal

@main
struct SayoCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "edit" {
                guard arguments.count == 2 else { throw CLIError.usage }
                let pid = try frontmostApplicationPID()
                try await ExternalEditor.edit(fileURL: URL(fileURLWithPath: arguments[1])) { text in
                    // External editors receive the complete draft, with no caret metadata.
                    let request = TerminalRequest(text: text,
                        selection: .init(location: 0, length: text.utf16.count), applicationPID: pid)
                    try await openSayoWithoutActivationIfAvailable()
                    return try await TerminalBridgeClient().rewrite(request)
                }
                return
            }
            let options = try RewriteOptions(arguments: arguments)
            let text = try readStandardInput()
            let selection = try options.selection(in: text)
            let pid = try options.applicationPID ?? frontmostApplicationPID()
            let request = TerminalRequest(text: text, selection: selection, applicationPID: pid)

            try await openSayoWithoutActivationIfAvailable()
            let result = try await TerminalBridgeClient().rewrite(request, timeout: options.timeout)
            try FileHandle.standardOutput.write(contentsOf: Data(result.utf8))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
            Darwin.exit(1)
        }
    }

    private static func readStandardInput() throws -> String {
        var data = Data()
        while true {
            let chunk = try FileHandle.standardInput.read(upToCount: 8_192) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= 64_000 else { throw CLIError.inputTooLong }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CLIError.invalidUTF8 }
        return text
    }

    private static func frontmostApplicationPID() throws -> Int32 {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 0 else {
            throw CLIError.missingPID
        }
        return pid
    }

    private static func openSayoWithoutActivationIfAvailable() async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.sayo.app").isEmpty else { return }
        guard let appURL = sayoApplicationURL() else { throw CLIError.appUnavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--background"]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func sayoApplicationURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        if let installedApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.sayo.app") {
            return installedApp
        }
        return nil
    }
}

private struct RewriteOptions {
    let cursor: Int?
    let cursorByte: Int?
    let selectionStart: Int?
    let selectionLength: Int?
    let applicationPID: Int32?
    let timeout: TimeInterval

    init(arguments: [String]) throws {
        guard arguments.first == "rewrite" else { throw CLIError.usage }
        var cursor: Int?
        var cursorByte: Int?
        var selectionStart: Int?
        var selectionLength: Int?
        var applicationPID: Int32?
        var timeout: TimeInterval = 120
        var index = 1

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw CLIError.usage }
            let value = arguments[index + 1]
            switch option {
            case "--cursor":
                guard cursor == nil, cursorByte == nil, let parsed = Int(value), parsed >= 0 else {
                    throw CLIError.invalidOption(option)
                }
                cursor = parsed
            case "--cursor-byte":
                guard cursor == nil, cursorByte == nil, let parsed = Int(value), parsed >= 0 else {
                    throw CLIError.invalidOption(option)
                }
                cursorByte = parsed
            case "--selection-start":
                guard let parsed = Int(value) else { throw CLIError.invalidOption(option) }
                selectionStart = parsed
            case "--selection-length":
                guard let parsed = Int(value) else { throw CLIError.invalidOption(option) }
                selectionLength = parsed
            case "--pid":
                guard let parsed = Int32(value), parsed > 0 else { throw CLIError.invalidOption(option) }
                applicationPID = parsed
            case "--timeout":
                guard let parsed = TimeInterval(value), parsed > 0, parsed <= 300 else {
                    throw CLIError.invalidOption(option)
                }
                timeout = parsed
            default:
                throw CLIError.invalidOption(option)
            }
            index += 2
        }

        guard cursor != nil || cursorByte != nil else { throw CLIError.usage }
        guard (selectionStart == nil) == (selectionLength == nil) else { throw CLIError.incompleteSelection }
        self.cursor = cursor
        self.cursorByte = cursorByte
        self.selectionStart = selectionStart
        self.selectionLength = selectionLength
        self.applicationPID = applicationPID
        self.timeout = timeout
    }

    func selection(in text: String) throws -> SayoCore.TextRange {
        let caret: SayoCore.TextRange?
        if let cursorByte {
            caret = TerminalTextOffsets.utf16Cursor(in: text, byteOffset: cursorByte)
        } else if let cursor {
            caret = TerminalTextOffsets.utf16Range(in: text, start: cursor, length: 0)
        } else {
            caret = nil
        }
        guard let caret else { throw CLIError.offsetOutOfBounds }
        guard let start = selectionStart, let length = selectionLength else { return caret }
        guard let range = TerminalTextOffsets.utf16Range(in: text, start: start, length: length) else {
            throw CLIError.offsetOutOfBounds
        }
        return range
    }
}

private enum CLIError: LocalizedError {
    case usage
    case invalidOption(String)
    case incompleteSelection
    case offsetOutOfBounds
    case inputTooLong
    case invalidUTF8
    case missingPID
    case appUnavailable

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: sayo edit FILE | sayo rewrite (--cursor SCALAR_OFFSET | --cursor-byte UTF8_OFFSET) [--selection-start SCALAR_OFFSET --selection-length SCALAR_LENGTH] [--pid PID] [--timeout SECONDS]"
        case .invalidOption(let option):
            return "Invalid value or option: \(option)"
        case .incompleteSelection:
            return "Both --selection-start and --selection-length are required together."
        case .offsetOutOfBounds:
            return "A cursor or selection offset is outside the editable command buffer."
        case .inputTooLong:
            return "The command buffer exceeds 64 KB."
        case .invalidUTF8:
            return "The command buffer is not valid UTF-8."
        case .missingPID:
            return "The foreground terminal process could not be identified."
        case .appUnavailable:
            return "The Sayo app could not be found."
        }
    }
}
