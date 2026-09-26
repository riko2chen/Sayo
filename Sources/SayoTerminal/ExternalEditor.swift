import Foundation

/// Adapts an external editor's draft file to the existing rewrite bridge.
public enum ExternalEditor {
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
