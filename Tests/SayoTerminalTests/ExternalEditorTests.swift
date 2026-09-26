import Foundation
import XCTest
@testable import SayoTerminal

final class ExternalEditorTests: XCTestCase {
    private func withDraft(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("draft with spaces.txt")
        try Data("你好 👋\nsecond line\n\n".utf8).write(to: file)
        try await body(file)
    }

    func testUnicodeMultilineRoundTrip() async throws {
        try await withDraft { file in
            try await ExternalEditor.edit(fileURL: file) { text in
                XCTAssertEqual(text, "你好 👋\nsecond line\n\n")
                return "改写 ✅\n\n"
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "改写 ✅\n\n")
        }
    }

    func testFailurePreservesOriginal() async throws {
        try await withDraft { file in
            let original = try Data(contentsOf: file)
            do {
                try await ExternalEditor.edit(fileURL: file) { _ in throw CancellationError() }
                XCTFail("Expected cancellation")
            } catch is CancellationError { }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testConcurrentEditIsNotOverwritten() async throws {
        try await withDraft { file in
            do {
                try await ExternalEditor.edit(fileURL: file) { _ in
                    try Data("new draft".utf8).write(to: file)
                    return "rewrite"
                }
                XCTFail("Expected conflict")
            } catch { }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new draft")
        }
    }

    func testInvalidAndOversizedInputDoesNotReachBridge() async throws {
        for data in [Data([0xff]), Data(repeating: 65, count: 64_001)] {
            try await withDraft { file in
                try data.write(to: file)
                do {
                    try await ExternalEditor.edit(fileURL: file) { _ in
                        XCTFail("Invalid draft must not reach bridge")
                        return "rewrite"
                    }
                    XCTFail("Expected invalid input")
                } catch { }
                XCTAssertEqual(try Data(contentsOf: file), data)
            }
        }
    }
}
