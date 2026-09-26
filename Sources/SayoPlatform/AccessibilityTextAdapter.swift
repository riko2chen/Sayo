import AppKit
import ApplicationServices
import Foundation
import OSLog
import SayoCore

/// Reads and edits standard macOS Accessibility text controls.
///
/// Native controls use AXValue and a UTF-16 selection. Draft.js editors use
/// paragraph text and opaque text markers because their numeric offsets omit
/// paragraph boundaries. Web editors use verified paste.
/// Web text-marker APIs and an IME's marked range are not consistently exposed
/// as standard AX ranges. Composed Chinese/English text is supported when the
/// host app presents it through the standard attributes; otherwise the adapter
/// fails instead of guessing at a replacement range.
@MainActor
public final class AccessibilityTextAdapter: TextInputSource, AnimatedTextReplacer {
    public var applicationAccess = ApplicationAccess()
    /// Explicit, session-only opt-in. Secure controls and excluded apps are never read.
    public var diagnosticTextSnippetsEnabled = false
    public var replacementInvocationID: String?
    public private(set) var lastInputDiagnosticFields: [String: String] = [:]

    private struct IdentityEntry {
        let element: AXUIElement
        let pid: pid_t
        let id: String
    }

    private struct Capture {
        let element: AXUIElement
        let pid: pid_t
        let context: TextContext
    }

    private var identities: [IdentityEntry] = []
    private var accessibilityApplicationPID: pid_t?
    private let geometryLogger = Logger(subsystem: "com.sayo.app", category: "caret")
    private let inputLogger = Logger(subsystem: "com.sayo.app", category: "input")
    private var lastGeometryLog = ""
    private let maximumRememberedIdentities = 32
    private var lastDiagnosticTreeKey = ""
    private var lastDiagnosticTree = ""
    private let draftReader = DraftTextReader()

    public init() {
        // AX messaging defaults can block for several seconds when a target
        // app is hung. The system-wide element sets the timeout globally for
        // this process, which also bounds calls made on focused child objects.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.20)
    }

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility permission when it has not already been granted.
    @discardableResult
    public static func requestPermission() -> Bool {
        // This is the documented value of kAXTrustedCheckOptionPrompt. Using
        // the value avoids importing that C global as mutable shared state.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func openPermissionSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for value in urls {
            guard let url = URL(string: value) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    public func currentContext() throws -> TextContext? {
        try captureCurrent()?.context
    }

    public func replace(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        try await performReplacement(text, in: snapshot, animated: false)
    }

    public func replaceAnimated(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        guard snapshot.context.selection.length == 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return try await performReplacement(text, in: snapshot, animated: false)
        }
        return try await performReplacement(text, in: snapshot, animated: true)
    }

