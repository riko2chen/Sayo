import Foundation

/// Adapts an external editor's draft file to the existing rewrite bridge.
public enum ExternalEditor {
    /// Claude's VS Code adapter supplies `-g FILE:LINE` (optionally :COLUMN).
    /// Existing helpers forward those arguments unchanged to `sayo edit`.
    public static func draftURL(arguments: [String]) throws -> URL {
        if arguments.count == 1 { return URL(fileURLWithPath: arguments[0]) }
        guard arguments.count == 2, ["-g", "--goto"].contains(arguments[0]) else {
            throw TerminalBridgeError.invalidRequest("Usage: sayo edit FILE | sayo edit -g FILE:LINE[:COLUMN]")
        }
        let locator = arguments[1]
        let manager = FileManager.default
        // A literal filename may itself end in colon-separated numbers.
        if manager.fileExists(atPath: locator) { return URL(fileURLWithPath: locator) }
        var path = locator
        var matches: [String] = []
        for _ in 0..<2 {
            guard let suffix = path.range(of: #":[0-9]+$"#, options: .regularExpression) else { break }
            path = String(path[..<suffix.lowerBound])
            if manager.fileExists(atPath: path) { matches.append(path) }
        }
        guard matches.count == 1, let file = matches.first else {
            throw TerminalBridgeError.invalidRequest("The editor draft path is missing or its cursor suffix is ambiguous.")
        }
        return URL(fileURLWithPath: file)
    }

    public static func edit(
        fileURL: URL,
        rewrite: (String) async throws -> String
    ) async throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let original = try handle.read(upToCount: 64_001) ?? Data()
        guard original.count <= 64_000 else {
            throw TerminalBridgeError.invalidRequest("The draft exceeds 64 KB.")
        }
        guard let text = String(data: original, encoding: .utf8) else {
            throw TerminalBridgeError.invalidRequest("The draft is not valid UTF-8.")
        }
        // An empty draft has nothing to rewrite.
        guard !text.isEmpty else { return }
        let result = try await rewrite(text)
        guard result.utf8.count <= 64_000 else {
            throw TerminalBridgeError.invalidResponse("The rewritten draft exceeds 64 KB.")
        }
        guard try Data(contentsOf: fileURL) == original else {
            throw TerminalBridgeError.io("The draft changed during rewriting; it was not overwritten.")
        }
        try Data(result.utf8).write(to: fileURL, options: .atomic)
    }
}
