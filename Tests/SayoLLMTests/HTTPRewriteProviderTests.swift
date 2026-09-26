import Foundation
import XCTest
import SayoCore
@testable import SayoLLM

final class HTTPRewriteProviderTests: XCTestCase {
    func testPlatformPresetsUseTheirOwnChatEndpointAndKey() async throws {
        for kind in [ProviderKind.deepSeek, .internAI, .qwen, .moonshot, .zhipu, .doubao, .siliconFlow, .openRouter, .magpie] {
            let transport = MockTransport { request in
                let data = Data(#"{"choices":[{"message":{"content":"rewritten"},"finish_reason":"stop"}]}"#.utf8)
                return (data, Self.httpResponse(for: request, status: 200))
            }
            let provider = HTTPRewriteProvider(configuration: configuration(provider: kind, baseURL: kind.defaultBaseURL, model: "test-model"), apiKey: kind.rawValue + "-key", transport: transport)
            let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
            XCTAssertEqual(result.text, "rewritten")
            let recorded = await transport.lastRequest(); let request = try XCTUnwrap(recorded)
            XCTAssertEqual(request.url?.absoluteString, kind.defaultBaseURL + "/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + kind.rawValue + "-key")
        }
    }

    func testExplicitAPIFormatOverridesProviderDefault() async throws {
        var configuration = configuration(provider: .magpie, baseURL: ProviderKind.magpie.defaultBaseURL, model: "test-model")
        configuration.apiFormat = .responses
        let transport = MockTransport { request in
            (Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"result"}]}]}"#.utf8),
             Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(configuration: configuration, apiKey: "magpie", transport: transport)
        let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
        XCTAssertEqual(result.text, "result")
        let recorded = await transport.lastRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3425/v1/responses")
    }

    func testOpenCodeRoutesEachModelFamilyAndParsesOnlyOutputText() async throws {
        let cases = [
            ("gpt-5.4", "responses", "Authorization", "Bearer zen-key", #"{"status":"completed","output":[{"type":"reasoning","summary":[{"text":"private reasoning"}]},{"type":"message","content":[{"type":"output_text","text":"result"}]}]}"#),
            ("claude-sonnet-4-6", "messages", "x-api-key", "zen-key", #"{"content":[{"type":"text","text":"result"}],"stop_reason":"end_turn"}"#),
            ("qwen3.7-plus", "messages", "x-api-key", "zen-key", #"{"content":[{"type":"text","text":"result"}],"stop_reason":"end_turn"}"#),
            ("gemini-3.1-pro", "models/gemini-3.1-pro:generateContent", "x-goog-api-key", "zen-key", #"{"candidates":[{"content":{"parts":[{"text":"result"}]},"finishReason":"STOP"}]}"#),
            ("deepseek-v4-flash", "chat/completions", "Authorization", "Bearer zen-key", #"{"choices":[{"message":{"content":"result"},"finish_reason":"stop"}]}"#)
        ]
        for (model, path, header, key, json) in cases {
            let transport = MockTransport { request in (Data(json.utf8), Self.httpResponse(for: request, status: 200)) }
            let provider = HTTPRewriteProvider(configuration: configuration(provider: .openCode, baseURL: ProviderKind.openCode.defaultBaseURL, model: model), apiKey: "zen-key", transport: transport)
            let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
            XCTAssertEqual(result.text, "result")
            let recorded = await transport.lastRequest(); let request = try XCTUnwrap(recorded)
            XCTAssertEqual(request.url?.absoluteString, ProviderKind.openCode.defaultBaseURL + "/" + path)
            XCTAssertEqual(request.value(forHTTPHeaderField: header), key)
            let body = try jsonObject(request)
            if path == "responses" {
                XCTAssertEqual(body["input"] as? String, "input")
                XCTAssertEqual(body["instructions"] as? String, "prompt")
                XCTAssertEqual(body["store"] as? Bool, false)
            }
        }
    }

    func testOpenCodeIncompleteOrRefusalResponseCannotReplaceText() async {
        for json in [#"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#,
                     #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}"#] {
            let transport = MockTransport { request in (Data(json.utf8), Self.httpResponse(for: request, status: 200)) }
            let provider = HTTPRewriteProvider(configuration: configuration(provider: .openCode, baseURL: ProviderKind.openCode.defaultBaseURL, model: "gpt-5.4"), apiKey: "test", transport: transport)
            do { _ = try await provider.rewrite(.init(text: "input", prompt: "prompt")); XCTFail("Invalid response accepted") }
            catch { XCTAssertEqual(error as? SayoError, .invalidResponse) }
        }
    }

    func testOpenAICompatibleRequestAndResponse() async throws {
        let transport = MockTransport { request in
            let response = #"{"choices":[{"message":{"content":"Clear text"}}]}"#.data(using: .utf8)!
            return (response, Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(
                provider: .openAICompatible,
                baseURL: "https://api.example.com/v1/",
                model: "gpt-test"
            ),
            apiKey: "openai-secret",
            transport: transport
        )

        let result = try await provider.rewrite(.init(text: "rough text", prompt: "rewrite it"))

        XCTAssertEqual(result.text, "Clear text")
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 60)

        let body = try jsonObject(request)
        XCTAssertEqual(body["model"] as? String, "gpt-test")
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "rewrite it")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "rough text")
    }

    func testOpenAIParsesTextContentParts() async throws {
        let transport = MockTransport { request in
            let data = #"{"choices":[{"message":{"content":[{"type":"text","text":"one"},{"type":"text","text":" two"}]}}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let provider = makeProvider(provider: .openAICompatible, transport: transport)

        let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))

        XCTAssertEqual(result.text, "one two")
    }

    func testAnthropicRequestAndResponse() async throws {
        let transport = MockTransport { request in
            let data = #"{"content":[{"type":"text","text":"First"},{"type":"text","text":" second"}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(
                provider: .anthropic,
                baseURL: "https://api.anthropic.test",
                model: "claude-test"
            ),
            apiKey: "anthropic-secret",
            transport: transport
        )

        let result = try await provider.rewrite(.init(text: "draft", prompt: "polish"))

        XCTAssertEqual(result.text, "First second")
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.test/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try jsonObject(request)
        XCTAssertEqual(body["model"] as? String, "claude-test")
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["system"] as? String, "polish")
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "draft")
    }

    func testAnthropicBaseURLEndingInV1DoesNotDuplicateVersionPath() async throws {
        let transport = MockTransport { request in
            let data = #"{"content":[{"type":"text","text":"result"}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(
                provider: .anthropic,
                baseURL: "https://api.anthropic.com/v1/",
                model: "claude-test"
            ),
            apiKey: "anthropic-secret",
            transport: transport
        )

        _ = try await provider.rewrite(.init(text: "draft", prompt: "polish"))

        let recordedURL = await transport.lastRequest()?.url?.absoluteString
        XCTAssertEqual(recordedURL, "https://api.anthropic.com/v1/messages")
    }

    func testGeminiRequestAndResponse() async throws {
        let transport = MockTransport { request in
            let data = #"{"candidates":[{"content":{"parts":[{"text":"Gemini"},{"text":" result"}]}}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(
                provider: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                model: "models/gemini-test"
            ),
            apiKey: "gemini-secret",
            transport: transport
        )

        let result = try await provider.rewrite(.init(text: "source", prompt: "instruction"))

        XCTAssertEqual(result.text, "Gemini result")
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-secret")
        XCTAssertNil(request.url?.query)

        let body = try jsonObject(request)
        let system = try XCTUnwrap(body["systemInstruction"] as? [String: Any])
        XCTAssertNil(system["role"])
        let systemParts = try XCTUnwrap(system["parts"] as? [[String: Any]])
        XCTAssertEqual(systemParts.first?["text"] as? String, "instruction")
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "source")
        XCTAssertNil(body["generationConfig"])
    }

    func testTemperatureIsOmittedAcrossProviderPayloads() async throws {
        let providers: [(ProviderKind, String, Data)] = [
            (
                .openAICompatible,
                "https://api.example.com/v1",
                #"{"choices":[{"message":{"content":"result"}}]}"#.data(using: .utf8)!
            ),
            (
                .anthropic,
                "https://api.anthropic.com/v1",
                #"{"content":[{"type":"text","text":"result"}]}"#.data(using: .utf8)!
            ),
            (
                .gemini,
                "https://generativelanguage.googleapis.com/v1beta",
                #"{"candidates":[{"content":{"parts":[{"text":"result"}]}}]}"#.data(using: .utf8)!
            )
        ]

        for (providerKind, baseURL, responseData) in providers {
            let transport = MockTransport { request in
                (responseData, Self.httpResponse(for: request, status: 200))
            }
            let provider = HTTPRewriteProvider(
                configuration: configuration(
                    provider: providerKind,
                    baseURL: baseURL
                ),
                apiKey: "secret",
                transport: transport
            )

            _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))

            let maybeRequest = await transport.lastRequest()
            let recordedRequest = try XCTUnwrap(maybeRequest)
            let body = try jsonObject(recordedRequest)
            XCTAssertNil(body["temperature"])
            XCTAssertNil(body["generationConfig"])
        }
    }

    func testRejectsNonLoopbackHTTPBeforeTransport() async {
        let transport = MockTransport.failingIfCalled()
        let provider = HTTPRewriteProvider(
            configuration: configuration(baseURL: "http://api.example.com/v1"),
            apiKey: "secret",
            transport: transport
        )

        await assertNetworkError(from: provider, contains: "HTTPS")
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testWhitespaceInputNeverCallsTransport() async {
        let transport = MockTransport.failingIfCalled()
        let provider = HTTPRewriteProvider(
            configuration: configuration(),
            apiKey: "secret",
            transport: transport
        )

        do {
            _ = try await provider.rewrite(.init(text: "  \n\t", prompt: "rewrite"))
            XCTFail("Expected empty input to fail locally")
        } catch let error as SayoError {
            XCTAssertEqual(error, .emptyInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testAllowsLoopbackHTTP() async throws {
        let transport = MockTransport { request in
            let data = #"{"choices":[{"message":{"content":"local"}}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(baseURL: "http://127.0.0.1:11434/v1"),
            apiKey: "local-key",
            transport: transport
        )

        let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))

        XCTAssertEqual(result.text, "local")
        let recordedURL = await transport.lastRequest()?.url?.absoluteString
        XCTAssertEqual(recordedURL, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testAllowsIPv6LoopbackHTTP() async throws {
        let transport = MockTransport { request in
            let data = #"{"choices":[{"message":{"content":"local"}}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(baseURL: "http://[::1]:11434/v1"),
            apiKey: "local-key",
            transport: transport
        )

        let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))

        XCTAssertEqual(result.text, "local")
        let recordedURL = await transport.lastRequest()?.url?.absoluteString
        XCTAssertEqual(recordedURL, "http://[::1]:11434/v1/chat/completions")
    }

    func testLoopbackOpenAICompatibleProvidersMayOmitAPIKeyOverHTTPOrHTTPS() async throws {
        let baseURLs = [
            "http://localhost:11434/v1",
            "https://localhost:11434/v1"
        ]

        for providerKind in [ProviderKind.localModel, .openAICompatible, .custom] {
            for baseURL in baseURLs {
                let transport = MockTransport { request in
                    let data = #"{"choices":[{"message":{"content":"local"}}]}"#.data(using: .utf8)!
                    return (data, Self.httpResponse(for: request, status: 200))
                }
                let provider = HTTPRewriteProvider(
                    configuration: configuration(provider: providerKind, baseURL: baseURL),
                    apiKey: "   ",
                    transport: transport
                )

                let result = try await provider.rewrite(.init(text: "input", prompt: "prompt"))

                XCTAssertEqual(result.text, "local")
                let recordedRequest = await transport.lastRequest()
                XCTAssertNil(recordedRequest?.value(forHTTPHeaderField: "Authorization"))
            }
        }
    }

    func testRemoteProvidersRequireAPIKey() async {
        let configurations: [(ProviderKind, String)] = [
            (.localModel, "https://api.example.com/v1"),
            (.openAICompatible, "https://api.example.com/v1"),
            (.anthropic, "https://api.anthropic.com/v1"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta")
        ]

        for (providerKind, baseURL) in configurations {
            let transport = MockTransport.failingIfCalled()
            let provider = HTTPRewriteProvider(
                configuration: configuration(provider: providerKind, baseURL: baseURL),
                apiKey: "",
                transport: transport
            )

            do {
                _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
                XCTFail("Expected missing configuration for \(providerKind)")
            } catch let error as SayoError {
                XCTAssertEqual(error, .missingConfiguration)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            let requestCount = await transport.requestCount()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testRejectsBaseURLCredentialsQueryAndFragment() async {
        let invalidURLs = [
            "https://user:secret@example.com/v1",
            "https://example.com/v1?api_key=secret",
            "https://example.com/v1#fragment"
        ]

        for url in invalidURLs {
            let transport = MockTransport.failingIfCalled()
            let provider = HTTPRewriteProvider(
                configuration: configuration(baseURL: url),
                apiKey: "secret",
                transport: transport
            )
            await assertNetworkError(from: provider, contains: "base URL")
            let requestCount = await transport.requestCount()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testMissingModelAndAPIKeyAreConfigurationErrors() async {
        for (model, key) in [("", "secret"), ("model", "   ")] {
            let transport = MockTransport.failingIfCalled()
            let provider = HTTPRewriteProvider(
                configuration: configuration(model: model),
                apiKey: key,
                transport: transport
            )

            do {
                _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
                XCTFail("Expected missing configuration")
            } catch let error as SayoError {
                XCTAssertEqual(error, .missingConfiguration)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            let requestCount = await transport.requestCount()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testHTTPErrorIsActionableAndDoesNotExposeResponseOrSecrets() async {
        let apiKey = "super-secret-key"
        let userText = "private user content"
        let transport = MockTransport { request in
            let body = "server echoed \(apiKey) and \(userText)".data(using: .utf8)!
            return (body, Self.httpResponse(for: request, status: 401))
        }
        let provider = HTTPRewriteProvider(
            configuration: configuration(),
            apiKey: apiKey,
            transport: transport
        )

        do {
            _ = try await provider.rewrite(.init(text: userText, prompt: "prompt"))
            XCTFail("Expected authentication error")
        } catch let error as SayoError {
            guard case .network(let message) = error else {
                return XCTFail("Expected a network error")
            }
            XCTAssertTrue(message.contains("Authentication failed"))
            XCTAssertTrue(message.contains("401"))
            XCTAssertFalse(message.contains(apiKey))
            XCTAssertFalse(message.contains(userText))
            XCTAssertFalse(message.contains("server echoed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedAndWhitespaceResponsesAreInvalid() async {
        for responseBody in [Data("not-json".utf8), Data(#"{"choices":[{"message":{"content":"  \n"}}]}"#.utf8)] {
            let transport = MockTransport { request in
                (responseBody, Self.httpResponse(for: request, status: 200))
            }
            let provider = makeProvider(provider: .openAICompatible, transport: transport)

            do {
                _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
                XCTFail("Expected invalid response")
            } catch let error as SayoError {
                XCTAssertEqual(error, .invalidResponse)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTimeoutGetsSanitizedActionableError() async {
        let transport = MockTransport { _ in throw URLError(.timedOut) }
        let provider = makeProvider(provider: .openAICompatible, transport: transport)

        await assertNetworkError(from: provider, contains: "timed out")
    }

    func testTruncatedOrInterruptedTextCannotBecomeReplacement() async {
        let fixtures: [(ProviderKind, String)] = [
            (.openAICompatible, #"{"choices":[{"message":{"content":"partial sentence"},"finish_reason":"length"}]}"#),
            (.openAICompatible, #"{"choices":[{"message":{"content":"partial sentence"},"finish_reason":"content_filter"}]}"#),
            (.anthropic, #"{"content":[{"type":"text","text":"partial sentence"}],"stop_reason":"max_tokens"}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"partial sentence"}]},"finishReason":"MAX_TOKENS"}]}"#)
        ]
        for (kind, body) in fixtures {
            let transport = MockTransport { request in (Data(body.utf8), Self.httpResponse(for: request, status: 200)) }
            let provider = makeProvider(provider: kind, transport: transport)
            do {
                _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
                XCTFail("Incomplete response must not become a replacement")
            } catch { XCTAssertEqual(error as? SayoError, .invalidResponse) }
        }
    }

    func testCancellationIsPreserved() async {
        let transport = MockTransport { _ in throw CancellationError() }
        let provider = makeProvider(provider: .openAICompatible, transport: transport)

        do {
            _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertNetworkError(
        from provider: HTTPRewriteProvider,
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.rewrite(.init(text: "input", prompt: "prompt"))
            XCTFail("Expected network error", file: file, line: line)
        } catch let error as SayoError {
            guard case .network(let message) = error else {
                return XCTFail("Expected network error, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains(expectedText), file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private static func configuration(
        provider: ProviderKind = .openAICompatible,
        baseURL: String = "https://api.example.com/v1",
        model: String = "test-model"
    ) -> LLMConfiguration {
        var configuration = LLMConfiguration()
        configuration.provider = provider
        configuration.baseURL = baseURL
        configuration.model = model
        return configuration
    }

    private func configuration(
        provider: ProviderKind = .openAICompatible,
        baseURL: String = "https://api.example.com/v1",
        model: String = "test-model"
    ) -> LLMConfiguration {
        Self.configuration(
            provider: provider,
            baseURL: baseURL,
            model: model
        )
    }

    private func makeProvider(
        provider: ProviderKind,
        transport: any HTTPTransport
    ) -> HTTPRewriteProvider {
        HTTPRewriteProvider(
            configuration: configuration(provider: provider),
            apiKey: "secret",
            transport: transport
        )
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor MockTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try await handler(request)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }

    func requestCount() -> Int {
        requests.count
    }

    static func failingIfCalled() -> MockTransport {
        MockTransport { request in
            XCTFail("Transport should not be called for \(request.url?.absoluteString ?? "unknown URL")")
            throw URLError(.badURL)
        }
    }
}
