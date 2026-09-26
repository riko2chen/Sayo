import Foundation
import SayoCore

public struct TerminalRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var selection: SayoCore.TextRange
    public var applicationPID: Int32
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        selection: SayoCore.TextRange,
        applicationPID: Int32,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.selection = selection
        self.applicationPID = applicationPID
        self.createdAt = createdAt
    }
}

public struct TerminalResponse: Codable, Equatable, Sendable {
    /// The complete command buffer that the shell should install.
    public var text: String?
    public var error: String?

    public init(text: String? = nil, error: String? = nil) {
        self.text = text
        self.error = error
    }
}

enum TerminalBridgeLimits {
    static let maximumTextBytes = 64_000
    static let maximumFileBytes = 128_000
    static let maximumRequestAge: TimeInterval = 30
    static let maximumClockSkew: TimeInterval = 5
}

public enum TerminalTextOffsets {
    /// Readline supplies an offset in UTF-8 bytes. Reject truncated scalars
    /// instead of rounding to another character or accepting replacement text.
    public static func utf16Cursor(in text: String, byteOffset: Int) -> SayoCore.TextRange? {
        guard byteOffset >= 0, byteOffset <= text.utf8.count,
              let prefix = String(bytes: text.utf8.prefix(byteOffset), encoding: .utf8) else {
            return nil
        }
        return SayoCore.TextRange(location: prefix.utf16.count, length: 0)
    }

    /// Converts shell character offsets (Unicode scalar positions) to the UTF-16
    /// range used by SayoCore and macOS text APIs.
    public static func utf16Range(in text: String, start: Int, length: Int) -> SayoCore.TextRange? {
        let scalars = text.unicodeScalars
        guard start >= 0, length >= 0, start <= scalars.count, length <= scalars.count - start else {
            return nil
        }
        let scalarStart = scalars.index(scalars.startIndex, offsetBy: start)
        let scalarEnd = scalars.index(scalarStart, offsetBy: length)
        let utf16Start = scalarStart.utf16Offset(in: text)
        let utf16End = scalarEnd.utf16Offset(in: text)
        return SayoCore.TextRange(location: utf16Start, length: utf16End - utf16Start)
    }
}

enum TerminalBridgeError: LocalizedError, Equatable {
    case invalidRequest(String)
    case invalidResponse(String)
    case timeout
    case appUnavailable
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .invalidResponse(let message), .io(let message):
            return message
        case .timeout:
            return "Sayo did not respond before the request timed out."
        case .appUnavailable:
            return "Sayo could not be opened."
        }
    }
}

extension TerminalRequest {
    func validate(now: Date = Date()) throws {
        guard text.utf8.count <= TerminalBridgeLimits.maximumTextBytes else {
            throw TerminalBridgeError.invalidRequest("The command buffer exceeds 64 KB.")
        }
        guard selection.isValid(in: text) else {
            throw TerminalBridgeError.invalidRequest("The command selection is invalid.")
        }
        guard applicationPID > 0 else {
            throw TerminalBridgeError.invalidRequest("The terminal process identifier is invalid.")
        }
        guard createdAt.timeIntervalSince(now) <= TerminalBridgeLimits.maximumClockSkew else {
            throw TerminalBridgeError.invalidRequest("The terminal request is dated in the future.")
        }
        guard now.timeIntervalSince(createdAt) <= TerminalBridgeLimits.maximumRequestAge else {
            throw TerminalBridgeError.invalidRequest("The terminal request expired.")
        }
    }
}

extension TerminalResponse {
    func validate() throws {
        guard (text == nil) != (error == nil) else {
            throw TerminalBridgeError.invalidResponse("Sayo returned an invalid terminal response.")
        }
        if let text, text.utf8.count > TerminalBridgeLimits.maximumTextBytes {
            throw TerminalBridgeError.invalidResponse("Sayo returned a command buffer larger than 64 KB.")
        }
        if let error, error.utf8.count > 4_096 {
            throw TerminalBridgeError.invalidResponse("Sayo returned an invalid terminal error.")
        }
    }
}
