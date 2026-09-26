import XCTest
import SayoCore
@testable import SayoPlatform

@MainActor
private final class Editor {
    var state = TextReplacementTransaction.State(text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
    var focused = true
    var web = true
    var canSelect = true
    var ignoreSelectAll = false
    var deferSelection = false
    var requestedSelection: SayoCore.TextRange?
    var ticks = 0
    var onTick: (() throws -> Void)?
    var onPrepare: (() -> Void)?
    var directWrite: ((String) -> Bool)?
    var pasteCount = 0
    var selectAllCount = 0
    var restores = 0
    var directCount = 0
    var supportsValueWrite = false
    var valueWriteCount = 0
    var writtenValues: [String] = []
    var supportsKeyboardAnimation = false
    var typedValues: [String] = []
    var ignoreKeyboardEvent: Int?
    var pasted = ""
    var rejectsSelectedPaste = false
    var rejectsEveryPaste = false
    var supportsCollapse = false

    func snapshot(_ scope: TextScope = .entireInput) throws -> TextSnapshot {
        try TextContext(id: "editor", text: state.text, selection: state.selection).snapshot(scope: scope)
    }
    var transaction: TextReplacementTransaction {
        let writeValue: ((String) -> Bool)? = supportsValueWrite ? { [self] value in
            valueWriteCount += 1
            writtenValues.append(value)
            state.text = value
            let location = min(state.selection.location, value.utf16.count)
            state.selection = .init(location: location, length: 0)
            return true
        } : nil
        return .init(access: .init(
            read: { [self] in
                guard focused else { throw SayoError.staleInput }
                return state
            },
            select: { [self] range in
                guard canSelect else { return false }
                requestedSelection = range
                if !deferSelection { state.selection = range }
                return true
            },
            selectAll: { [self] in
                selectAllCount += 1
                if !ignoreSelectAll { state.selection = .init(location: 0, length: state.text.utf16.count) }
            },
            collapseSelectionToEnd: { [self] in
                guard supportsCollapse else { throw SayoError.unsupportedInput }
                state.selection = .init(location: state.selection.location + state.selection.length, length: 0)
            },
            writeSelected: { [self] value in directCount += 1; return directWrite?(value) ?? false },
            writeValue: writeValue,
            preparePaste: { [self] value in
                onPrepare?()
                return .init(send: { [self] in
                    pasteCount += 1
                    pasted = value
                    if rejectsEveryPaste || (rejectsSelectedPaste && state.selection.length > 0) { return }
                    state.text = (state.text as NSString).replacingCharacters(in: state.selection.nsRange, with: value)
                    state.selection = .init(location: state.selection.location + value.utf16.count, length: 0)
                }, restoreClipboard: { [self] in restores += 1 })
            }, prefersPaste: web,
            typeText: supportsKeyboardAnimation ? { [self] value in
                typedValues.append(value)
                if typedValues.count == ignoreKeyboardEvent { return }
                state.text = (state.text as NSString).replacingCharacters(in: state.selection.nsRange, with: value)
                state.selection = .init(location: state.selection.location + value.utf16.count, length: 0)
            } : nil), pause: { [self] in ticks += 1; try onTick?() })
    }
}

@MainActor
final class TextReplacementTransactionTests: XCTestCase {
    func testDisabledSelectAllFallbackStillReplacesThroughDirectRangeSelection() async throws {
        let editor = Editor()
        editor.state.selection = .init(location: 7, length: 0)
        var transaction = editor.transaction
        transaction.allowSelectAllFallback = false
        let outcome = try await transaction.replace("result", snapshot: editor.snapshot())
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "result")
        XCTAssertEqual(editor.selectAllCount, 0)
    }

