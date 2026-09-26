import Foundation
import OSLog

/// Bounded, local JSON Lines diagnostics. All file access runs on one queue.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sayo", isDirectory: true))
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("diagnostics.jsonl") }
    private let queue = DispatchQueue(label: "com.sayo.diagnostics", qos: .utility)
    private let maximumBytes: Int
    private let archiveCount: Int
    private var previous: [String: [String: String]] = [:]
    private var writeError: String?
    private var enabled = true
    private let logger = Logger(subsystem: "com.sayo.app", category: "diagnostics")

    public init(directory: URL, maximumBytes: Int = 512 * 1024, archiveCount: Int = 3) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.archiveCount = max(1, archiveCount)
    }

    /// Stops or resumes new records without deleting files already retained.
    public func setEnabled(_ enabled: Bool) {
        queue.sync {
            self.enabled = enabled
            self.previous.removeAll()
            if enabled { self.writeError = nil }
        }
    }

    public func record(_ event: String, fields: [String: String]) {
        queue.async { [self] in
            guard enabled else { return }
            guard previous[event] != fields else { return }
            do {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let record = Entry(timestamp: formatter.string(from: Date()), event: event, fields: fields)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(record)
                data.append(0x0A)
                try prepareDirectory()
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size + data.count > maximumBytes { try rotate() }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data().write(to: fileURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                previous[event] = fields
                writeError = nil
            } catch {
                writeError = error.localizedDescription
                logger.error("Diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Includes rotated files and waits for pending writes before producing a snapshot.
    public func recentText(limit: Int = 200) throws -> String {
        try queue.sync {
            if let writeError { throw NSError(domain: "Sayo.Diagnostics", code: 1,
                userInfo: [NSLocalizedDescriptionKey: writeError]) }
            var lines: [Substring] = []
            for url in (1...archiveCount).reversed().map({ archive($0) }) + [fileURL] {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                lines += try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            }
            return lines.suffix(max(0, limit)).joined(separator: "\n")
        }
    }

    /// The viewer starts with the newest event and uses local time. Exported
    /// JSON Lines retain their original UTC timestamps and chronological order.
    public func recentDisplayText(limit: Int = 200, timeZone: TimeZone = .current) throws -> String {
        let lines = try recentText(limit: limit).split(separator: "\n")
        let decoder = JSONDecoder()
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackParser = ISO8601DateFormatter()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return lines.reversed().map { line in
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)),
                  let date = parser.date(from: entry.timestamp) ?? fallbackParser.date(from: entry.timestamp),
                  let fields = try? encoder.encode(entry.fields)
            else { return String(line) }
            return "[\(formatter.string(from: date))] \(entry.event)\n\(String(decoding: fields, as: UTF8.self))"
        }.joined(separator: "\n\n")
    }

    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func archive(_ index: Int) -> URL { directory.appendingPathComponent("diagnostics.\(index).jsonl") }
    private func rotate() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: archive(archiveCount).path) { try manager.removeItem(at: archive(archiveCount)) }
        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                if manager.fileExists(atPath: archive(index).path) {
                    try manager.moveItem(at: archive(index), to: archive(index + 1))
                }
            }
        }
        try manager.moveItem(at: fileURL, to: archive(1))
    }

    private struct Entry: Codable {
        let timestamp: String
        let event: String
        let fields: [String: String]
    }
}
