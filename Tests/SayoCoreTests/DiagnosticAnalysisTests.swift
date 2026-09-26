import XCTest
@testable import SayoCore

final class DiagnosticAnalysisTests: XCTestCase {
    private func line(_ event: String, _ fields: [String: String] = [:], timestamp: String = "2026-09-07T15:00:00.000Z") throws -> String {
        String(decoding: try JSONEncoder().encode(DiagnosticEvent(timestamp: timestamp, event: event, fields: fields)), as: UTF8.self)
    }
    func testInterleavedInvocationsGroupByIDAndOrderByInvocationStart() throws {
        let lines = try [
            line("invocation_started", ["invocationID": "a", "app": "flomo", "ordinal": "1"]),
            line("input", ["app": "flomo", "inputID": "field"]),
            line("invocation_started", ["invocationID": "b", "app": "flomo", "ordinal": "2"]),
            line("invocation_completed", ["invocationID": "b", "outcome": "replaced"]),
            line("invocation_cancelled", ["invocationID": "a"])
        ]
        let groups = DiagnosticAnalysis(jsonLines: lines.joined(separator: "\n")).groups.filter { $0.category == .invocation }
        XCTAssertEqual(groups.map(\.id), ["invocation:b", "invocation:a"])
        XCTAssertEqual(groups.map(\.outcome), ["replaced", "cancelled"])
        XCTAssertEqual(groups.map { $0.events.count }, [2, 2])
    }
    func testFallbackReasonDoesNotImplyInsertionSucceeded() throws {
        let lines = try [line("fallback_started", ["invocationID": "a", "reason": "replacement_unchanged"]),
                         line("replacement_failed", ["invocationID": "a", "error": "staleInput"])]
        let group = try XCTUnwrap(DiagnosticAnalysis(jsonLines: lines.joined(separator: "\n")).groups.first)
        XCTAssertEqual(group.outcome, "failed")
        XCTAssertEqual(group.fallbackReason, "replacement_unchanged")
        XCTAssertTrue(group.incomplete)
        XCTAssertTrue(group.summary(.simplifiedChinese).contains("失败"))
    }
    func testOldLogsAndMalformedLinesNeverInventInvocationOrCause() throws {
        let analysis = DiagnosticAnalysis(jsonLines: try line("bubble", ["app": "Old App", "phase": "replaced"]) + "\n{bad-json")
        XCTAssertEqual(analysis.unreadableLines, 1)
        XCTAssertEqual(analysis.groups.first?.category, .history)
        XCTAssertNil(analysis.groups.first?.fallbackReason)
        XCTAssertNil(analysis.groups.first?.outcome)
        XCTAssertTrue(DiagnosticEvent.fallbackExplanation(nil, .simplifiedChinese).contains("没有记录"))
    }
    func testInputGroupsSeparateAppsAndSortByMostRecentObservation() throws {
        let lines = try [line("input", ["bundleID": "a", "inputID": "same"]),
                         line("input", ["bundleID": "b", "inputID": "same"]),
                         line("input", ["bundleID": "a", "inputID": "same", "reason": "empty_value"])]
        let groups = DiagnosticAnalysis(jsonLines: lines.joined(separator: "\n")).groups
        XCTAssertEqual(groups.map(\.applicationKey), ["a", "b"])
        XCTAssertEqual(groups.map { $0.events.count }, [2, 1])
    }
    func testAppCapturedAtInvocationSurvivesFocusChangesAndExportRoundTrips() throws {
        let lines = try [line("invocation_started", ["invocationID": "a", "app": "Editor", "bundleID": "editor"]),
                         line("input_captured", ["invocationID": "a", "app": "Editor"]),
                         line("invocation_completed", ["invocationID": "a", "outcome": "inserted_at_caret"])]
        let analysis = DiagnosticAnalysis(jsonLines: lines.joined(separator: "\n"))
        let group = try XCTUnwrap(analysis.groups.first)
        XCTAssertEqual(group.application, "Editor")
        XCTAssertEqual(group.applicationKey, "editor")
        XCTAssertEqual(group.outcome, "inserted_at_caret")
        XCTAssertFalse(group.incomplete)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticEvent.self, from: Data(group.events[0].rawText.utf8)), group.events[0])
    }
    func testNetworkDiagnosticNeverIncludesServerResponseText() {
        XCTAssertEqual(DiagnosticEvent.errorCode(SayoError.network("secret response")), "network")
    }

    func testAIDiagnosticEvidenceIncludesAllRecentFailuresAndTheirFullTimelines() throws {
        let lines = try [
            line("invocation_started", ["invocationID": "a", "app": "Editor", "bundleID": "com.example.editor"], timestamp: "2026-09-07T14:49:30.000Z"),
            line("rewrite_requested", ["invocationID": "a"], timestamp: "2026-09-07T14:50:00.000Z"),
            line("invocation_failed", ["invocationID": "a", "error": "network"], timestamp: "2026-09-07T14:55:00.000Z"),
            line("invocation_started", ["invocationID": "b", "app": "Browser"], timestamp: "2026-09-07T14:58:00.000Z"),
            line("replacement_failed", ["invocationID": "b", "error": "replacementFailed"], timestamp: "2026-09-07T14:59:00.000Z"),
            line("invocation_started", ["invocationID": "old", "app": "Old App"], timestamp: "2026-09-07T14:40:00.000Z"),
            line("invocation_failed", ["invocationID": "old", "error": "network"], timestamp: "2026-09-07T14:49:59.000Z"),
            line("invocation_started", ["invocationID": "ok", "app": "Working App"], timestamp: "2026-09-07T14:59:00.000Z"),
            line("invocation_completed", ["invocationID": "ok", "outcome": "replaced"], timestamp: "2026-09-07T14:59:30.000Z")
        ]
        let evidence = AIDiagnosticEvidence(
            jsonLines: lines.joined(separator: "\n"),
            now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z"))
        )
        XCTAssertEqual(evidence.failures.map(\.application), ["Browser", "Editor"])
        XCTAssertEqual(evidence.failures[1].events.map(\.event), ["invocation_started", "rewrite_requested", "invocation_failed"])
        XCTAssertEqual(evidence.failures[1].bundleID, "com.example.editor")
    }

    func testAIDiagnosticEvidenceUsesAllowListAndRedactsTreePreviews() throws {
        let lines = try [
            line("invocation_started", [
                "invocationID": "secret-id", "operationID": "secret-operation", "pid": "42",
                "app": "Editor", "bundleID": "com.example.editor", "rawPreview": "private source",
                "resolvedPreview": "private translation", "unknownFutureField": "private future value",
                "tree": "0:AXTextArea classes=[editor] staticLength=7 preview=private text | 1:AXGroup classes=[] staticLength=-1"
            ], timestamp: "2026-09-07T14:59:00.000Z"),
            line("invocation_failed", ["invocationID": "secret-id", "error": "unsupportedInput"], timestamp: "2026-09-07T14:59:30.000Z")
        ]
        let evidence = AIDiagnosticEvidence(
            jsonLines: lines.joined(separator: "\n"),
            now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z"))
        )
        let fields = try XCTUnwrap(evidence.failures.first?.events.first?.fields)
        XCTAssertEqual(fields["app"], "Editor")
        XCTAssertEqual(fields["bundleID"], "com.example.editor")
        XCTAssertEqual(fields["tree"], "0:AXTextArea classes=[redacted] staticLength=7 preview=[redacted] | 1:AXGroup classes=[redacted] staticLength=-1")
        XCTAssertNil(fields["invocationID"])
        XCTAssertNil(fields["operationID"])
        XCTAssertNil(fields["pid"])
        XCTAssertNil(fields["rawPreview"])
        XCTAssertNil(fields["resolvedPreview"])
        XCTAssertNil(fields["unknownFutureField"])
        let exported = try evidence.jsonText()
        XCTAssertFalse(exported.contains("private source"))
        XCTAssertFalse(exported.contains("private translation"))
        XCTAssertFalse(exported.contains("secret-id"))
    }
}
