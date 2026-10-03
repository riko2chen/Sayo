import AppKit
import XCTest
@testable import SayoPlatform

@MainActor
final class PasteboardLeaseTests: XCTestCase {
    func testRestoresAllClipboardRepresentations() throws {
        let board = NSPasteboard(name: .init("sayo-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let rtf = Data("{\\rtf1\\ansi original}".utf8)
        item.setString("original", forType: .string)
        item.setData(rtf, forType: .rtf)
        board.writeObjects([item])
        let lease = try PasteboardLease(text: "replacement", pasteboard: board)
        XCTAssertEqual(board.string(forType: .string), "replacement")
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .rtf), rtf)
    }

    func testUserCopyAfterPasteIsNeverOverwrittenByRestore() throws {
        let board = NSPasteboard(name: .init("sayo-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let lease = try PasteboardLease(text: "replacement", pasteboard: board)
        board.clearContents()
        board.setString("new user copy", forType: .string)
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testSelectionCaptureRequiresANewCopyAndRestoresAllRepresentations() throws {
        let board = NSPasteboard(name: .init("sayo-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let rtf = Data("{\\rtf1\\ansi original}".utf8)
        item.setString("original", forType: .string)
        item.setData(rtf, forType: .rtf)
        board.writeObjects([item])

        let lease = try SelectionCaptureLease(pasteboard: board)
        XCTAssertNil(lease.capturedString(), "Old clipboard text must not look like a selection.")
        board.clearContents()
        board.setString("selected text", forType: .string)
        XCTAssertEqual(lease.capturedString(), "selected text")
        lease.restore()

        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .rtf), rtf)
    }

    func testSelectionCaptureDoesNotOverwriteANewerUserCopy() throws {
        let board = NSPasteboard(name: .init("sayo-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let lease = try SelectionCaptureLease(pasteboard: board)
        board.clearContents()
        board.setString("selected text", forType: .string)
        XCTAssertEqual(lease.capturedString(), "selected text")

        board.clearContents()
        board.setString("new user copy", forType: .string)
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testCopyPasteFallbackOnlyAllowsUnreadableEditorReasons() {
        for reason in ["no_focused_element", "role_unavailable", "unsupported_role",
                       "value_or_selection_unavailable", "input_not_writable"] {
            XCTAssertTrue(CopyPasteCompatibilityAdapter.shouldAttemptFallback(after: ["reason": reason]))
        }
        for reason in ["secure_input_skipped", "terminal_or_excluded_app", "terminal_detected", "excluded_app", "sayo_settings",
                       "permission_required", "value_preserved"] {
            XCTAssertFalse(CopyPasteCompatibilityAdapter.shouldAttemptFallback(after: ["reason": reason]))
        }
    }
}
