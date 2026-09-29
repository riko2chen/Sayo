import Foundation

/// Resolves an editing target without searching unrelated fields in a window.
/// The remembered editor is only a candidate: live ownership must
/// confirm it on every read, including each replacement verification.
struct FocusedTextInputResolver<Element> {
    struct Resolution {
        let element: Element
        let source: String
    }

    var role: (Element) -> String?
    var parent: (Element) -> Element?
    var linkedElements: (Element) -> [Element]
    var selectionBelongsToEditor: (Element) -> Bool
    var sameContext: (Element, Element) -> Bool
    var equal: (Element, Element) -> Bool

    static var editorRoles: Set<String> { ["AXTextField", "AXTextArea", "AXComboBox"] }

    func resolve(focused: Element, remembered: Element?) -> Resolution? {
        if Self.editorRoles.contains(role(focused) ?? "") {
            return Resolution(element: focused, source: "focused_element")
        }

        // Text inside an editable can itself be exposed as focused. Stop at
        // another interactive control or a document/window boundary.
        let transparentRoles: Set<String> = ["AXStaticText", "AXGroup", "AXUnknown"]
        var current = focused
        for _ in 0..<12 {
            guard transparentRoles.contains(role(current) ?? ""),
                  let ancestor = parent(current), !equal(ancestor, current),
                  sameContext(focused, ancestor)
            else { break }
            if Self.editorRoles.contains(role(ancestor) ?? "") {
                return Resolution(element: ancestor, source: "editable_ancestor")
            }
            current = ancestor
        }

        guard let remembered,
              Self.editorRoles.contains(role(remembered) ?? ""),
              sameContext(focused, remembered)
        else { return nil }

        // An input's linked popup is an explicit relationship, unlike merely
        // sharing a window or retaining an old caret/selection range.
        // Chromium reports AXFocused=false on the DOM-focused input when an
        // aria-activedescendant has AX focus. Require a concrete popup link,
        // rather than using that flag or a stale selection as a focus test.
        let popupRoles: Set<String> = ["AXList", "AXOutline", "AXTable"]
        let linked = linkedElements(remembered).filter { popupRoles.contains(role($0) ?? "") }
        guard !linked.isEmpty else { return nil }
        let suggestionRoles = transparentRoles.union(popupRoles).union(["AXRow", "AXCell"])
        current = focused
        for _ in 0..<12 {
            guard suggestionRoles.contains(role(current) ?? ""), sameContext(focused, current) else { break }
            if linked.contains(where: { equal($0, current) }) {
                guard selectionBelongsToEditor(remembered) else { return nil }
                return Resolution(element: remembered, source: "associated_editor_popup")
            }
            guard let ancestor = parent(current), !equal(ancestor, current) else { break }
            current = ancestor
        }
        return nil
    }
}
