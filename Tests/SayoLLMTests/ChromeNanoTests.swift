import XCTest
import SayoCore
@testable import SayoLLM

final class ChromeNanoDetectionTests: XCTestCase {
    func testMissingAndInaccessibleDirectoriesAreNotConfused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ChromeNanoInstallation.inspect(home: root, applications: root).fileInspectionUnavailable)
        let parent = root.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data([1]).write(to: parent.appendingPathComponent("OptGuideOnDeviceModel"))
        XCTAssertTrue(ChromeNanoInstallation.inspect(home: root, applications: root).fileInspectionUnavailable)
    }
    func testDetectionRequiresManifestWeightsAndExecutionConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let component = root.appendingPathComponent("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/1")
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
        try Data(#"{"version":"1.2.3.4"}"#.utf8).write(to: component.appendingPathComponent("manifest.json"))
        try Data([1, 2, 3]).write(to: component.appendingPathComponent("weights.bin"))
        XCTAssertTrue(ChromeNanoInstallation.inspect(home: root, applications: root).components.isEmpty)
        try Data([1]).write(to: component.appendingPathComponent("on_device_model_execution_config.pb"))
        let result = ChromeNanoInstallation.inspect(home: root, applications: root)
        XCTAssertFalse(result.chromeInstalled)
        XCTAssertEqual(result.components.map(\.version), ["1.2.3.4"])
        XCTAssertEqual(result.components.first?.bytes, 3)
        try Data().write(to: component.appendingPathComponent("weights.bin"))
        XCTAssertTrue(ChromeNanoInstallation.inspect(home: root, applications: root).components.isEmpty)
    }

    func testHTTPParserWaitsForCompleteBodyAndRejectsAmbiguousFraming() throws {
        let head = "POST /poll HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try NanoHTTPRequest.parse(Data((head + "{").utf8)))
        XCTAssertEqual(try NanoHTTPRequest.parse(Data((head + "{}").utf8))?.body, Data("{}".utf8))
        for header in ["Content-Length: -1", "Content-Length: 200000", "Content-Length: 0\r\nContent-Length: 2", "Transfer-Encoding: chunked"] {
            XCTAssertThrowsError(try NanoHTTPRequest.parse(Data("POST / HTTP/1.1\r\n\(header)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try NanoHTTPRequest.parse(Data(repeating: 65, count: 16_385)))
        XCTAssertThrowsError(try NanoHTTPRequest.parse(Data((head + "{}extra").utf8)))
    }
}

@MainActor final class ChromeNanoBridgeTests: XCTestCase {
    private func fragmentParameters(_ url: URL) -> [String: String] {
        let items = URLComponents(string: "?" + (url.fragment ?? ""))?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    private func post(_ url: URL, path: String, body: [String: Any], token: String? = nil,
                      origin: String? = nil) async throws -> (Int, [String: Any]) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/" + path
        components.fragment = nil
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token ?? fragmentParameters(url)["token"] ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode,
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    private func nextJob(_ url: URL) async throws -> [String: Any] {
        for _ in 0..<30 {
            let (_, response) = try await post(url, path: "poll", body: ["ready": true])
            if let job = response["job"] as? [String: Any] { return job }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("No pending request reached the browser")
        throw SayoError.invalidResponse
    }

    func testConnectionPageReceivesResolvedSayoLanguageWithoutPuttingTokenInHTTPPath() async throws {
        let bridge = ChromeNanoBridge()
        defer { bridge.stop() }
        for language in InterfaceLanguage.allCases {
            let url = try await bridge.connectionURL(interfaceLanguage: language)
            XCTAssertEqual(fragmentParameters(url)["lang"], language.resolved == .simplifiedChinese ? "zh-CN" : "en")
            XCTAssertFalse(fragmentParameters(url)["token", default: ""].isEmpty)
            XCTAssertNil(url.query)
            XCTAssertEqual(url.path, "/")
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("id=\"language\""))
            let authenticated = try await post(url, path: "poll", body: ["ready": true])
            XCTAssertEqual(authenticated.0, 200)
        }
    }

    func testAuthenticatedRoundTripAndSessionIsolation() async throws {
        let bridge = ChromeNanoBridge()
        defer { bridge.stop() }
        let url = try await bridge.connectionURL()
        let denied = try await post(url, path: "poll", body: ["ready": true], token: "wrong")
        XCTAssertEqual(denied.0, 403)
        let crossOrigin = try await post(url, path: "poll", body: ["ready": true], origin: "https://example.com")
        XCTAssertEqual(crossOrigin.0, 403)
        XCTAssertFalse(bridge.isConnected)
        _ = try await post(url, path: "poll", body: ["ready": true])
        XCTAssertTrue(bridge.isConnected)
        let task = Task { try await bridge.rewrite(.init(text: "She go to school yesterday.", prompt: "Correct grammar.", targetLanguage: .english)) }
        let job = try await nextJob(url)
        XCTAssertEqual(job["text"] as? String, "She go to school yesterday.")
        XCTAssertNil(job["inputLanguages"])
        XCTAssertNil(job["outputLanguages"])
        let repeated = try await post(url, path: "poll", body: ["ready": true])
        XCTAssertTrue(repeated.1["job"] is NSNull)
        _ = try await post(url, path: "result", body: ["id": job["id"]!, "text": "She went to school yesterday."])
        let result = try await task.value
        XCTAssertEqual(result.text, "She went to school yesterday.")
        let rotated = try await bridge.connectionURL()
        XCTAssertNotEqual(url.fragment, rotated.fragment)
        let stale = try await post(url, path: "poll", body: ["ready": true])
        XCTAssertEqual(stale.0, 403)
        XCTAssertFalse(bridge.isConnected)
    }

    func testCancellationRemovesJobAndIgnoresLateResult() async throws {
        let bridge = ChromeNanoBridge()
        defer { bridge.stop() }
        let url = try await bridge.connectionURL()
        _ = try await post(url, path: "poll", body: ["ready": true])
        let task = Task { try await bridge.rewrite(.init(text: "A test sentence.", prompt: "Rewrite.")) }
        let job = try await nextJob(url)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let poll = try await post(url, path: "poll", body: ["ready": true])
        XCTAssertTrue(poll.1["activeID"] is NSNull)
        let late = try await post(url, path: "result", body: ["id": job["id"]!, "text": "Stale answer"])
        XCTAssertEqual(late.0, 404)
    }

    func testAllTargetLanguagesAndMultilingualInputReachChromeUnchanged() async throws {
        let bridge = ChromeNanoBridge()
        defer { bridge.stop() }
        let url = try await bridge.connectionURL()
        _ = try await post(url, path: "poll", body: ["ready": true])
        for language in TargetLanguage.allCases {
            var settings = AppSettings()
            settings.targetLanguage = language
            let prompt = settings.effectivePrompt
            let input = "这个产品很好用。한국어 العربية Русский"
            let task = Task { try await bridge.rewrite(.init(text: input, prompt: prompt, targetLanguage: language)) }
            let job = try await nextJob(url)
            XCTAssertEqual(job["text"] as? String, input)
            XCTAssertEqual(job["prompt"] as? String, prompt)
            XCTAssertTrue(prompt.contains(language.promptName))
            XCTAssertNil(job["inputLanguages"], language.rawValue)
            XCTAssertNil(job["outputLanguages"], language.rawValue)
            _ = try await post(url, path: "result", body: ["id": job["id"]!, "text": "模型返回的原文"])
            let result = try await task.value
            XCTAssertEqual(result.text, "模型返回的原文")
        }
    }

    func testTimeoutStillFailsWithoutCloudFallback() async throws {
        let bridge = ChromeNanoBridge(requestTimeout: 0.05)
        defer { bridge.stop() }
        let url = try await bridge.connectionURL()
        _ = try await post(url, path: "poll", body: ["ready": true])
        do {
            _ = try await bridge.rewrite(.init(text: "Hello", prompt: "Rewrite"))
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    func testBrowserErrorIsSanitizedAndEmptyOutputRejected() async throws {
        let bridge = ChromeNanoBridge()
        defer { bridge.stop() }
        let url = try await bridge.connectionURL()
        _ = try await post(url, path: "poll", body: ["ready": true])
        for response in [["error": "private source text"], ["text": "  "]] {
            let task = Task { try await bridge.rewrite(.init(text: "Test", prompt: "Rewrite")) }
            let job = try await nextJob(url)
            var body: [String: Any] = response
            body["id"] = job["id"]
            _ = try await post(url, path: "result", body: body)
            do { _ = try await task.value; XCTFail("Expected failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private source text")) }
        }
    }
}
