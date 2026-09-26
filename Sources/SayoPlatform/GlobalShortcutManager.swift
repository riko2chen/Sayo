import AppKit
import ApplicationServices
import Carbon
import Foundation
import SayoCore

public enum SayoPlatformError: LocalizedError, Equatable, Sendable {
    case hotKeyRegistrationFailed(OSStatus)
    case keychain(OSStatus)
    case shortcutReleaseTimedOut

    public var errorDescription: String? {
        switch self {
        case .hotKeyRegistrationFailed(let status):
            return "The global shortcut could not be registered (OSStatus \(status))."
        case .keychain(let status):
            return "The secret could not be stored securely (OSStatus \(status))."
        case .shortcutReleaseTimedOut:
            return "Release the Sayo shortcut and try again."
        }
    }
}

@MainActor
public final class GlobalShortcutManager {
    private final class CarbonRegistration: @unchecked Sendable {
        var eventHandlerRef: EventHandlerRef?
        var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    }

    private static let signature: OSType = 0x5361796F // "Sayo"
    private static var nextID: UInt32 = 1

    private let registration = CarbonRegistration()
    private var configuredShortcuts: [Shortcut] = []
    private var shortcutsByID: [UInt32: Shortcut] = [:]
    private var action: ((Shortcut) -> Void)?
    private var isEnabled = true

    public init() {}

