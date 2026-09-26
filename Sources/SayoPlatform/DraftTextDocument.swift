import ApplicationServices
import Foundation
import SayoCore

/// Draft.js exposes paragraph separators differently in AXValue and numeric
/// selection offsets. Keep paragraph text and opaque browser positions together.
struct ParagraphText {
    let paragraphs: [String]
    var text: String { paragraphs.joined(separator: "\n") }

    func offset(paragraph: Int, localOffset: Int) throws -> Int {
        guard paragraphs.indices.contains(paragraph),
              SayoCore.TextRange(location: localOffset, length: 0).isValid(in: paragraphs[paragraph])
        else { throw SayoError.invalidSelection }
        return paragraphs.prefix(paragraph).reduce(0) { $0 + $1.utf16.count + 1 } + localOffset
    }
}

@MainActor
final class DraftTextReader {
    struct Document {
        let text: String
        let selection: SayoCore.TextRange
        let fullRange: AXTextMarkerRange
    }
    private struct Block {
        let element: AXUIElement
        let nativeText: String
        let text: String
        let start: AXTextMarker
        let end: AXTextMarker
    }
    private struct RememberedSelection {
        let range: SayoCore.TextRange
        let markers: AXTextMarkerRange
    }
    private var rememberedElement: AXUIElement?
    private var rememberedText = ""
    private var selections: [RememberedSelection] = []

    func supports(_ element: AXUIElement) -> Bool {
        (attribute("AXDOMClassList", element) as? [String])?.contains("public-DraftEditor-content") == true
    }

    func read(_ element: AXUIElement) throws -> Document {
        var visited = 0
        let elements = try paragraphElements(element, visited: &visited)
        guard !elements.isEmpty, elements.count <= 1_024 else { throw SayoError.unsupportedInput }
        let blocks: [Block] = try elements.map { block in
            guard let range = markerRange(parameter("AXTextMarkerRangeForUIElement", element, block)),
                  let nativeText = parameter("AXStringForTextMarkerRange", element, range) as? String
            else { throw SayoError.unsupportedInput }
            // A lone BR in an otherwise empty Draft block is an editing sentinel,
            // not an extra paragraph. Literal newlines in static text are retained.
            let emptySentinel = nativeText == "\n" && !hasStaticText(block, depth: 0)
            return Block(element: block, nativeText: nativeText, text: emptySentinel ? "" : nativeText,
                         start: AXTextMarkerRangeCopyStartMarker(range), end: AXTextMarkerRangeCopyEndMarker(range))
        }
        let layout = ParagraphText(paragraphs: blocks.map(\.text))
        let text = layout.text
        guard text.utf16.count <= 256_000,
              let selected = markerRange(attribute("AXSelectedTextMarkerRange", element))
        else { throw SayoError.unsupportedInput }
        let anchor = AXTextMarkerRangeCopyStartMarker(selected)
        let focus = AXTextMarkerRangeCopyEndMarker(selected)
        let anchorOffset = try offset(of: anchor, in: blocks, layout: layout, element: element)
        let focusOffset = try offset(of: focus, in: blocks, layout: layout, element: element)
        let selection = SayoCore.TextRange(location: min(anchorOffset, focusOffset), length: abs(focusOffset - anchorOffset))
        guard selection.isValid(in: text) else { throw SayoError.invalidSelection }
        let start = anchorOffset <= focusOffset ? anchor : focus
        let end = anchorOffset <= focusOffset ? focus : anchor
        let fullRange = AXTextMarkerRangeCreate(nil, blocks[0].start, blocks[blocks.count - 1].end)

        if (rememberedElement.map({ !CFEqual($0, element) }) ?? true) || rememberedText != text {
            selections.removeAll()
            rememberedElement = element
            rememberedText = text
        }
        remember(selection, markers: AXTextMarkerRangeCreate(nil, start, end))
        remember(.init(location: selection.location, length: 0), markers: AXTextMarkerRangeCreate(nil, start, start))
        remember(.init(location: selection.location + selection.length, length: 0), markers: AXTextMarkerRangeCreate(nil, end, end))
        return Document(text: text, selection: selection, fullRange: fullRange)
    }

    func select(_ range: SayoCore.TextRange, in element: AXUIElement, expectedText: String, validateFocus: () -> Bool) throws -> Bool {
        let current = try read(element)
        guard current.text == expectedText, range.isValid(in: current.text) else { throw SayoError.staleInput }
        let markers: AXTextMarkerRange
        if range == SayoCore.TextRange(location: 0, length: current.text.utf16.count) {
            markers = current.fullRange
        } else if let remembered = selections.last(where: { $0.range == range }) {
            markers = remembered.markers
        } else {
            return false
        }
        guard validateFocus() else { throw SayoError.staleInput }
        return AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, markers) == .success
    }

    private func remember(_ range: SayoCore.TextRange, markers: AXTextMarkerRange) {
        selections.removeAll { $0.range == range }
        selections.append(.init(range: range, markers: markers))
        if selections.count > 24 { selections.removeFirst(selections.count - 24) }
    }

    private func offset(of marker: AXTextMarker, in blocks: [Block], layout: ParagraphText,
                        element: AXUIElement) throws -> Int {
        guard let rawOwner = parameter("AXUIElementForTextMarker", element, marker),
              CFGetTypeID(rawOwner) == AXUIElementGetTypeID()
        else { throw SayoError.invalidSelection }
        var owner: AXUIElement? = unsafeBitCast(rawOwner, to: AXUIElement.self)
        for _ in 0..<32 {
            guard let current = owner else { break }
            if let index = blocks.firstIndex(where: { CFEqual($0.element, current) }) {
                let block = blocks[index]
                let prefixRange = AXTextMarkerRangeCreate(nil, block.start, marker)
                guard let prefix = parameter("AXStringForTextMarkerRange", element, prefixRange) as? String,
                      block.nativeText.hasPrefix(prefix)
                else { throw SayoError.invalidSelection }
                let local = block.text.isEmpty ? 0 : prefix.utf16.count
                return try layout.offset(paragraph: index, localOffset: local)
            }
            if CFEqual(current, element) { break }
            guard let parent = attribute(kAXParentAttribute, current), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            owner = unsafeBitCast(parent, to: AXUIElement.self)
        }
        // A marker outside this editable is never allowed to borrow its offsets.
        throw SayoError.invalidSelection
    }

    private func paragraphElements(_ element: AXUIElement, visited: inout Int, depth: Int = 0) throws -> [AXUIElement] {
        visited += 1
        guard visited <= 2_048, depth < 16 else { throw SayoError.unsupportedInput }
        if (attribute("AXDOMClassList", element) as? [String])?.contains("public-DraftStyleDefault-block") == true {
            return [element]
        }
        let children = attribute(kAXChildrenAttribute, element) as? [AXUIElement] ?? []
        return try children.flatMap { try paragraphElements($0, visited: &visited, depth: depth + 1) }
    }

    private func hasStaticText(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 16 else { return true }
        if attribute(kAXRoleAttribute, element) as? String == kAXStaticTextRole as String,
           let value = attribute(kAXValueAttribute, element) as? String, !value.isEmpty { return true }
        return (attribute(kAXChildrenAttribute, element) as? [AXUIElement] ?? []).contains { hasStaticText($0, depth: depth + 1) }
    }

    private func markerRange(_ value: CFTypeRef?) -> AXTextMarkerRange? {
        guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXTextMarkerRange.self)
    }

    private func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func parameter(_ name: String, _ element: AXUIElement, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }
}
