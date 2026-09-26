import XCTest
import SayoCore
@testable import SayoUI

@MainActor
final class AIDiagnosticModelTests: XCTestCase {
    private func line(_ event: String, _ fields: [String: String], timestamp: String) throws -> String {
        String(decoding: try JSONEncoder().encode(
            DiagnosticEvent(timestamp: timestamp, event: event, fields: fields)
        ), as: UTF8.self)
    }

    func testRunsDiagnosisWithRedactedRecentFailureEvidence() async throws {
        var settings = AppSettings()
        settings.interfaceLanguage = .simplifiedChinese
        let model = AppViewModel(settings: settings)
        model.diagnosticText = try [
            line("invocation_started", [
                "invocationID": "private-id", "app": "Editor", "rawPreview": "private text"
            ], timestamp: "2026-09-07T14:59:00.000Z"),
            line("invocation_failed", [
                "invocationID": "private-id", "error": "unsupportedInput"
            ], timestamp: "2026-09-07T14:59:30.000Z")
        ].joined(separator: "\n")
        model.refreshDiagnosticsAction = { model.diagnosticText }
        let called = expectation(description: "model called")
        model.runAIDiagnosticsAction = { evidence in
            XCTAssertTrue(evidence.contains("Editor"))
            XCTAssertFalse(evidence.contains("private text"))
            XCTAssertFalse(evidence.contains("private-id"))
            called.fulfill()
            return "建议检查辅助功能。"
        }

        model.runAIDiagnostics(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z")))
        await fulfillment(of: [called], timeout: 1)
        for _ in 0..<20 where model.aiDiagnosticRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.aiDiagnosticResult, "建议检查辅助功能。")
        XCTAssertEqual(model.aiDiagnosticFailureCount, 1)
        XCTAssertFalse(model.aiDiagnosticRunning)
        XCTAssertTrue(model.aiDiagnosticStatus.contains("已完成"))
    }

    func testDoesNotCallModelWhenNoFailuresExistInWindow() throws {
        let model = AppViewModel(settings: .init())
        model.diagnosticText = try line(
            "invocation_failed",
            ["invocationID": "old", "error": "network"],
            timestamp: "2026-09-07T14:40:00.000Z"
        )
        model.refreshDiagnosticsAction = { model.diagnosticText }
        model.runAIDiagnosticsAction = { _ in XCTFail("Model should not be called"); return "" }

        model.runAIDiagnostics(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z")))

        XCTAssertTrue(model.aiDiagnosticResult.isEmpty)
        XCTAssertTrue(model.aiDiagnosticEvidence.isEmpty)
        XCTAssertTrue(model.aiDiagnosticStatus.contains("No failed cases"))
    }
}
