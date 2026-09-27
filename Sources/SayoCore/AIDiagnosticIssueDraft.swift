import Foundation

/// Defense in depth for free-form values and model output. Evidence fields are
/// allow-listed separately; this is not a substitute for that allow-list.
public enum DiagnosticRedaction {
    public static func text(_ source: String, secrets: [String] = []) -> String {
        var result = source
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        let patterns = [
            #"(?i)\b(?:https?|file)://[^\s<>\"`]+"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?:/(?:Users|home|Volumes|private|tmp)/|~/)[^\s<>\"`]+"#,
            #"(?i)\b(?:sk-[A-Z0-9_-]+|gh[pousr]_[A-Z0-9_]+|github_pat_[A-Z0-9_]+)\b"#,
            #"(?i)\bBearer\s+[A-Z0-9._~+/-]+=*"#,
            #"(?i)\b(?:api[_ -]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }
}

/// Opens GitHub's editable new-issue form. It never submits an issue.
public struct AIDiagnosticIssueDraft: Equatable, Sendable {
    // Bound the percent-encoded URL, including non-ASCII text and JSON punctuation.
    public static let maximumURLBytes = 7_500
    public let url: URL
    public let isAbbreviated: Bool

    public init(result: String, evidence: AIDiagnosticEvidence, version: String, build: String, osVersion: String) throws {
        var analysis = DiagnosticRedaction.text(result)
        var details = try evidence.jsonText()
        let title = "[AI diagnosis] \(evidence.failures.count) failed case(s)"
        let introduction = """
        ## Sayo diagnostic report
        Sayo: \(DiagnosticRedaction.text(version)) (\(DiagnosticRedaction.text(build)))
        macOS: \(DiagnosticRedaction.text(osVersion))
        Scan: \(evidence.windowStart) – \(evidence.generatedAt) (\(evidence.windowMinutes) minutes)
        Selected failed cases: \(evidence.failures.count)

        Please review this redacted draft before submitting. AI suggestions may be incorrect.
        Add reproduction steps, expected behavior, and actual behavior if helpful.
        """
        func draftURL(abbreviated: Bool) -> URL? {
            let note = abbreviated
                ? "\n\nThis draft is abbreviated to fit the browser URL. Save the full result file in Sayo and attach it if needed."
                : ""
            let body = """
            \(introduction)\(note)

            ## AI analysis
            \(analysis)

            ## Redacted evidence\(abbreviated ? " (excerpt)" : "")
            ````text
            \(details)
            ````
            """
            var components = URLComponents(string: "https://github.com/riko2chen/Sayo/issues/new")!
            components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            // A literal '+' in a query must survive form-style query decoding.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url
        }
        var abbreviated = false
        guard var candidate = draftURL(abbreviated: false) else { throw SayoError.invalidResponse }
        if candidate.absoluteString.utf8.count > Self.maximumURLBytes {
            abbreviated = true
            details = evidence.failures.enumerated().map { index, failure in
                let error = failure.events.last(where: { $0.event == "invocation_failed" || $0.event == "replacement_failed" })?.fields["error"] ?? "unknown"
                return "\(index + 1). \(failure.application) | \(failure.failedAt) | \(error)"
            }.joined(separator: "\n")
            candidate = draftURL(abbreviated: true)!
        }
        while candidate.absoluteString.utf8.count > Self.maximumURLBytes {
            // Shorten the larger encoded section; keep both analysis and case evidence.
            func cost(_ value: String) -> Int { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.utf8.count ?? value.utf8.count }
            if cost(analysis) >= cost(details), analysis.count > 40 {
                analysis = String(analysis.prefix(analysis.count * 3 / 4)) + "\n[…]"
            } else if details.count > 40 {
                details = String(details.prefix(details.count * 3 / 4)) + "\n[…]"
            } else { throw SayoError.invalidResponse }
            candidate = draftURL(abbreviated: true)!
        }
        url = candidate
        isAbbreviated = abbreviated
    }
}
