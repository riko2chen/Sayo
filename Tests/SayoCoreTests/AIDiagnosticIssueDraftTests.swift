import XCTest
@testable import SayoCore

final class AIDiagnosticIssueDraftTests: XCTestCase {
    private func evidence(count: Int = 1) throws -> AIDiagnosticEvidence {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z"))
        let lines = try (0..<count).map { index in
            String(decoding: try JSONEncoder().encode(DiagnosticEvent(
                timestamp: "2026-09-07T14:59:00.000Z", event: "invocation_failed",
                fields: ["invocationID": "private-\(index)", "app": "编辑器 + & # \(index)", "error": "network", "rawPreview": "secret input"]
            )), as: UTF8.self)
        }
        return AIDiagnosticEvidence(jsonLines: lines.joined(separator: "\n"), now: now)
    }

    func testOpensNewIssueFormWithEncodedRedactedAnalysisAndSelectedEvidence() throws {
        let draft = try AIDiagnosticIssueDraft(
            result: "检查辅助功能 + & #\nEmail: user@example.com; /Users/alice/private; sk-secret-key",
            evidence: evidence(), version: "0.1.0", build: "1000", osVersion: "macOS 15.0"
        )
        XCTAssertEqual(draft.url.host, "github.com")
        XCTAssertEqual(draft.url.path, "/riko2chen/Sayo/issues/new")
        let items = try XCTUnwrap(URLComponents(url: draft.url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try XCTUnwrap(items.first(where: { $0.name == "body" })?.value)
        XCTAssertTrue(body.contains("检查辅助功能 + & #\n"))
        XCTAssertTrue(body.contains("编辑器 + & # 0"))
        XCTAssertTrue(body.contains("30 minutes"))
        XCTAssertTrue(body.contains("0.1.0 (1000)"))
        XCTAssertTrue(draft.url.absoluteString.contains("%2B"))
        for secret in ["user@example.com", "alice", "sk-secret-key", "private-0", "secret input"] {
            XCTAssertFalse(body.contains(secret), secret)
        }
        XCTAssertFalse(draft.isAbbreviated)
    }

    func testLongUnicodeReportFitsURLAndClearlyMarksAbbreviation() throws {
        let draft = try AIDiagnosticIssueDraft(
            result: String(repeating: "分析结果🔍需要检查辅助功能。", count: 2_000),
            evidence: evidence(count: 100), version: "0.1.0", build: "1000", osVersion: "macOS 15.0"
        )
        XCTAssertLessThanOrEqual(draft.url.absoluteString.utf8.count, AIDiagnosticIssueDraft.maximumURLBytes)
        XCTAssertTrue(draft.isAbbreviated)
        let body = try XCTUnwrap(URLComponents(url: draft.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "body" })?.value)
        XCTAssertTrue(body.contains("abbreviated"))
        XCTAssertTrue(body.contains("分析结果"))
        XCTAssertTrue(body.contains("编辑器"))
        XCTAssertTrue(body.contains("Save the full result file"))
    }

    func testModelOutputRedactsKnownCredentialsAndPrivatePatterns() {
        let text = DiagnosticRedaction.text("custom-secret-value token=hidden Bearer abc.def ~/private.txt 192.168.1.10", secrets: ["custom-secret-value"])
        for secret in ["custom-secret-value", "hidden", "abc.def", "private.txt", "192.168.1.10"] {
            XCTAssertFalse(text.contains(secret))
        }
    }
}
