import Foundation
import SayoCore

/// Carries a global shortcut's destination through the shell/editor handoff.
/// Ordinary terminal commands always default to the first language.
public struct TerminalTranslationRoute {
    private struct Pending {
        let id: UUID
        let destination: TranslationDestination
        let applicationPID: Int32
        let createdAt: Date
    }
    private var pending: Pending?

    public init() {}

    @discardableResult
    public mutating func arm(destination: TranslationDestination, applicationPID: Int32, now: Date = Date()) -> UUID {
        let id = UUID()
        pending = Pending(id: id, destination: destination, applicationPID: applicationPID, createdAt: now)
        return id
    }

    public mutating func clear(id: UUID? = nil) {
        if id == nil || pending?.id == id { pending = nil }
    }

    public mutating func consume(for request: TerminalRequest, now: Date = Date()) -> TranslationDestination {
        guard let pending else { return .primary }
        // A failed or delayed handoff must not change a later terminal command.
        guard now.timeIntervalSince(pending.createdAt) <= 10 else {
            self.pending = nil
            return .primary
        }
        guard request.applicationPID == pending.applicationPID,
              request.createdAt >= pending.createdAt else { return .primary }
        self.pending = nil
        return pending.destination
    }
}
