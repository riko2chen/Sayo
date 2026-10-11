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

    func testClaudeGotoArgumentsRewriteTheDraftAndPreserveSpaces() async throws {
        try await withDraft { file in
            for arguments in [[file.path], ["-g", file.path + ":1"], ["--goto", file.path + ":12:3"]] {
                XCTAssertEqual(try ExternalEditor.draftURL(arguments: arguments), file)
            }
            let url = try ExternalEditor.draftURL(arguments: ["-g", file.path + ":1"])
            try await ExternalEditor.edit(fileURL: url) { _ in "rewritten" }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "rewritten")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ":1"))
        }
    }

    func testGotoPreservesLiteralNumericFilenameSuffixAndRejectsAmbiguousPaths() async throws {
        try await withDraft { file in
            let numericFile = URL(fileURLWithPath: file.path + ":12")
            try Data("literal filename".utf8).write(to: numericFile)
            XCTAssertEqual(try ExternalEditor.draftURL(arguments: [numericFile.path]), numericFile)
            XCTAssertEqual(try ExternalEditor.draftURL(arguments: ["-g", numericFile.path]), numericFile)
            XCTAssertThrowsError(try ExternalEditor.draftURL(arguments: ["-g", numericFile.path + ":3"]))
            XCTAssertEqual(try String(contentsOf: numericFile, encoding: .utf8), "literal filename")
        }
    }

    func testInvalidEditorArgumentsDoNotSelectOrModifyADraft() async throws {
        try await withDraft { file in
            let original = try Data(contentsOf: file)
            for arguments in [[], ["--unknown", file.path], ["-g", file.path + ":bad"],
                              ["-g", file.path + ":1", "another-file"], ["-g", "/missing-draft:1"]] {
                XCTAssertThrowsError(try ExternalEditor.draftURL(arguments: arguments))
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
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
