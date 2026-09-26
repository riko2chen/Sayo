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

        model.prepareAIDiagnostics(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z")))
        XCTAssertEqual(model.aiDiagnosticSelectedCases, [0])
        XCTAssertFalse(model.aiDiagnosticRunning)
        model.runAIDiagnostics()
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
            timestamp: "2026-09-07T14:29:59.000Z"
        )
        model.refreshDiagnosticsAction = { model.diagnosticText }
        model.runAIDiagnosticsAction = { _ in XCTFail("Model should not be called"); return "" }

        model.prepareAIDiagnostics(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z")))

        XCTAssertTrue(model.aiDiagnosticResult.isEmpty)
        XCTAssertTrue(model.aiDiagnosticEvidence.isEmpty)
        XCTAssertTrue(model.aiDiagnosticStatus.contains("No failed cases"))
    }

    private func scannedModel() throws -> AppViewModel {
        let model = AppViewModel(settings: .init())
        model.refreshDiagnosticsAction = {
            try [self.line("invocation_failed", ["invocationID": "a", "app": "Editor", "error": "network"], timestamp: "2026-09-07T14:40:00.000Z"),
                 self.line("invocation_failed", ["invocationID": "b", "app": "Browser", "error": "unsupportedInput"], timestamp: "2026-09-07T14:59:00.000Z")].joined(separator: "\n")
        }
        model.prepareAIDiagnostics(now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z")))
        return model
    }

    func testScanningSelectionAndEmptyAuthorizationNeverCallModel() async throws {
        let model = try scannedModel()
        model.runAIDiagnosticsAction = { _ in XCTFail("Unapproved cases must not be sent"); return "" }
        XCTAssertEqual(model.aiDiagnosticSelectedCases, [0, 1])
        XCTAssertTrue(model.aiDiagnosticEvidence.isEmpty)
        model.selectAIDiagnosticCase(0, selected: false)
        XCTAssertEqual(model.aiDiagnosticSelectedCases, [1])
        model.invertAIDiagnosticSelection()
        XCTAssertEqual(model.aiDiagnosticSelectedCases, [0])
        model.selectAllAIDiagnosticCases()
        model.invertAIDiagnosticSelection()
        model.runAIDiagnostics()
        await Task.yield()
        XCTAssertFalse(model.aiDiagnosticRunning)
        XCTAssertTrue(model.aiDiagnosticEvidence.isEmpty)
    }

    func testAuthorizationUsesOnlySelectedSnapshotAndExportsSameEvidence() async throws {
        let model = try scannedModel()
        model.selectAIDiagnosticCase(0, selected: false)
        model.refreshDiagnosticsAction = { "" }
        model.refreshDiagnostics()
        var callCount = 0
        model.apiKey = "known-custom-secret"
        model.runAIDiagnosticsAction = { source in
            callCount += 1
            let evidence = try JSONDecoder().decode(AIDiagnosticEvidence.self, from: Data(source.utf8))
            XCTAssertEqual(evidence.failures.map(\.application), ["Editor"])
            try await Task.sleep(for: .milliseconds(20))
            return "Check permissions known-custom-secret"
        }
        model.runAIDiagnostics()
        model.runAIDiagnostics()
        model.invertAIDiagnosticSelection()
        XCTAssertEqual(model.aiDiagnosticSelectedCases, [1])
        for _ in 0..<100 where model.aiDiagnosticRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(model.aiDiagnosticFailureCount, 1)
        XCTAssertEqual(model.aiDiagnosticResult, "Check permissions [redacted]")
        var exported = false
        model.saveAIDiagnosticReportAction = { result, source in
            exported = true
            XCTAssertEqual(result, model.aiDiagnosticResult)
            XCTAssertEqual(source, model.aiDiagnosticEvidence)
            XCTAssertFalse(source.contains("Browser"))
        }
        model.saveAIDiagnosticReport()
        XCTAssertTrue(exported)
        var opened = false
        model.openAIDiagnosticIssueAction = { url in
            opened = true
            let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "body" })?.value ?? ""
            XCTAssertTrue(body.contains("Editor"))
            XCTAssertFalse(body.contains("Browser"))
            XCTAssertFalse(body.contains("known-custom-secret"))
            return true
        }
        model.openAIDiagnosticIssue()
        XCTAssertTrue(opened)
    }

    func testFailedScanDoesNotAuthorizeStaleEvidence() async throws {
        let model = try scannedModel()
        model.refreshDiagnosticsAction = { throw SayoError.invalidResponse }
        model.runAIDiagnosticsAction = { _ in XCTFail("Stale evidence must not be sent"); return "" }
        model.prepareAIDiagnostics()
        model.runAIDiagnostics()
        await Task.yield()
        XCTAssertNil(model.aiDiagnosticCandidates)
        XCTAssertTrue(model.aiDiagnosticSelectedCases.isEmpty)
        XCTAssertTrue(model.aiDiagnosticStatus.contains("Refresh failed"))
    }

    func testAnalysisFailureAllowsRetryAndBrowserFailureIsReported() async throws {
        let model = try scannedModel()
        model.runAIDiagnosticsAction = { _ in throw SayoError.invalidResponse }
        model.runAIDiagnostics()
        for _ in 0..<100 where model.aiDiagnosticRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.aiDiagnosticRunning)
        XCTAssertTrue(model.aiDiagnosticResult.isEmpty)
        XCTAssertTrue(model.aiDiagnosticStatus.contains("failed"))
        XCTAssertEqual(model.aiDiagnosticSelectedCases, [0, 1])
        model.runAIDiagnosticsAction = { _ in "Try again" }
        model.runAIDiagnostics()
        for _ in 0..<100 where model.aiDiagnosticRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.aiDiagnosticResult, "Try again")
        model.openAIDiagnosticIssueAction = { _ in false }
        model.openAIDiagnosticIssue()
        XCTAssertTrue(model.aiDiagnosticStatus.contains("Could not open GitHub"))
    }
}