    private func performReplacement(
        _ text: String,
        in snapshot: TextSnapshot,
        animated: Bool
    ) async throws -> TextReplacementOutcome {
        let invocationID = replacementInvocationID ?? UUID().uuidString
        let operationID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        var sequence = 0
        let trace: (String, [String: String]) -> Void = { event, fields in
            sequence += 1
            var fields = fields
            fields["invocationID"] = invocationID; fields["operationID"] = operationID
            fields["app"] = snapshot.context.applicationName; fields["inputID"] = snapshot.context.id
            fields["step"] = String(sequence)
            fields["operationElapsedMs"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            DiagnosticLog.shared.record(event, fields: fields)
        }
        do {
            guard let initial = try captureCurrent() else {
                throw SayoError.staleInput
            }
            guard snapshot.matchesForReplacement(initial.context) else {
                throw SayoError.staleInput
            }
            guard snapshot.range.isValid(in: snapshot.context.text) else {
                throw SayoError.invalidSelection
            }

            let element = initial.element
            let isWebInput = isWebTextInput(element)
            let usesParagraphMarkers = draftReader.supports(element)
            let logger = Logger(subsystem: "com.sayo.app", category: "replacement")
            let read: () throws -> TextReplacementTransaction.State = { [self] in
                guard try focusedElementMatches(element) else {
                    trace("replacement_read_failed", ["reason": "focus_changed"]); throw SayoError.staleInput
                }
                guard stringAttribute(kAXSubroleAttribute, of: element) != kAXSecureTextFieldSubrole as String else {
                    trace("replacement_read_failed", ["reason": "secure_input"]); throw SayoError.staleInput
                }
                if usesParagraphMarkers {
                    let document = try draftReader.read(element)
                    return .init(text: document.text, selection: document.selection)
                }
                guard let value = stringAttribute(kAXValueAttribute, of: element),
                      let range = textRangeAttribute(kAXSelectedTextRangeAttribute, of: element), range.isValid(in: value) else {
                    trace("replacement_read_failed", ["reason": "value_or_range_unavailable"]); throw SayoError.staleInput
                }
                return .init(text: value, selection: range)
            }
            let set: (String, CFTypeRef) -> Bool = { attribute, value in
                let status = AXUIElementSetAttributeValue(element, attribute as CFString, value)
                logger.debug("AX write attribute=\(attribute, privacy: .public) status=\(status.rawValue, privacy: .public)")
                trace("ax_write", ["attribute": attribute, "status": String(status.rawValue)])
                return status == .success
            }
            let access = TextReplacementTransaction.Access(
                read: read,
                select: { [self] range in
                    if usesParagraphMarkers {
                        let accepted = (try? draftReader.select(range, in: element, expectedText: snapshot.context.text,
                            validateFocus: { (try? self.focusedElementMatches(element)) == true })) ?? false
                        trace("selection_marker_write", ["accepted": String(accepted), "range": "\(range.location):\(range.length)"])
                        return accepted
                    }
                    guard canSet(kAXSelectedTextRangeAttribute, on: element),
                          let value = try? axRangeValue(range) else { return false }
                    return set(kAXSelectedTextRangeAttribute, value)
                },
                selectAll: { [self] in
                    guard try focusedElementMatches(element) else { throw SayoError.staleInput }
                    try postCommandKey(0, to: initial.pid)
                },
                collapseSelectionToEnd: { [self] in
                    guard try focusedElementMatches(element) else { throw SayoError.staleInput }
                    try postEditingKey(124, flags: [], to: initial.pid)
                },
                writeSelected: !usesParagraphMarkers && canSet(kAXSelectedTextAttribute, on: element)
                    ? { set(kAXSelectedTextAttribute, $0 as CFString) } : nil,
                writeValue: !usesParagraphMarkers && canSet(kAXValueAttribute, on: element)
                    ? { set(kAXValueAttribute, $0 as CFString) } : nil,
                preparePaste: { [self] replacement in
                    let clipboard = try PasteboardLease(text: replacement)
                    return .init(send: {
                        guard try self.focusedElementMatches(element) else { throw SayoError.staleInput }
                        try self.postCommandKey(9, to: initial.pid)
                    }, restoreClipboard: { clipboard.restore() })
                },
                prefersPaste: isWebInput,
                typeText: usesParagraphMarkers ? nil : { [self] text in
                    guard try focusedElementMatches(element) else { throw SayoError.staleInput }
                    try postUnicodeText(text, to: initial.pid)
                }
            )
            logger.info("replacement started webInput=\(isWebInput, privacy: .public)")
            let transaction = TextReplacementTransaction(access: access, trace: trace)
            let outcome = animated
                ? try await transaction.replaceAnimated(text, snapshot: snapshot)
                : try await transaction.replace(text, snapshot: snapshot)
            logger.info("replacement verified insertedAtCaret=\(outcome == .insertedAtCaret, privacy: .public)")
            trace("replacement_finished", ["outcome": outcome == .insertedAtCaret ? "inserted_at_caret" : "replaced"])
            return outcome
        } catch {
            trace("replacement_failed", ["error": DiagnosticEvent.errorCode(error)])
            throw error
        }
    }

    private func isWebTextInput(_ element: AXUIElement) -> Bool {
        // Chromium/Electron can expose the focused contenteditable as an
        // AXTextArea detached from its AXWebArea ancestor. DOM attributes are
        // still present on that focused object, and are stronger evidence than
        // AX setter writability (Chromium may accept AXSelectedText but ignore it).
        if Self.hasWebTextInputMetadata(
            domClasses: copiedAttribute("AXDOMClassList", from: element, as: [String].self),
            domIdentifier: stringAttribute("AXDOMIdentifier", of: element)
        ) {
            return true
        }
        var current: AXUIElement? = element
        for _ in 0..<20 {
            guard let owner = current else { break }
            let role = stringAttribute(kAXRoleAttribute, of: owner)
            if role == "AXWebArea" { return true }
            if role == kAXWindowRole as String { break }
            current = copiedAttribute(kAXParentAttribute, from: owner, as: AXUIElement.self)
        }
        return false
    }

    nonisolated static func hasWebTextInputMetadata(
        domClasses: [String]?,
        domIdentifier: String?
    ) -> Bool {
        // Attribute presence matters: a web editor may have an empty class or
        // identifier value, while native AppKit controls do not expose either.
        domClasses != nil || domIdentifier != nil
    }

    /// Deliver editing shortcuts only to the validated process, without
    /// activating another application or sending Return/Enter.
    private func postCommandKey(_ key: CGKeyCode, to pid: pid_t) throws {
        try postEditingKey(key, flags: .maskCommand, to: pid)
    }

    private func postEditingKey(_ key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw SayoError.replacementFailed }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func postUnicodeText(_ text: String, to pid: pid_t) throws {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { throw SayoError.replacementFailed }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func captureCurrent() throws -> Capture? {
        let foreground = NSWorkspace.shared.frontmostApplication
        var diagnostics = ["app": foreground?.localizedName ?? "unknown",
            "bundleID": foreground?.bundleIdentifier ?? "unknown", "reason": "permission_required"]
        defer { lastInputDiagnosticFields = diagnostics; DiagnosticLog.shared.record("input", fields: diagnostics) }
        guard Self.isTrusted else { throw SayoError.permissionRequired }

        // Chromium/Electron expose text markers only after an assistive client
        // requests their full accessibility tree. Do this on activation, before
        // resolving focus: enabling the tree can replace the focused AX object.
        if let application = NSWorkspace.shared.frontmostApplication,
           accessibilityApplicationPID != application.processIdentifier {
            accessibilityApplicationPID = application.processIdentifier
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                if canSet(attribute, on: appElement) {
                    AXUIElementSetAttributeValue(appElement, attribute as CFString, kCFBooleanTrue)
                }
            }
        }
        let system = AXUIElementCreateSystemWide()
        guard let element: AXUIElement = copiedAttribute(
            kAXFocusedUIElementAttribute,
            from: system,
            as: AXUIElement.self
        ) else {
            diagnostics["reason"] = "no_focused_element"
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let application = NSRunningApplication(processIdentifier: pid)
        else {
            diagnostics["reason"] = "application_unavailable"
            return nil
        }

        let bundleID = application.bundleIdentifier
        diagnostics["app"] = application.localizedName ?? "unknown"
        diagnostics["bundleID"] = bundleID ?? "unknown"
        diagnostics["pid"] = String(pid)
        if TerminalDetector.isTerminal(bundleID) || !isApplicationAllowed(bundleID) {
            diagnostics["reason"] = "terminal_or_excluded_app"
            return nil
        }
        if pid == ProcessInfo.processInfo.processIdentifier && isOwnSettings(element) {
            diagnostics["reason"] = "sayo_settings"
            return nil
        }

        guard let role = stringAttribute(kAXRoleAttribute, of: element) else {
            diagnostics["reason"] = "role_unavailable"
            return nil
        }
        diagnostics["role"] = role
        let supportedRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        guard supportedRoles.contains(role) else {
            diagnostics["reason"] = "unsupported_role"
            // Never inspect AXValue on arbitrary roles: many non-text controls
            // expose values with unrelated types and semantics.
            return nil
        }

        if stringAttribute(kAXSubroleAttribute, of: element) == kAXSecureTextFieldSubrole as String {
            diagnostics["reason"] = "secure_input_skipped"
            return nil
        }

        diagnostics["reason"] = "value_or_selection_unavailable"
        guard let rawText = stringAttribute(kAXValueAttribute, of: element),
              let rawSelection = textRangeAttribute(kAXSelectedTextRangeAttribute, of: element)
        else {
            throw SayoError.unsupportedInput
        }

        let characterCount = integerAttribute(kAXNumberOfCharactersAttribute, of: element)
        let webInput = isWebTextInput(element)
        let draftDocument: DraftTextReader.Document?
        if draftReader.supports(element) {
            diagnostics["reason"] = "paragraph_text_unavailable"
            draftDocument = try draftReader.read(element)
        } else {
            draftDocument = nil
        }
        let explicitPlaceholder = stringAttribute(kAXPlaceholderValueAttribute, of: element).flatMap { $0.isEmpty ? nil : $0 }
        let markedPlaceholder = placeholderDecoration(in: element)
        let inferredPlaceholder = markedPlaceholder ?? (webInput
            ? inferredWebPlaceholder(value: rawText, selection: rawSelection, element: element)
            : nil)
        let placeholder = explicitPlaceholder ?? inferredPlaceholder
        let accessibleText = draftDocument.map {
            AccessibleText(text: $0.text, selection: $0.selection, placeholder: nil,
                           rawValueIsPlaceholder: false, placeholderContainmentMatch: false)
        } ?? Self.resolveAccessibleText(
            value: rawText,
            placeholder: placeholder,
            characterCount: characterCount,
            selection: rawSelection,
            isWebTextInput: webInput,
            webPlaceholderEvidence: inferredPlaceholder == rawText
        )
        diagnostics["inputID"] = identity(for: element, pid: pid)
        diagnostics["webInput"] = String(webInput)
        diagnostics["rawLength"] = String(rawText.utf16.count)
        diagnostics["characterCount"] = characterCount.map(String.init) ?? "unavailable"
        diagnostics["selection"] = "\(rawSelection.location):\(rawSelection.length)"
        diagnostics["textMapping"] = draftDocument == nil ? "standard" : "paragraph_markers"
        diagnostics["resolvedSelection"] = "\(accessibleText.selection.location):\(accessibleText.selection.length)"
        diagnostics["explicitPlaceholderLength"] = explicitPlaceholder.map { String($0.utf16.count) } ?? "unavailable"
        diagnostics["inferredPlaceholderLength"] = inferredPlaceholder.map { String($0.utf16.count) } ?? "unavailable"
        diagnostics["placeholderSource"] = explicitPlaceholder != nil ? "AXPlaceholderValue" : (markedPlaceholder != nil ? "marked_placeholder" : (inferredPlaceholder != nil ? "nested_static_text" : "none"))
        diagnostics["placeholderMatchesValue"] = String(placeholder == rawText)
        diagnostics["placeholderContainmentMatch"] = String(accessibleText.placeholderContainmentMatch)
        diagnostics["filteredPlaceholder"] = String(accessibleText.rawValueIsPlaceholder)
        diagnostics["resolvedLength"] = String(accessibleText.text.utf16.count)
        diagnostics["textSnippets"] = String(diagnosticTextSnippetsEnabled)
        diagnostics["reason"] = accessibleText.placeholderContainmentMatch ? "placeholder_containment_length" : (accessibleText.rawValueIsPlaceholder ? "placeholder_filtered" : (rawText.isEmpty ? "empty_value" : "value_preserved"))
        let treeKey = "\(diagnostics["inputID"] ?? ""):\(rawSelection):\(rawText):\(diagnosticTextSnippetsEnabled)"
        if treeKey != lastDiagnosticTreeKey {
            lastDiagnosticTreeKey = treeKey
            lastDiagnosticTree = diagnosticTree(element)
        }
        diagnostics["tree"] = lastDiagnosticTree
        if diagnosticTextSnippetsEnabled {
            diagnostics["rawPreview"] = String(rawText.prefix(120))
            diagnostics["placeholderPreview"] = placeholder.map { String($0.prefix(120)) } ?? ""
            diagnostics["resolvedPreview"] = String(accessibleText.text.prefix(120))
        }
        guard accessibleText.selection.isValid(in: accessibleText.text) else {
            diagnostics["reason"] = "invalid_selection"
            throw SayoError.unsupportedInput
        }

        if accessibleText.rawValueIsPlaceholder {
            inputLogger.info(
                "filtered placeholder value role=\(role, privacy: .public) webInput=\(webInput, privacy: .public) valueLength=\(rawText.utf16.count, privacy: .public) placeholderLength=\(placeholder?.utf16.count ?? 0, privacy: .public) characterCount=\(characterCount ?? -1, privacy: .public)"
            )
        }

        let hasTargetedWrite = canSet(kAXSelectedTextRangeAttribute, on: element)
            && canSet(kAXSelectedTextAttribute, on: element)
        guard hasTargetedWrite || canSet(kAXValueAttribute, on: element) || webInput else {
            diagnostics["reason"] = "input_not_writable"
            throw SayoError.unsupportedInput
        }

        let context = TextContext(
            id: identity(for: element, pid: pid),
            text: accessibleText.text,
            selection: accessibleText.selection,
            caret: caretRect(for: draftDocument == nil ? accessibleText.selection : rawSelection,
                             text: draftDocument == nil ? accessibleText.text : rawText, element: element),
            applicationName: application.localizedName ?? "",
            isSensitive: false
        )
        diagnostics["caretAvailable"] = String(context.caret != nil)
        return Capture(element: element, pid: pid, context: context)
    }

    /// Bounded to the focused editor; never traverses the surrounding document/window.
    private func diagnosticTree(_ element: AXUIElement) -> String {
        var nodes: [String] = []
        func visit(_ node: AXUIElement, depth: Int) {
            guard depth <= 3, nodes.count < 16 else { return }
            let role = stringAttribute(kAXRoleAttribute, of: node) ?? "unknown"
            if stringAttribute(kAXSubroleAttribute, of: node) == kAXSecureTextFieldSubrole as String {
                nodes.append("\(depth):secure_input_skipped"); return
            }
            let classes = (copiedAttribute("AXDOMClassList", from: node, as: [String].self) ?? [])
                .prefix(8).map { String($0.prefix(80)) }.joined(separator: ",")
            let text = role == kAXStaticTextRole as String ? accessibilityText(of: node) : nil
            var summary = "\(depth):\(role) classes=[\(classes)] staticLength=\(text?.utf16.count ?? -1)"
            if diagnosticTextSnippetsEnabled, let text { summary += " preview=\(String(text.prefix(120)))" }
            nodes.append(summary)
            guard depth < 3 else { return }
            for child in (copiedAttribute(kAXChildrenAttribute, from: node, as: [AXUIElement].self) ?? []).prefix(6) {
                visit(child, depth: depth + 1)
            }
        }
        visit(element, depth: 0)
        return nodes.joined(separator: " | ")
    }

    private func focusedElementMatches(_ expected: AXUIElement) throws -> Bool {
        guard Self.isTrusted else { throw SayoError.permissionRequired }
        let system = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = copiedAttribute(
            kAXFocusedUIElementAttribute,
            from: system,
            as: AXUIElement.self
        ) else {
            return false
        }
        return CFEqual(focused, expected)
    }

    private func identity(for element: AXUIElement, pid: pid_t) -> String {
        if let index = identities.firstIndex(where: { entry in
            entry.pid == pid && CFEqual(entry.element, element)
        }) {
            let entry = identities.remove(at: index)
            identities.append(entry)
            return entry.id
        }

        let id = UUID().uuidString
        identities.append(IdentityEntry(element: element, pid: pid, id: id))
        if identities.count > maximumRememberedIdentities {
            identities.removeFirst(identities.count - maximumRememberedIdentities)
        }
        return id
    }

    private func isApplicationAllowed(_ bundleID: String?) -> Bool {
        // Sayo never rewrites its own fields, whatever the user's list says.
        bundleID != "com.sayo.app" && applicationAccess.allows(bundleIdentifier: bundleID)
    }

    private func isOwnSettings(_ element: AXUIElement) -> Bool {
        guard let window: AXUIElement = copiedAttribute(kAXWindowAttribute, from: element, as: AXUIElement.self)
        else { return false }

        let title = stringAttribute(kAXTitleAttribute, of: window)?.lowercased() ?? ""
        let identifier = stringAttribute(kAXIdentifierAttribute, of: window)?.lowercased() ?? ""
        let settingsTerms = [
            "settings", "preferences", "设置", "偏好设置", "設定", "環境設定"
        ]
        return settingsTerms.contains(where: title.contains)
            || identifier.contains("settings")
            || identifier.contains("preferences")
    }

    private func caretRect(
        for selection: SayoCore.TextRange,
        text: String,
        element: AXUIElement
    ) -> ScreenRect? {
        let textLength = text.utf16.count
        let insertion = min(selection.location + selection.length, textLength)
        let inputRect = inputAreaRect(for: element)

        // Prefer actual insertion-point bounds. Character inference loses the
        // caret's line at wraps and trailing newlines, so it is only a fallback.
        let candidates: [(String, () -> CGRect?)] = [
            ("insertion", { self.boundsForRange(CFRange(location: insertion, length: 0), in: element).map(self.convertFromAXCoordinates) }),
            ("marker", { self.textMarkerCaretRect(for: element) }),
            ("character", { self.nativeCaretRect(at: insertion, in: text, element: element) }),
            ("line-prefix", { self.lineCaretRect(at: insertion, for: element) })
        ]

        var attempts: [String] = []
        for (source, resolve) in candidates {
            guard let candidate = resolve() else { attempts.append("\(source)=nil"); continue }
            attempts.append("\(source)=\(candidate)")
            guard isUsableCaretRect(candidate, inside: inputRect), candidate.width <= 4 else { continue }
            logGeometry("selection=\(selection.location):\(selection.length) source=\(source) rect=\(candidate)")
            return ScreenRect(
                x: Double(candidate.origin.x),
                y: Double(candidate.origin.y),
                width: Double(max(candidate.width, 1)),
                height: Double(candidate.height)
            )
        }

        logGeometry("selection=\(selection.location):\(selection.length) source=container attempts=\(attempts.joined(separator: ";")) input=\(String(describing: inputRect))")
        guard let inputRect else { return nil }
        return ScreenRect(
            x: Double(inputRect.origin.x),
            y: Double(inputRect.origin.y),
            width: 1,
            height: Double(inputRect.height)
        )
    }

    private func logGeometry(_ message: String) {
        guard message != lastGeometryLog else { return }
        lastGeometryLog = message
        // Only geometry and range offsets; never record the user's input text.
        geometryLogger.debug("\(message, privacy: .public)")
    }

    /// Chromium and Electron editors frequently report broken or empty
    /// AXBoundsForRange values while still exposing the private text-marker
    /// accessibility API used by WebKit-backed text controls.
    private func textMarkerCaretRect(for element: AXUIElement) -> CGRect? {
        // Web contenteditables may expose markers on their AXWebArea ancestor
        // instead of the focused AXTextArea. Stop at the containing window.
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let owner = current else { break }
            if let rect = selectedMarkerBounds(for: owner), rect.width <= 4, rect.height > 0 { return rect }
            if stringAttribute(kAXRoleAttribute, of: owner) == kAXWindowRole as String { break }
            current = copiedAttribute(kAXParentAttribute, from: owner, as: AXUIElement.self)
        }
        return nil
    }

    private func selectedMarkerBounds(for element: AXUIElement) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        ) == .success,
        let markerRange
        else { return nil }