    func testDisabledSelectAllFallbackNeverSendsSelectAllWhenRangeSelectionIsUnavailable() async throws {
        let editor = Editor()
        editor.state.selection = .init(location: 7, length: 0)
        editor.canSelect = false
        var transaction = editor.transaction
        transaction.allowSelectAllFallback = false
        let outcome = try await transaction.replace("result", snapshot: editor.snapshot())
        XCTAssertEqual(outcome, .insertedAtCaret)
        XCTAssertEqual(editor.selectAllCount, 0)
    }
    private func fails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected rejection", file: file, line: line) } catch { }
    }

    func testTraceExplainsAcceptedNativeWriteThatDoesNothing() async throws {
        let editor = Editor(); editor.web = false; editor.directWrite = { _ in true }
        var events: [(String, [String: String])] = []
        var transaction = editor.transaction; transaction.trace = { events.append(($0, $1)) }
        let outcome = try await transaction.replace("[result]", snapshot: editor.snapshot(.selection))
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before [result] after")
        XCTAssertEqual(events.first { $0.0 == "direct_write" }?.1["accepted"], "true")
        XCTAssertEqual(events.first { $0.0 == "write_unchanged" }?.1["samples"], "51")
        XCTAssertEqual(events.first { $0.0 == "direct_write_unchanged" }?.1["method"], "selected_text")
        XCTAssertFalse(events.contains { $0.0 == "fallback_started" })
        XCTAssertEqual(events.filter { $0.0 == "write_verified" }.count, 1)
    }

    func testTraceSeparatesFailedSelectionFromFailedWrite() async throws {
        let editor = Editor(); editor.state.selection = .init(location: 7, length: 0)
        editor.canSelect = false; editor.ignoreSelectAll = true
        var events: [(String, [String: String])] = []
        var transaction = editor.transaction; transaction.trace = { events.append(($0, $1)) }
        let outcome = try await transaction.replace("[result]", snapshot: editor.snapshot())
        XCTAssertEqual(outcome, .insertedAtCaret)
        XCTAssertEqual(events.first { $0.0 == "selection_timeout" }?.1["actualRange"], "7:0")
        XCTAssertEqual(events.first { $0.0 == "fallback_started" }?.1["reason"], "replacement_unsupported")
        XCTAssertFalse(events.contains { $0.0 == "write_unchanged" })
    }

    func testTraceNeverSuggestsFallbackAfterRendererRollback() async throws {
        let editor = Editor(); let original = editor.state.text
        editor.onTick = { if editor.ticks == 3 { editor.state.text = original } }
        var events: [(String, [String: String])] = []
        var transaction = editor.transaction; transaction.trace = { events.append(($0, $1)) }
        await fails { try await transaction.replace("result", snapshot: editor.snapshot()) }
        XCTAssertEqual(events.first { $0.0 == "write_changed_unexpectedly" }?.1["revertedAfterResult"], "true")
        XCTAssertFalse(events.contains { $0.0 == "fallback_started" || $0.0 == "write_verified" })
    }

    func testWebEditorUsesPasteAndPreservesSelectionSurroundings() async throws {
        let editor = Editor()
        editor.canSelect = false
        try await editor.transaction.replace("this product", snapshot: editor.snapshot(.selection))
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertEqual(editor.directCount, 0)
        XCTAssertEqual(editor.selectAllCount, 0)
        XCTAssertEqual(editor.pasteCount, 1)
        XCTAssertEqual(editor.restores, 1)
    }

    func testWebSelectionIsReselectedAfterBrowserCollapsesIt() async throws {
        let editor = Editor()
        let snapshot = try editor.snapshot(.selection)
        editor.state.selection = snapshot.insertionRange

        try await editor.transaction.replace("this product", snapshot: snapshot)

        XCTAssertEqual(editor.requestedSelection, snapshot.range)
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testSelectionReplacementWorksAtBeginningMiddleAndEnd() async throws {
        let cases: [(String, SayoCore.TextRange, String, String)] = [
            ("one two three", .init(location: 0, length: 3), "ONE", "ONE two three"),
            ("one two three", .init(location: 4, length: 3), "TWO", "one TWO three"),
            ("one two three", .init(location: 8, length: 5), "THREE", "one two THREE")
        ]
        for (text, selection, replacement, expected) in cases {
            let editor = Editor()
            editor.state = .init(text: text, selection: selection)
            try await editor.transaction.replace(replacement, snapshot: editor.snapshot(.selection))
            XCTAssertEqual(editor.state.text, expected)
        }
    }

    func testSelectionReplacementUsesUTF16ForEmojiAndMixedText() async throws {
        let editor = Editor()
        editor.state = .init(text: "👋 I like 这个产品!", selection: .init(location: 3, length: 11))
        try await editor.transaction.replace("I like this product", snapshot: editor.snapshot(.selection))
        XCTAssertEqual(editor.state.text, "👋 I like this product!")
    }

    func testMovedSelectionIsRejectedBeforePaste() async throws {
        let editor = Editor()
        let snapshot = try editor.snapshot(.selection)
        editor.state.selection = .init(location: 0, length: 3)
        await fails { try await editor.transaction.replace("this product", snapshot: snapshot) }
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertEqual(editor.state.text, "Before 这个产品 after")
    }

    func testChangedTextIsRejectedBeforePaste() async throws {
        let editor = Editor()
        let snapshot = try editor.snapshot(.selection)
        editor.state.text = "User changed the text"
        editor.state.selection = .init(location: 0, length: 0)
        await fails { try await editor.transaction.replace("this product", snapshot: snapshot) }
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertEqual(editor.state.text, "User changed the text")
    }

    func testAsynchronousSelectionIsVerifiedBeforePastingEntireInput() async throws {
        let editor = Editor()
        editor.deferSelection = true
        editor.onTick = { if editor.ticks == 8 { editor.state.selection = editor.requestedSelection! } }
        try await editor.transaction.replace("Whole replacement", snapshot: editor.snapshot())
        XCTAssertEqual(editor.state.text, "Whole replacement")
        XCTAssertEqual(editor.pasteCount, 1)
        XCTAssertEqual(editor.selectAllCount, 0)
    }

    func testUnsupportedAXSelectionUsesVerifiedSelectAllForEntireInput() async throws {
        let editor = Editor()
        editor.canSelect = false
        try await editor.transaction.replace("Whole replacement", snapshot: editor.snapshot())
        XCTAssertEqual(editor.state.text, "Whole replacement")
        XCTAssertEqual(editor.selectAllCount, 1)
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testUnconfirmedSelectAllNeverPastes() async throws {
        let editor = Editor()
        editor.canSelect = false
        editor.ignoreSelectAll = true
        await fails { try await editor.transaction.replace("replacement", snapshot: editor.snapshot()) }
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertEqual(editor.state.text, "Before 这个产品 after")
    }

    func testTypingWhileSelectionIsPendingAbortsBeforeClipboard() async throws {
        let editor = Editor()
        editor.deferSelection = true
        editor.onTick = { editor.state.text = "User's newer text" }
        await fails { try await editor.transaction.replace("old result", snapshot: editor.snapshot()) }
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertEqual(editor.state.text, "User's newer text")
    }

    func testFocusChangeDuringClipboardPreparationNeverSendsPaste() async throws {
        let editor = Editor()
        editor.onPrepare = { editor.focused = false }
        await fails { try await editor.transaction.replace("replacement", snapshot: editor.snapshot()) }
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertEqual(editor.restores, 1)
    }

    func testSelectionChangeDuringClipboardPreparationNeverSendsPaste() async throws {
        let editor = Editor()
        editor.onPrepare = { editor.state.selection = .init(location: 0, length: 0) }
        await fails { try await editor.transaction.replace("replacement", snapshot: editor.snapshot()) }
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertEqual(editor.state.selection, .init(location: 0, length: 0))
        XCTAssertEqual(editor.restores, 1)
    }

    func testNativeWriteMayTakeLongerThanSixtyMilliseconds() async throws {
        let editor = Editor()
        editor.web = false
        editor.directWrite = { _ in true }
        editor.onTick = { if editor.ticks == 15 { editor.state.text = "Native replacement" } }
        try await editor.transaction.replace("Native replacement", snapshot: editor.snapshot())
        XCTAssertEqual(editor.state.text, "Native replacement")
        XCTAssertEqual(editor.pasteCount, 0)
    }

    func testRendererRollbackIsNotReportedAsSuccessAndNeverRepasted() async throws {
        let editor = Editor()
        let original = editor.state.text
        editor.onTick = { if editor.ticks == 3 { editor.state.text = original } }
        await fails { try await editor.transaction.replace("replacement", snapshot: editor.snapshot()) }
        XCTAssertEqual(editor.pasteCount, 1)
        XCTAssertEqual(editor.restores, 1)
    }

    func testCancellationRestoresClipboardAndDoesNotRetry() async throws {
        let editor = Editor()
        editor.onTick = { throw CancellationError() }
        await fails { try await editor.transaction.replace("replacement", snapshot: editor.snapshot()) }
        XCTAssertEqual(editor.restores, 1)
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testFailedSelectedReplacementAppendsAfterSelectionWithoutDeletingIt() async throws {
        let editor = Editor()
        editor.rejectsSelectedPaste = true
        let outcome = try await editor.transaction.replace("[result]", snapshot: editor.snapshot(.selection))
        XCTAssertEqual(outcome, .insertedAtCaret)
        XCTAssertEqual(editor.state.text, "Before 这个产品[result] after")
        XCTAssertEqual(editor.pasteCount, 2)
        XCTAssertEqual(editor.restores, 2)
    }

    func testFailedFullReplacementInsertsAtOriginalCaretRatherThanFieldEnd() async throws {
        let editor = Editor()
        editor.state.selection = .init(location: 7, length: 0)
        editor.rejectsSelectedPaste = true
        let outcome = try await editor.transaction.replace("[result]", snapshot: editor.snapshot())
        XCTAssertEqual(outcome, .insertedAtCaret)
        XCTAssertEqual(editor.state.text, "Before [result]这个产品 after")
        XCTAssertEqual(editor.pasteCount, 2)
    }

    func testFailedSelectAllWithUnselectedCaretCanStillInsert() async throws {
        let editor = Editor()
        editor.state.selection = .init(location: 7, length: 0)
        editor.canSelect = false
        editor.ignoreSelectAll = true
        let outcome = try await editor.transaction.replace("[result]", snapshot: editor.snapshot())
        XCTAssertEqual(outcome, .insertedAtCaret)
        XCTAssertEqual(editor.state.text, "Before [result]这个产品 after")
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testFallbackCanCollapseVerifiedSelectionWhenAXSelectionIsUnsupported() async throws {
        let editor = Editor()
        editor.canSelect = false
        editor.supportsCollapse = true
        editor.rejectsSelectedPaste = true
        let outcome = try await editor.transaction.replace("[result]", snapshot: editor.snapshot(.selection))
        XCTAssertEqual(outcome, .insertedAtCaret)
        XCTAssertEqual(editor.state.text, "Before 这个产品[result] after")
    }

    func testFailedInsertionStopsAfterOneFallback() async throws {
        let editor = Editor()
        editor.rejectsEveryPaste = true
        await fails { try await editor.transaction.replace("[result]", snapshot: editor.snapshot(.selection)) }
        XCTAssertEqual(editor.state.text, "Before 这个产品 after")
        XCTAssertEqual(editor.pasteCount, 2)
        XCTAssertEqual(editor.restores, 2)
    }

    func testNativeNoOpWriteRetriesPasteAtOriginalSelectionBeforeInsertion() async throws {
        let editor = Editor()
        editor.web = false
        editor.directWrite = { _ in true }
        let outcome = try await editor.transaction.replace("[result]", snapshot: editor.snapshot(.selection))
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before [result] after")
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testUnchangedResultDoesNotTouchClipboardOrSelection() async throws {
        let editor = Editor()
        let original = editor.state
        try await editor.transaction.replace(original.text, snapshot: editor.snapshot())
        XCTAssertEqual(editor.state, original)
        XCTAssertEqual(editor.pasteCount, 0)
        XCTAssertNil(editor.requestedSelection)
    }

    func testNativeValueReplacementRetractsThenTypesResult() async throws {
        let editor = Editor()
        editor.web = false
        editor.supportsValueWrite = true

        let outcome = try await editor.transaction.replaceAnimated(
            "this product",
            snapshot: editor.snapshot(.selection)
        )

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertGreaterThan(editor.valueWriteCount, 3)
        XCTAssertTrue(editor.writtenValues.contains("Before  after"))
        XCTAssertTrue(editor.writtenValues.contains("Before t after"))
        XCTAssertEqual(editor.writtenValues.last, "Before this product after")
        XCTAssertEqual(editor.pasteCount, 0)
    }

    func testAnimatedReplacementFallsBackForWebInput() async throws {
        let editor = Editor()
        var events: [String] = []
        var transaction = editor.transaction
        transaction.trace = { event, _ in events.append(event) }

        let outcome = try await transaction.replaceAnimated(
            "this product",
            snapshot: editor.snapshot(.selection)
        )

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertEqual(editor.pasteCount, 1)
        XCTAssertTrue(events.contains("replacement_animation_fallback"))
    }

    func testWebReplacementUsesVerifiedKeyboardTypewriterAnimation() async throws {
        let editor = Editor()
        editor.supportsKeyboardAnimation = true

        let outcome = try await editor.transaction.replaceAnimated(
            "this product",
            snapshot: editor.snapshot(.selection)
        )

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertGreaterThan(editor.typedValues.count, 2)
        XCTAssertEqual(editor.typedValues.first, "t")
        XCTAssertEqual(editor.typedValues.joined(), "this product")
        XCTAssertEqual(editor.pasteCount, 0)
    }

    func testWebAnimationFallsBackAtomicallyWhenFirstKeyboardEventIsIgnored() async throws {
        let editor = Editor()
        editor.supportsKeyboardAnimation = true
        editor.ignoreKeyboardEvent = 1

        let outcome = try await editor.transaction.replaceAnimated(
            "this product",
            snapshot: editor.snapshot(.selection)
        )

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testWebAnimationFinishesSafelyIfLaterKeyboardEventIsIgnored() async throws {
        let editor = Editor()
        editor.supportsKeyboardAnimation = true
        editor.ignoreKeyboardEvent = 2

        let outcome = try await editor.transaction.replaceAnimated(
            "this product",
            snapshot: editor.snapshot(.selection)
        )

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(editor.state.text, "Before this product after")
        XCTAssertEqual(editor.pasteCount, 1)
    }

    func testAnimatedReplacementStopsWhenUserChangesText() async throws {
        let editor = Editor()
        editor.web = false
        editor.supportsValueWrite = true
        editor.onTick = {
            if editor.valueWriteCount == 1 {
                editor.state.text = "User's newer text"
                editor.state.selection = .init(location: 18, length: 0)
            }
        }

        await fails {
            try await editor.transaction.replaceAnimated("this product", snapshot: editor.snapshot(.selection))
        }
        XCTAssertEqual(editor.state.text, "User's newer text")
        XCTAssertEqual(editor.valueWriteCount, 1)
    }
}