    deinit {
        for hotKeyRef in registration.hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef = registration.eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    public func register(
        _ shortcuts: [Shortcut],
        enabled: Bool = true,
        handler: @escaping (Shortcut) -> Void
    ) throws {
        unregisterHotKeys()
        var uniqueShortcuts: [Shortcut] = []
        for shortcut in shortcuts where !uniqueShortcuts.contains(shortcut) {
            uniqueShortcuts.append(shortcut)
        }
        configuredShortcuts = uniqueShortcuts
        action = handler
        isEnabled = enabled
        guard enabled, !uniqueShortcuts.isEmpty else { return }
        try registerConfiguredShortcuts()
    }

    /// Temporarily suspends the configured shortcuts without forgetting them.
    /// Sayo uses this while it is the active application so shortcut recorder
    /// controls receive the key event instead of Carbon consuming it first.
    public func setEnabled(_ enabled: Bool) throws {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        unregisterHotKeys()
        guard enabled, !configuredShortcuts.isEmpty else { return }
        try registerConfiguredShortcuts()
    }

    /// Checks that another process has not claimed any of these shortcuts.
    /// The temporary registrations are removed before this method returns.
    public func validate(_ shortcuts: [Shortcut]) throws {
        var uniqueShortcuts: [Shortcut] = []
        for shortcut in shortcuts where !uniqueShortcuts.contains(shortcut) {
            uniqueShortcuts.append(shortcut)
        }
        var temporaryReferences: [EventHotKeyRef] = []
        defer {
            for reference in temporaryReferences {
                UnregisterEventHotKey(reference)
            }
        }
        for shortcut in uniqueShortcuts {
            let id = Self.nextID
            Self.nextID &+= 1
            if Self.nextID == 0 { Self.nextID = 1 }

            var reference: EventHotKeyRef?
            let hotKey = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                carbonModifiers(for: shortcut),
                hotKey,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard status == noErr, let reference else {
                throw SayoPlatformError.hotKeyRegistrationFailed(status)
            }
            temporaryReferences.append(reference)
        }
    }

    private func registerConfiguredShortcuts() throws {
        try installEventHandlerIfNeeded()

        do {
            for shortcut in configuredShortcuts {
                let id = Self.nextID
                Self.nextID &+= 1
                if Self.nextID == 0 { Self.nextID = 1 }

                var reference: EventHotKeyRef?
                let hotKey = EventHotKeyID(signature: Self.signature, id: id)
                let status = RegisterEventHotKey(
                    shortcut.keyCode,
                    carbonModifiers(for: shortcut),
                    hotKey,
                    GetApplicationEventTarget(),
                    0,
                    &reference
                )
                guard status == noErr, let reference else {
                    throw SayoPlatformError.hotKeyRegistrationFailed(status)
                }
                registration.hotKeyRefs[id] = reference
                shortcutsByID[id] = shortcut
            }
        } catch {
            unregisterHotKeys()
            throw error
        }
    }

    public func unregister() {
        unregisterHotKeys()
        configuredShortcuts.removeAll()
        action = nil
    }

    private func unregisterHotKeys() {
        for hotKeyRef in registration.hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        registration.hotKeyRefs.removeAll()
        shortcutsByID.removeAll()
    }

    /// Sends the Terminal Integration widget chord without changing the
    /// frontmost application. It requires Accessibility permission, not Input
    /// Monitoring permission.
    public func triggerTerminalWidget(afterReleasing triggeringShortcut: Shortcut) async throws {
        try validateTerminalTarget()
        try await waitForRelease(of: triggeringShortcut)
        try validateTerminalTarget()
        try postShortcut(Shortcut(keyCode: 7, control: true))  // Ctrl+X
        try postShortcut(Shortcut(keyCode: 15, control: true)) // Ctrl+R
    }

    /// Sends a CLI-native editor shortcut to the frontmost terminal after the
    /// focused foreground process has been identified as a supported CLI.
    /// Returns true when the same shortcut was globally registered by Sayo and
    /// had to be released, temporarily unregistered, and relayed to the CLI.
    public func triggerTerminalCLIShortcut(
        _ shortcut: Shortcut,
        afterReleasing triggeringShortcut: Shortcut
    ) async throws -> Bool {
        try validateTerminalTarget()
        let requiresRelay = isEnabled && configuredShortcuts.contains(shortcut)
        if requiresRelay { try setEnabled(false) }
        do {
            try await waitForRelease(of: triggeringShortcut)
            try validateTerminalTarget()
            try postShortcut(shortcut)
        } catch {
            if requiresRelay { try? setEnabled(true) }
            throw error
        }
        if requiresRelay { try setEnabled(true) }
        return requiresRelay
    }

    private func waitForRelease(of shortcut: Shortcut) async throws {
        let keyCode = CGKeyCode(shortcut.keyCode)
        var released = false
        for _ in 0..<150 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let keyIsUp = !CGEventSource.keyState(.combinedSessionState, key: keyCode)
            let modifiersAreUp = (!shortcut.command || !flags.contains(.maskCommand))
                && (!shortcut.option || !flags.contains(.maskAlternate))
                && (!shortcut.control || !flags.contains(.maskControl))
                && (!shortcut.shift || !flags.contains(.maskShift))
            if keyIsUp && modifiersAreUp {
                released = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard released else { throw SayoPlatformError.shortcutReleaseTimedOut }
    }

    private func installEventHandlerIfNeeded() throws {
        guard registration.eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            sayoHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        guard status == noErr, let reference else {
            throw SayoPlatformError.hotKeyRegistrationFailed(status)
        }
        registration.eventHandlerRef = reference
    }

    private func carbonModifiers(for shortcut: Shortcut) -> UInt32 {
        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private func validateTerminalTarget() throws {
        guard AccessibilityTextAdapter.isTrusted else {
            throw SayoError.permissionRequired
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              TerminalDetector.isTerminal(frontmost.bundleIdentifier)
        else {
            throw SayoError.terminalUnavailable
        }
    }

    private func postShortcut(_ shortcut: Shortcut) throws {
        guard shortcut.keyCode <= UInt32(CGKeyCode.max) else {
            throw SayoError.terminalUnavailable
        }
        let keyCode = CGKeyCode(shortcut.keyCode)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              )
        else {
            throw SayoError.terminalUnavailable
        }
        var flags: CGEventFlags = []
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }
        if shortcut.shift { flags.insert(.maskShift) }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    fileprivate func invoke(hotKeyID id: UInt32) {
        guard isEnabled, let shortcut = shortcutsByID[id] else { return }
        action?(shortcut)
    }
}

private let sayoHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKey = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKey
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKey.id
    Task { @MainActor in
        manager.invoke(hotKeyID: id)
    }
    return noErr
}