        var rawBounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &rawBounds
        ) == .success,
        let rawBounds,
        CFGetTypeID(rawBounds) == AXValueGetTypeID()
        else { return nil }

        let value = unsafeBitCast(rawBounds, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return convertFromAXCoordinates(rect)
    }

    /// Mirrors the native fallback used by Input Source Pro. Many AppKit
    /// controls only return useful geometry for a one-character range, and
    /// need the visible range to handle a caret at the end of the buffer.
    private func nativeCaretRect(at insertion: Int, in text: String, element: AXUIElement) -> CGRect? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }

        let visible = textRangeAttribute(kAXVisibleCharacterRangeAttribute, of: element)
        let visibleEnd = visible.map { $0.location + $0.length } ?? nsText.length
        let isPastVisibleEnd = insertion >= visibleEnd
        let queryLocation = max(0, min(insertion - (isPastVisibleEnd ? 1 : 0), nsText.length - 1))

        guard let bounds = boundsForRange(
            CFRange(location: queryLocation, length: 1),
            in: element
        ).map(convertFromAXCoordinates),
              bounds.height > 0,
              bounds.width <= max(4, bounds.height * 2)
        else { return nil }

        if insertion > queryLocation {
            if nsText.character(at: queryLocation) == 10 {
                return newlineCaretRect(before: queryLocation, fallback: bounds, text: nsText, element: element)
            }
            return CGRect(x: bounds.maxX, y: bounds.minY, width: 1, height: bounds.height)
        }

        return CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func newlineCaretRect(
        before location: Int,
        fallback: CGRect,
        text: NSString,
        element: AXUIElement
    ) -> CGRect? {
        guard location > 0 else { return nil }

        for previous in stride(from: location - 1, through: 0, by: -1) {
            guard text.character(at: previous) == 10,
                  let previousBounds = boundsForRange(
                    CFRange(location: previous, length: 1),
                    in: element
                  ).map(convertFromAXCoordinates)
            else { continue }

            return CGRect(
                x: previousBounds.minX,
                y: previousBounds.minY - fallback.height,
                width: 1,
                height: fallback.height
            )
        }
        return nil
    }

    /// If a control exposes line geometry but not character geometry, derive
    /// the caret X from the bounds of the line prefix. This keeps the bubble
    /// near the insertion point instead of treating the whole line as a caret.
    private func lineCaretRect(at insertion: Int, for element: AXUIElement) -> CGRect? {
        var rawLine: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXInsertionPointLineNumber" as CFString,
            &rawLine
        ) == .success,
        let line = rawLine as? NSNumber
        else { return nil }

        var rawRange: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXRangeForLine" as CFString,
            line,
            &rawRange
        ) == .success,
        let rawRange,
        CFGetTypeID(rawRange) == AXValueGetTypeID()
        else { return nil }

        let value = unsafeBitCast(rawRange, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range),
              range.location >= 0,
              range.length > 0,
              let rawLineBounds = boundsForRange(range, in: element)
        else { return nil }

        let lineBounds = convertFromAXCoordinates(rawLineBounds)
        let offset = max(0, min(insertion - range.location, range.length))
        guard offset > 0 else {
            return CGRect(x: lineBounds.minX, y: lineBounds.minY, width: 1, height: lineBounds.height)
        }

        if let rawPrefixBounds = boundsForRange(
            CFRange(location: range.location, length: offset),
            in: element
        ) {
            let prefixBounds = convertFromAXCoordinates(rawPrefixBounds)
            return CGRect(x: prefixBounds.maxX, y: lineBounds.minY, width: 1, height: lineBounds.height)
        }

        return CGRect(x: lineBounds.minX, y: lineBounds.minY, width: 1, height: lineBounds.height)
    }

    private func boundsForRange(_ range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var rawBounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        ) == .success,
        let rawBounds,
        CFGetTypeID(rawBounds) == AXValueGetTypeID()
        else { return nil }

        let value = unsafeBitCast(rawBounds, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    private func inputAreaRect(for element: AXUIElement) -> CGRect? {
        if let parent: AXUIElement = copiedAttribute(kAXParentAttribute, from: element, as: AXUIElement.self),
           stringAttribute(kAXRoleAttribute, of: parent) == kAXScrollAreaRole as String,
           let rect = elementRect(parent) {
            return rect
        }
        return elementRect(element)
    }

    private func elementRect(_ element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, of: element),
              let size = sizeAttribute(kAXSizeAttribute, of: element)
        else { return nil }
        return convertFromAXCoordinates(CGRect(origin: position, size: size))
    }

    private func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func convertFromAXCoordinates(_ rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func isUsableCaretRect(_ rect: CGRect, inside inputRect: CGRect?) -> Bool {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.height > 0
        else { return false }

        guard let inputRect else { return true }
        return inputRect.insetBy(dx: -8, dy: -8).intersects(rect)
    }

    private func copiedAttribute<T>(
        _ attribute: String,
        from element: AXUIElement,
        as type: T.Type
    ) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw
        else { return nil }
        return raw as? T
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        copiedAttribute(attribute, from: element, as: String.self)
    }

    private func integerAttribute(_ attribute: String, of element: AXUIElement) -> Int? {
        copiedAttribute(attribute, from: element, as: NSNumber.self)?.intValue
    }

    /// Chromium contenteditable placeholders are sometimes exposed as AXValue
    /// while AXPlaceholderValue is missing and AXNumberOfCharacters reports the
    /// placeholder length. In that state Chromium exposes the placeholder as a
    /// nested static-text descendant. Direct real text vetoes inference;
    /// ProseMirror paragraphs additionally require an explicit empty-document marker.
    private func inferredWebPlaceholder(
        value: String,
        selection: SayoCore.TextRange,
        element: AXUIElement
    ) -> String? {
        guard !value.isEmpty,
              selection.location == 0,
              selection.length == 0,
              let children = copiedAttribute(kAXChildrenAttribute, from: element, as: [AXUIElement].self)
        else { return nil }

        let editorClasses = copiedAttribute("AXDOMClassList", from: element, as: [String].self) ?? []

        if children.contains(where: { child in
            stringAttribute(kAXRoleAttribute, of: child) == kAXStaticTextRole as String
                && Self.webValue(value, matchesStaticText: accessibilityText(of: child))
        }) {
            return nil
        }

        for child in children.prefix(6) {
            guard stringAttribute(kAXRoleAttribute, of: child) != kAXStaticTextRole as String else { continue }
            let childClasses = copiedAttribute("AXDOMClassList", from: child, as: [String].self) ?? []
            guard Self.canContainWebPlaceholder(editorClasses: editorClasses, childClasses: childClasses) else { continue }
            if containsStaticText(value, in: child, remainingDepth: 2) {
                return value
            }
        }
        return nil
    }

    private func containsStaticText(_ value: String, in element: AXUIElement, remainingDepth: Int) -> Bool {
        if stringAttribute(kAXRoleAttribute, of: element) == kAXStaticTextRole as String,
           Self.webValue(value, matchesStaticText: accessibilityText(of: element)) {
            return true
        }
        guard remainingDepth > 0,
              let children = copiedAttribute(kAXChildrenAttribute, from: element, as: [AXUIElement].self)
        else { return false }
        return children.prefix(6).contains {
            containsStaticText(value, in: $0, remainingDepth: remainingDepth - 1)
        }
    }

    private func accessibilityText(of element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, of: element)
            ?? stringAttribute(kAXTitleAttribute, of: element)
            ?? stringAttribute(kAXDescriptionAttribute, of: element)
    }

    /// Electron editors such as flomo append a block-ending newline to AXValue,
    /// but omit it from the corresponding static-text node. Compare that one
    /// representation difference without trimming meaningful user whitespace.
    /// Apply this to direct text too, so real text still vetoes placeholder inference.
    nonisolated static func webValue(_ value: String, matchesStaticText text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return value == text || value == text + "\n"
    }

    /// ProseMirror wraps real paragraphs in AXGroup too. Tiptap's empty-document
    /// marker distinguishes placeholder decoration from actual paragraph text.
    nonisolated static func canContainWebPlaceholder(editorClasses: [String], childClasses: [String]) -> Bool {
        !editorClasses.contains("ProseMirror")
            || (childClasses.contains("is-empty") && childClasses.contains("is-editor-empty"))
    }

    /// Some editors expose their decoration through AX children, even when the
    /// focused input has no AXWebArea ancestor or AXPlaceholderValue attribute.
    private func placeholderDecoration(in element: AXUIElement) -> String? {
        var remainingNodes = 24
        func collect(_ node: AXUIElement, depth: Int, insidePlaceholder: Bool) -> String {
            guard depth <= 3, remainingNodes > 0 else { return "" }
            remainingNodes -= 1
            guard stringAttribute(kAXSubroleAttribute, of: node) != kAXSecureTextFieldSubrole as String else { return "" }
            let classes = copiedAttribute("AXDOMClassList", from: node, as: [String].self) ?? []
            let marked = insidePlaceholder || Self.isPlaceholderDecoration(classes: classes)
            if stringAttribute(kAXRoleAttribute, of: node) == kAXStaticTextRole as String {
                return marked ? accessibilityText(of: node) ?? "" : ""
            }
            guard depth < 3 else { return "" }
            return (copiedAttribute(kAXChildrenAttribute, from: node, as: [AXUIElement].self) ?? [])
                .prefix(6).map { collect($0, depth: depth + 1, insidePlaceholder: marked) }.joined()
        }
        let text = collect(element, depth: 0, insidePlaceholder: false)
        return text.isEmpty ? nil : text
    }

    nonisolated static func isPlaceholderDecoration(classes: [String]) -> Bool {
        classes.contains("placeholder") || (classes.contains("is-empty") && classes.contains("is-editor-empty"))
    }

    /// User-selected heuristic; UTF-16 matches the AX length/selection units.
    nonisolated static func matchesPlaceholderLengthRule(value: String, placeholder: String?) -> Bool {
        guard let placeholder, !placeholder.isEmpty else { return false }
        return value.contains(placeholder) && value.utf16.count <= placeholder.utf16.count * 2
    }

    struct AccessibleText: Equatable, Sendable {
        let text: String
        let selection: SayoCore.TextRange
        let placeholder: String?
        let rawValueIsPlaceholder: Bool
        let placeholderContainmentMatch: Bool
    }

    /// Converts raw Accessibility attributes into editable user text. Placeholder
    /// content is consumed at this boundary and never enters TextContext or rewrite logic.
    nonisolated static func resolveAccessibleText(
        value: String,
        placeholder: String?,
        characterCount: Int?,
        selection: SayoCore.TextRange = SayoCore.TextRange(location: 0, length: 0),
        isWebTextInput: Bool = false,
        webPlaceholderEvidence: Bool = false
    ) -> AccessibleText {
        let valueMatchesPlaceholder = !value.isEmpty && placeholder == value
        let confirmedPlaceholder = valueMatchesPlaceholder && characterCount == 0
        let webPlaceholderFallback = valueMatchesPlaceholder
            && characterCount == nil
            && isWebTextInput
            && selection.location == 0
            && selection.length == 0
        let inferredWebPlaceholder = valueMatchesPlaceholder
            && webPlaceholderEvidence
            && isWebTextInput
            && selection.location == 0
            && selection.length == 0
        let containmentMatch = matchesPlaceholderLengthRule(value: value, placeholder: placeholder)
        let rawValueIsPlaceholder = containmentMatch || confirmedPlaceholder || webPlaceholderFallback || inferredWebPlaceholder

        if rawValueIsPlaceholder {
            return AccessibleText(
                text: "",
                selection: SayoCore.TextRange(location: 0, length: 0),
                placeholder: placeholder,
                rawValueIsPlaceholder: true,
                placeholderContainmentMatch: containmentMatch
            )
        }

        return AccessibleText(
            text: value,
            selection: selection,
            placeholder: placeholder,
            rawValueIsPlaceholder: false,
            placeholderContainmentMatch: false
        )
    }

    private func textRangeAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> SayoCore.TextRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }

        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range),
              range.location >= 0,
              range.length >= 0
        else { return nil }
        return SayoCore.TextRange(location: range.location, length: range.length)
    }

    private func axRangeValue(_ range: SayoCore.TextRange) throws -> AXValue {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else {
            throw SayoError.invalidSelection
        }
        return value
    }

    private func canSet(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

}

@MainActor
public final class InputObserver {
    public private(set) var lastError: SayoError?

    private let source: any TextInputSource
    private var pollingTask: Task<Void, Never>?
    private var lastContext: TextContext?
    private var hasEmitted = false

    public init(source: any TextInputSource) {
        self.source = source
    }

    deinit {
        pollingTask?.cancel()
    }

    public func start(onChange: @escaping (TextContext?) -> Void) {
        stop()
        lastContext = nil
        lastError = nil
        hasEmitted = false

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.poll(onChange: onChange)
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(onChange: (TextContext?) -> Void) {
        let context: TextContext?
        do {
            context = try source.currentContext()
            lastError = nil
        } catch let error as SayoError {
            context = nil
            lastError = error
        } catch {
            context = nil
            lastError = .unsupportedInput
        }

        // TextContext equality includes the caret, so a caret-only move emits.
        guard !hasEmitted || context != lastContext else { return }
        hasEmitted = true
        lastContext = context
        onChange(context)
    }
}

public enum TerminalDetector {
    private static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "co.zeit.hyper"
    ]

    public static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}
