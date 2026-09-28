import XCTest
@testable import SayoPlatform

final class FocusedTextInputResolverTests: XCTestCase {
    private final class Node {
        var role: String
        var window = 1
        var pid = 1
        var parent: Node?
        var linked: [Node] = []
        weak var selectionOwner: Node?
        init(_ role: String, parent: Node? = nil) { self.role = role; self.parent = parent }
    }
    private var resolver: FocusedTextInputResolver<Node> {
        .init(role: { $0.role }, parent: { $0.parent }, linkedElements: { $0.linked },
              selectionBelongsToEditor: { $0.selectionOwner === $0 },
              sameContext: { $0.pid == $1.pid && $0.window == $1.window },
              equal: { $0 === $1 })
    }

    func testCurrentEditorWinsOverRememberedEditor() {
        let old = Node("AXTextArea"), new = Node("AXTextField")
        XCTAssertTrue(resolver.resolve(focused: new, remembered: old)?.element === new)
    }

    func testResolvesTextDescendantToItsEditableAncestor() {
        let editor = Node("AXTextArea")
        let text = Node("AXStaticText", parent: Node("AXGroup", parent: editor))
        XCTAssertTrue(resolver.resolve(focused: text, remembered: nil)?.element === editor)
    }

    func testNestedButtonIsNotTreatedAsEditorFocus() {
        let editor = Node("AXTextArea")
        let text = Node("AXStaticText", parent: Node("AXButton", parent: editor))
        XCTAssertNil(resolver.resolve(focused: text, remembered: editor))
    }

    func testLinkedSuggestionResolvesEvenWhenAXFocusMovesOffEditor() {
        let editor = Node("AXComboBox"), popup = Node("AXList")
        let suggestion = Node("AXStaticText", parent: Node("AXRow", parent: popup))
        editor.linked = [popup]
        editor.selectionOwner = editor
        XCTAssertTrue(resolver.resolve(focused: suggestion, remembered: editor)?.element === editor)
        // An intervening target change invalidates the remembered editor.
        XCTAssertNil(resolver.resolve(focused: suggestion, remembered: nil))
    }

    func testInteractiveControlInsidePopupDoesNotBorrowEditor() {
        let editor = Node("AXComboBox"), popup = Node("AXList")
        editor.linked = [popup]; editor.selectionOwner = editor
        let button = Node("AXButton", parent: popup)
        XCTAssertNil(resolver.resolve(focused: button, remembered: editor))
        XCTAssertNil(resolver.resolve(focused: Node("AXStaticText", parent: button), remembered: editor))
    }

    func testSharedPopupCannotBorrowAnEditorWithAStaleSelection() {
        let first = Node("AXComboBox"), second = Node("AXComboBox"), popup = Node("AXList")
        let suggestion = Node("AXStaticText", parent: popup)
        first.linked = [popup]; second.linked = [popup]
        first.selectionOwner = second; second.selectionOwner = second
        XCTAssertNil(resolver.resolve(focused: suggestion, remembered: first))
        XCTAssertTrue(resolver.resolve(focused: suggestion, remembered: second)?.element === second)
        second.selectionOwner = nil
        XCTAssertNil(resolver.resolve(focused: suggestion, remembered: second))
    }

    func testArbitraryLinkedContentDoesNotQualifyAsSuggestionPopup() {
        let editor = Node("AXTextArea"), linked = Node("AXGroup")
        let text = Node("AXStaticText", parent: linked)
        editor.linked = [linked]; editor.selectionOwner = editor
        XCTAssertNil(resolver.resolve(focused: text, remembered: editor))
    }

    func testUnrelatedTextNeverBorrowsRememberedEditor() {
        let editor = Node("AXTextArea")
        editor.linked = [Node("AXList")]; editor.selectionOwner = editor
        XCTAssertNil(resolver.resolve(focused: Node("AXStaticText"), remembered: editor))
    }

    func testWindowOrApplicationChangeRejectsRememberedEditor() {
        let editor = Node("AXComboBox"), popup = Node("AXList")
        editor.linked = [popup]; editor.selectionOwner = editor
        XCTAssertTrue(resolver.resolve(focused: popup, remembered: editor)?.element === editor)
        popup.window = 2
        XCTAssertNil(resolver.resolve(focused: popup, remembered: editor))
        popup.window = 1; popup.pid = 2
        XCTAssertNil(resolver.resolve(focused: popup, remembered: editor))
    }

    func testDetachedEditorAndCyclicParentsFailClosed() {
        let editor = Node("AXComboBox"), popup = Node("AXList"), text = Node("AXStaticText")
        editor.linked = [popup]; editor.selectionOwner = editor
        editor.role = "AXUnknown"
        XCTAssertNil(resolver.resolve(focused: popup, remembered: editor))
        let group = Node("AXGroup", parent: text)
        text.parent = group
        XCTAssertNil(resolver.resolve(focused: text, remembered: nil))
    }
}
