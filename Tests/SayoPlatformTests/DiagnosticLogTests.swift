import XCTest
@testable import SayoPlatform

final class DiagnosticLogTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDisabledLogStopsNewRecordsWithoutDeletingExistingFiles() throws {
        let log = DiagnosticLog(directory: try temporaryDirectory())
        log.record("before", fields: ["value": "1"])
        XCTAssertTrue(try log.recentText().contains("before"))

        log.setEnabled(false)
        log.record("disabled", fields: ["value": "2"])
        XCTAssertFalse(try log.recentText().contains("disabled"))
        XCTAssertTrue(try log.recentText().contains("before"))

        log.setEnabled(true)
        log.record("after", fields: ["value": "3"])
        XCTAssertTrue(try log.recentText().contains("after"))
    }

    func testRepeatedPollingIsDeduplicatedAcrossInterleavedEvents() throws {
        let log = DiagnosticLog(directory: try temporaryDirectory())
        for _ in 0..<50 {
            log.record("input", fields: ["resolvedLength": "0"])
            log.record("bubble", fields: ["phase": "hidden"])
        }
        log.record("input", fields: ["resolvedLength": "9"])
        log.record("input", fields: ["resolvedLength": "0"])
        let lines = try log.recentText().split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(try log.recentText(limit: 1), String(lines.last!))
    }

    func testRotationKeepsBoundedFilesAndReadableChronologicalEvents() throws {
        let directory = try temporaryDirectory()
        let log = DiagnosticLog(directory: directory, maximumBytes: 300, archiveCount: 2)
        for index in 0..<20 { log.record("input", fields: ["index": String(index), "reason": "placeholder_filtered"]) }
        let lines = try log.recentText().split(separator: "\n")
        let indices = try lines.map { line -> Int in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let fields = try XCTUnwrap(object["fields"] as? [String: String])
            return try XCTUnwrap(Int(fields["index"] ?? ""))
        }
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(indices.last, 19)
        XCTAssertLessThan(indices.count, 20)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.count, 3)
        for file in files {
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 300)
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testMultilineSnippetsStayInOneJSONRecordAndExistingLogsSurviveRestart() throws {
        let directory = try temporaryDirectory()
        let log = DiagnosticLog(directory: directory)
        let snippet = "现在的想法是...\n\"test\""
        log.record("input", fields: ["rawPreview": snippet])
        let saved = try log.recentText()
        XCTAssertEqual(saved.split(separator: "\n").count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        XCTAssertEqual((object["fields"] as? [String: String])?["rawPreview"], snippet)
        let restarted = DiagnosticLog(directory: directory)
        restarted.record("launch", fields: ["textSnippets": "false"])
        XCTAssertEqual(try restarted.recentText().split(separator: "\n").count, 2)
    }

    func testWriteErrorsAreVisibleWhenUserReadsLogs() throws {
        let path = try temporaryDirectory()
        try Data("not a directory".utf8).write(to: path)
        let log = DiagnosticLog(directory: path)
        log.record("input", fields: ["reason": "empty_value"])
        XCTAssertThrowsError(try log.recentText())
    }

    func testViewerShowsNewestFirstInLocalTimeWhileExportKeepsUTC() throws {
        let log = DiagnosticLog(directory: try temporaryDirectory())
        try log.prepareDirectory()
        let original = """
        {"timestamp":"2026-09-07T13:45:51.711Z","event":"launch","fields":{}}
        {"timestamp":"2026-09-07T16:46:09.276Z","event":"input","fields":{"resolvedLength":"0"}}
        """
        try original.write(to: log.fileURL, atomically: true, encoding: .utf8)
        let display = try log.recentDisplayText(timeZone: XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600)))
        XCTAssertTrue(display.hasPrefix("[2026-09-08 00:46:09.276 +08:00] input\n"))
        XCTAssertTrue(display.contains("[2026-09-07 21:45:51.711 +08:00] launch"))
        XCTAssertEqual(try log.recentText(), original)
    }

    func testViewerTakesLatestWindowBeforeReversingAndReadsNewWrites() throws {
        let log = DiagnosticLog(directory: try temporaryDirectory())
        for index in 0..<205 { log.record("input", fields: ["index": String(index)]) }
        let first = try log.recentDisplayText()
        XCTAssertEqual(first.components(separatedBy: "] input\n").count - 1, 200)
        XCTAssertEqual(first.split(separator: "\n")[1], "{\"index\":\"204\"}")
        XCTAssertTrue(first.hasSuffix("{\"index\":\"5\"}"))
        log.record("input", fields: ["index": "205"])
        let refreshed = try log.recentDisplayText()
        XCTAssertEqual(refreshed.split(separator: "\n")[1], "{\"index\":\"205\"}")
        XCTAssertTrue(refreshed.hasSuffix("{\"index\":\"6\"}"))
    }
}
