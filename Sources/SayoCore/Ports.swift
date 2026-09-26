import Foundation

public protocol RewriteProvider: Sendable {
    func rewrite(_ request: RewriteRequest) async throws -> RewriteResult
}

@MainActor public protocol TextInputSource: AnyObject {
    func currentContext() throws -> TextContext?
}

public enum TextReplacementOutcome: Equatable, Sendable {
    case replaced, insertedAtCaret
}

@MainActor public protocol TextReplacer: AnyObject {
    /// Must revalidate identity, original text, selection and active focus immediately before writing.
    func replace(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome
}

/// Optional capability for editors that can safely verify staged writes.
/// Callers must fall back to `TextReplacer` when this capability is absent.
@MainActor public protocol AnimatedTextReplacer: TextReplacer {
    func replaceAnimated(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome
}

public protocol DelayClock: Sendable {
    func sleep(seconds: Double) async throws
}

public struct SystemDelayClock: DelayClock {
    public init() {}
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor public protocol SettingsRepository: AnyObject {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public protocol SecretStore: Sendable {
    func readKey(for profileID: String) throws -> String?
    func saveKey(_ value: String, for profileID: String) throws
}
