import AppKit
import CoreGraphics
import Foundation
import SayoCore

/// Explicit shortcut-only fallback for applications that do not expose their editor through
/// macOS Accessibility. It captures an existing selection with Command-C and later replaces
/// that same foreground target with Command-V. Unlike the Accessibility path, the resulting
/// text cannot be read back, so this adapter never runs from passive input observation.
@MainActor
public final class CopyPasteCompatibilityAdapter {
    private struct Target: Equatable {
        let pid: pid_t
        let bundleID: String
        let applicationName: String
        let windowNumber: CGWindowID?
    }

    private struct Session {
        let target: Target
        var context: TextContext
    }

    public var replacementInvocationID: String?
    public private(set) var isActive = false
    private var session: Session?

    public init() {}

    /// Only failures that say "the app did not expose a readable editor" may use this fallback.
    /// Secure, excluded, terminal, and Sayo-owned controls must never be bypassed through Copy.
    public static func shouldAttemptFallback(after fields: [String: String]) -> Bool {
        switch fields["reason"] {
        case "no_focused_element", "role_unavailable", "unsupported_role",
             "value_or_selection_unavailable", "input_not_writable":
            return true
        default:
            return false
        }
    }

    public func captureCurrentSelection() async throws -> TextContext {
        cancel()
        guard AccessibilityTextAdapter.isTrusted else { throw SayoError.permissionRequired }
        let target = try currentTarget()
        let lease = try SelectionCaptureLease()
        defer { lease.restore() }

        DiagnosticLog.shared.record("compatibility_capture_started", fields: diagnosticFields(for: target))
        try postCommandKey(8, to: target.pid) // C
        DiagnosticLog.shared.record("compatibility_copy_sent", fields: diagnosticFields(for: target))

        var selectedText: String?
        for _ in 0..<31 {
            try Task.checkCancellation()
            if let text = lease.capturedString() {
                selectedText = text
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard matchesCurrentTarget(target) else {
            DiagnosticLog.shared.record("compatibility_capture_failed", fields:
                diagnosticFields(for: target).merging(["reason": "target_changed"], uniquingKeysWith: { _, new in new }))
            throw SayoError.staleInput
        }
        guard let selectedText,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            DiagnosticLog.shared.record("compatibility_capture_failed", fields:
                diagnosticFields(for: target).merging(["reason": "copy_unavailable"], uniquingKeysWith: { _, new in new }))
            throw SayoError.compatibilitySelectionRequired
        }

        let context = TextContext(
            id: "copy-paste:\(target.pid):\(target.windowNumber.map(String.init) ?? "unknown"):\(UUID().uuidString)",
            text: selectedText,
            selection: TextRange(location: 0, length: selectedText.utf16.count),
            applicationName: target.applicationName
        )
        session = Session(target: target, context: context)
        isActive = true
        DiagnosticLog.shared.record("compatibility_capture_succeeded", fields:
            diagnosticFields(for: target).merging(["sourceLength": String(selectedText.utf16.count)], uniquingKeysWith: { _, new in new }))
        return context
    }

    public func currentContext() -> TextContext? {
        guard let session else { return nil }
        guard matchesCurrentTarget(session.target) else {
            cancel()
            return nil
        }
        return session.context
    }

    public func replace(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        guard var session,
              matchesCurrentTarget(session.target),
              snapshot.matches(session.context)
        else { throw SayoError.staleInput }

        let lease = try PasteboardLease(text: text)
        defer { lease.restore() }
        try postCommandKey(9, to: session.target.pid) // V
        DiagnosticLog.shared.record("compatibility_paste_sent", fields:
            diagnosticFields(for: session.target).merging([
                "invocationID": replacementInvocationID ?? "unknown",
                "resultLength": String(text.utf16.count)
            ], uniquingKeysWith: { _, new in new }))

        // Keep the temporary pasteboard contents available until the target consumes the event.
        try await Task.sleep(for: .milliseconds(120))
        guard matchesCurrentTarget(session.target) else { throw SayoError.staleInput }

        let finalText = snapshot.replacing(with: text)
        session.context.text = finalText
        session.context.selection = TextRange(location: finalText.utf16.count, length: 0)
        self.session = session
        return .replaced
    }

    public func cancel() {
        session = nil
        isActive = false
        replacementInvocationID = nil
    }

    private func currentTarget() throws -> Target {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = application.bundleIdentifier
        else { throw SayoError.noInput }
        return Target(
            pid: application.processIdentifier,
            bundleID: bundleID,
            applicationName: application.localizedName ?? "",
            windowNumber: frontWindowNumber(for: application.processIdentifier)
        )
    }

    private func matchesCurrentTarget(_ expected: Target) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == expected.pid,
              application.bundleIdentifier == expected.bundleID
        else { return false }
        guard let expectedWindow = expected.windowNumber else { return true }
        return frontWindowNumber(for: expected.pid) == expectedWindow
    }

    private func frontWindowNumber(for pid: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    private func postCommandKey(_ key: CGKeyCode, to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw SayoError.replacementFailed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func diagnosticFields(for target: Target) -> [String: String] {
        [
            "app": target.applicationName,
            "bundleID": target.bundleID,
            "pid": String(target.pid),
            "windowNumber": target.windowNumber.map(String.init) ?? "unavailable"
        ]
    }
}

/// Temporarily installs a unique sentinel so a failed Copy can never be mistaken for old
/// clipboard text. Restoration is conditional, preserving a newer user clipboard change.
@MainActor
final class SelectionCaptureLease {
    private let pasteboard: NSPasteboard
    private let savedItems: [NSPasteboardItem]
    private let sentinel: String
    private let installedChangeCount: Int
    private var capturedChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) throws {
        self.pasteboard = pasteboard
        sentinel = "sayo-selection-\(UUID().uuidString)"
        let before = pasteboard.changeCount
        savedItems = try (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type) else { throw SayoError.replacementFailed }
                copy.setData(data, forType: type)
            }
            return copy
        }
        guard pasteboard.changeCount == before else { throw SayoError.staleInput }

        let item = NSPasteboardItem()
        item.setString(sentinel, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            pasteboard.writeObjects(savedItems)
            throw SayoError.replacementFailed
        }
        installedChangeCount = pasteboard.changeCount
    }

    func capturedString() -> String? {
        let current = pasteboard.changeCount
        guard current != installedChangeCount else { return nil }
        capturedChangeCount = current
        guard let text = pasteboard.string(forType: .string),
              text != sentinel
        else { return nil }
        return text
    }

    func restore() {
        let current = pasteboard.changeCount
        guard current == installedChangeCount || current == capturedChangeCount else { return }
        pasteboard.clearContents()
        if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
    }
}
