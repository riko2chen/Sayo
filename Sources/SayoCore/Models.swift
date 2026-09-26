import Foundation

public enum WorkingMode: String, Codable, CaseIterable, Sendable {
    case manual, silent

    public var showsInvokeShortcut: Bool { self == .manual }
    public var showsCopyShortcut: Bool { self != .silent }

}

public enum TextScope: String, Codable, CaseIterable, Sendable {
    case automatic, entireInput, selection
}

/// All text offsets crossing the macOS boundary use UTF-16, as Accessibility does.
public struct TextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public func isValid(in text: String) -> Bool {
        let units = Array(text.utf16)
        guard location >= 0, length >= 0, location <= units.count, length <= units.count - location else { return false }
        // Foundation accepts some indices inside surrogate pairs. Such ranges would corrupt emoji on replacement.
        func isBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return isBoundary(location) && isBoundary(location + length)
    }
}

public struct ScreenRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct TextContext: Equatable, Sendable {
    /// Adapter-owned identity. Never use a screen coordinate to identify an input.
    public var id: String
    public var text: String
    public var selection: TextRange
    public var caret: ScreenRect?
    public var applicationName: String
    public var isSensitive: Bool
    public init(id: String, text: String, selection: TextRange, caret: ScreenRect? = nil,
                applicationName: String = "", isSensitive: Bool = false) {
        self.id = id; self.text = text; self.selection = selection; self.caret = caret
        self.applicationName = applicationName; self.isSensitive = isSensitive
    }
    public func snapshot(scope: TextScope = .automatic) throws -> TextSnapshot {
        guard !isSensitive else { throw SayoError.sensitiveInput }
        guard selection.isValid(in: text) else { throw SayoError.invalidSelection }
        let usesSelection = scope == .selection || (scope == .automatic && selection.length > 0)
        let range = usesSelection ? selection : TextRange(location: 0, length: text.utf16.count)
        guard range.isValid(in: text) else { throw SayoError.invalidSelection }
        let source = (text as NSString).substring(with: range.nsRange)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw usesSelection ? SayoError.noSelection : SayoError.emptyInput
        }
        guard source.utf8.count <= 64_000 else { throw SayoError.inputTooLong }
        return TextSnapshot(context: self, range: range, source: source)
    }
}

public struct TextSnapshot: Equatable, Sendable {
    public let context: TextContext
    public let range: TextRange
    public let source: String
    public init(context: TextContext, range: TextRange, source: String) {
        self.context = context; self.range = range; self.source = source
    }
    public func matches(_ current: TextContext) -> Bool {
        !current.isSensitive && context.id == current.id && context.text == current.text
            && context.selection == current.selection
    }
    /// A browser can collapse a still-valid selection when Sayo's floating UI is
    /// clicked or focus presentation changes. Keep the captured text target valid
    /// when only that selection collapses to one of its original boundaries.
    public func matchesForReplacement(_ current: TextContext) -> Bool {
        !current.isSensitive && context.id == current.id && context.text == current.text
            && acceptsReplacementSelection(current.selection)
    }
    public func acceptsReplacementSelection(_ current: TextRange) -> Bool {
        if current == context.selection { return true }
        guard context.selection.length > 0,
              range == context.selection,
              current.length == 0
        else { return false }
        let end = range.location + range.length
        return current.location == range.location || current.location == end
    }
    /// A selection falls back to insertion immediately after its last character.
    public var insertionRange: TextRange {
        TextRange(location: context.selection.location + context.selection.length, length: 0)
    }
    public func insertingAtCaret(_ text: String) -> String {
        (context.text as NSString).replacingCharacters(in: insertionRange.nsRange, with: text)
    }
    public func replacing(with replacement: String) -> String {
        (context.text as NSString).replacingCharacters(in: range.nsRange, with: replacement)
    }
}

public struct RewriteRequest: Sendable {
    public let text: String
    public let prompt: String
    public let targetLanguage: TargetLanguage?
    public init(text: String, prompt: String, targetLanguage: TargetLanguage? = nil) {
        self.text = text; self.prompt = prompt; self.targetLanguage = targetLanguage
    }
}

public struct RewriteResult: Equatable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

public enum SayoError: LocalizedError, Equatable {
    case noInput, emptyInput, noSelection, compatibilitySelectionRequired
    case invalidSelection, sensitiveInput, inputTooLong
    case staleInput, unsupportedInput, permissionRequired, missingConfiguration
    case invalidResponse, network(String), replacementFailed, terminalUnavailable
    public var errorDescription: String? {
        switch self {
        case .noInput: return "Click an editable text field and try again."
        case .emptyInput: return "Type something first."
        case .noSelection: return "Select the text you want to rewrite."
        case .compatibilitySelectionRequired:
            return "This app cannot replace text directly. Select some text first."
        case .invalidSelection: return "This app did not provide a valid text selection."
        case .sensitiveInput: return "Sayo is paused in secure text fields."
        case .inputTooLong: return "Select a shorter passage (up to 64 KB)."
        case .staleInput: return "Your text or focus changed. Rewrite the latest text to continue."
        case .unsupportedInput: return "This input cannot be safely edited. For terminals, enable Terminal Integration."
        case .permissionRequired: return "Enable Accessibility for Sayo in System Settings."
        case .missingConfiguration: return "Add your model and API key in Settings → Language Model."
        case .invalidResponse: return "The model returned no usable text. Please try again."
        case .network(let message): return message
        case .replacementFailed: return "The app could not confirm replacement. Your result is still available to copy."
        case .terminalUnavailable: return "Enable Terminal Integration and open a new terminal session."
        }
    }
}
