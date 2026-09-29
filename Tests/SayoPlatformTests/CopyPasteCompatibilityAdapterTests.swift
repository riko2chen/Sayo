import AppKit
import XCTest
import SayoCore
@testable import SayoPlatform

@MainActor
final class CopyPasteCompatibilityAdapterTests: XCTestCase {
    @MainActor private final class Fixture {
        let board = NSPasteboard(name: .init("sayo-compatibility-test-\(UUID())"))
        var editorID: String? = "first"
        var keys: [CGKeyCode] = []
        var pasted: String?
        var afterCopy: (() -> Void)?
        var beforeTargetRead: (() -> Void)?
        lazy var adapter = CopyPasteCompatibilityAdapter(targetSource: { [unowned self] in
            beforeTargetRead?()
            guard let editorID else { throw SayoError.unsupportedInput }
            return .init(pid: 123, bundleID: "test.app", applicationName: "Test", windowNumber: 1, editorID: editorID)
        }, sendCommandKey: { [unowned self] key, _ in
            keys.append(key)
            if key == 8 {
                board.clearContents(); board.setString("Same text", forType: .string)
                afterCopy?()
            } else if key == 9 {
                pasted = board.string(forType: .string)
            }
        }, pasteboard: board, isTrusted: { true })
    }

    func testReplacementUsesCapturedEditorAndRestoresClipboard() async throws {
        let fixture = Fixture(); defer { fixture.board.releaseGlobally() }
        fixture.board.setString("User clipboard", forType: .string)
        let context = try await fixture.adapter.captureCurrentSelection()
        let outcome = try await fixture.adapter.replace("Updated", in: context.snapshot())
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(fixture.keys, [8, 9])
        XCTAssertEqual(fixture.pasted, "Updated")
        XCTAssertEqual(fixture.board.string(forType: .string), "User clipboard")
    }

    func testIdenticalTextInAnotherFieldInSameWindowCannotReceivePaste() async throws {
        let fixture = Fixture(); defer { fixture.board.releaseGlobally() }
        let context = try await fixture.adapter.captureCurrentSelection()
        fixture.editorID = "second"
        do {
            _ = try await fixture.adapter.replace("Updated", in: context.snapshot())
            XCTFail("A different field must reject the old result.")
        } catch { XCTAssertEqual(error as? SayoError, .staleInput) }
        XCTAssertEqual(fixture.keys, [8])
        XCTAssertNil(fixture.pasted)
    }

    func testLostEditorIdentityInvalidatesSession() async throws {
        let fixture = Fixture(); defer { fixture.board.releaseGlobally() }
        _ = try await fixture.adapter.captureCurrentSelection()
        fixture.editorID = nil
        XCTAssertNil(fixture.adapter.currentContext())
        XCTAssertFalse(fixture.adapter.isActive)
        fixture.editorID = "first"
        XCTAssertNil(fixture.adapter.currentContext(), "A cancelled session cannot silently revive.")
    }

    func testUnidentifiableEditorCannotCaptureOrSendCopy() async {
        let fixture = Fixture(); defer { fixture.board.releaseGlobally() }
        fixture.editorID = nil
        do {
            _ = try await fixture.adapter.captureCurrentSelection()
            XCTFail("An app/window alone is not an editor identity.")
        } catch { XCTAssertEqual(error as? SayoError, .unsupportedInput) }
        XCTAssertTrue(fixture.keys.isEmpty)
    }

    func testFieldChangeWhileCopyIsInFlightRejectsCapture() async {
        let fixture = Fixture(); defer { fixture.board.releaseGlobally() }
        fixture.afterCopy = { fixture.editorID = "second" }
        defer { fixture.afterCopy = nil }
        do {
            _ = try await fixture.adapter.captureCurrentSelection()
            XCTFail("Copy must still belong to the captured field.")
        } catch { XCTAssertEqual(error as? SayoError, .staleInput) }
        XCTAssertFalse(fixture.adapter.isActive)
    }

    func testFocusIsRecheckedImmediatelyBeforePaste() async throws {
        let fixture = Fixture(); defer { fixture.board.releaseGlobally() }
        fixture.board.setString("User clipboard", forType: .string)
        let context = try await fixture.adapter.captureCurrentSelection()
        var reads = 0
        fixture.beforeTargetRead = {
            reads += 1
            if reads == 2 { fixture.editorID = "second" }
        }
        defer { fixture.beforeTargetRead = nil }
        do {
            _ = try await fixture.adapter.replace("Updated", in: context.snapshot())
            XCTFail("Preparing the clipboard must not bypass the final focus check.")
        } catch { XCTAssertEqual(error as? SayoError, .staleInput) }
        XCTAssertEqual(fixture.keys, [8])
        XCTAssertNil(fixture.pasted)
        XCTAssertEqual(fixture.board.string(forType: .string), "User clipboard")
    }
}
