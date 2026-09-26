import XCTest
@testable import SayoCore

final class TextContextTests: XCTestCase {
    func testAutomaticScopeUsesSelectionOtherwiseEntireInput() throws {
        var context = TextContext(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let selected = try context.snapshot()
        XCTAssertEqual(selected.source, "这个产品")
        XCTAssertEqual(selected.replacing(with: "this product"), "Before this product after")
        context.selection = .init(location: 7, length: 0)
        XCTAssertEqual(try context.snapshot().source, context.text)
    }
    func testAutomaticScopeDoesNotSendWholeFieldForWhitespaceSelection() throws {
        let context = TextContext(id: "field", text: "before   after", selection: .init(location: 6, length: 3))
        XCTAssertThrowsError(try context.snapshot())
    }
    func testInsertionKeepsEmojiAndSurroundingText() throws {
        let context = TextContext(id: "field", text: "Hi 😀 there", selection: .init(location: 3, length: 2))
        XCTAssertEqual(try context.snapshot().insertingAtCaret("[result]"), "Hi 😀[result] there")
    }

    func testMixedTextSelectionUsesUTF16AndPreservesSurroundings() throws {
        let context = TextContext(id: "input", text: "👋 I like 这个产品!", selection: .init(location: 3, length: 11))
        let snapshot = try context.snapshot(scope: .selection)
        XCTAssertEqual(snapshot.source, "I like 这个产品")
        XCTAssertEqual(snapshot.replacing(with: "I like this product"), "👋 I like this product!")
    }
    func testSelectionNeverFallsBackToWholeInput() {
        let context = TextContext(id: "input", text: "private", selection: .init(location: 0, length: 0))
        XCTAssertThrowsError(try context.snapshot(scope: .selection)) { XCTAssertEqual($0 as? SayoError, .noSelection) }
    }
    func testSecureInputsCannotCreateSnapshot() {
        let context = TextContext(id: "input", text: "secret", selection: .init(location: 0, length: 0), isSensitive: true)
        XCTAssertThrowsError(try context.snapshot(scope: .entireInput)) { XCTAssertEqual($0 as? SayoError, .sensitiveInput) }
    }
    func testMalformedUTF16BoundaryAndOverflowAreRejected() {
        XCTAssertFalse(TextRange(location: 1, length: 1).isValid(in: "👋"))
        XCTAssertFalse(TextRange(location: Int.max, length: Int.max).isValid(in: "hello"))
        XCTAssertFalse(TextRange(location: -1, length: 1).isValid(in: "hello"))
    }
    func testSnapshotRejectsChangedFocusTextAndSelection() throws {
        var context = TextContext(id: "a", text: "hello", selection: .init(location: 5, length: 0))
        let snapshot = try context.snapshot(scope: .entireInput)
        context.id = "b"; XCTAssertFalse(snapshot.matches(context))
        context.id = "a"; context.text = "hello!"; XCTAssertFalse(snapshot.matches(context))
        context.text = "hello"; context.selection.location = 0; XCTAssertFalse(snapshot.matches(context))
    }
    func testSelectedSnapshotCanResumeFromCollapsedBoundaryOnly() throws {
        let original = TextContext(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let snapshot = try original.snapshot()
        var current = original

        current.selection = .init(location: 11, length: 0)
        XCTAssertTrue(snapshot.matchesForReplacement(current))
        current.selection = .init(location: 7, length: 0)
        XCTAssertTrue(snapshot.matchesForReplacement(current))
        current.selection = .init(location: 6, length: 0)
        XCTAssertFalse(snapshot.matchesForReplacement(current))
        current.selection = .init(location: 0, length: 4)
        XCTAssertFalse(snapshot.matchesForReplacement(current))
    }
}
