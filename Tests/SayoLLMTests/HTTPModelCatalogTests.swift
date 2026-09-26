import Foundation
import XCTest
import SayoCore
@testable import SayoLLM

final class HTTPModelCatalogTests: XCTestCase {
    func testPlatformPresetsUseOpenAIModelListIncludingOpenCodeNativeModels() async throws {
        for kind in [ProviderKind.deepSeek, .internAI, .qwen, .moonshot, .zhipu, .doubao, .siliconFlow, .openRouter, .openCode, .magpie] {
            let transport = CatalogMockTransport { request in
                (Data(#"{"data":[{"id":"claude-sonnet-4-6"},{"id":"gpt-5.4"}]}"#.utf8), Self.httpResponse(for: request, status: 200))
            }
            let catalog = HTTPModelCatalog(configuration: Self.configuration(provider: kind, baseURL: kind.defaultBaseURL), apiKey: "platform-key", transport: transport)
            let models = try await catalog.models()
            XCTAssertEqual(models, ["claude-sonnet-4-6", "gpt-5.4"])
            let request = await transport.lastRequest()
            XCTAssertEqual(request?.url?.absoluteString, kind.defaultBaseURL + "/models")
            XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer platform-key")
        }
    }

    func testOpenAICompatibleLoadsSortsAndDeduplicatesModels() async throws {
        let transport = CatalogMockTransport { request in
            let data = #"{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"a-model"}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let catalog = HTTPModelCatalog(
            configuration: Self.configuration(
                provider: .openAICompatible,
                baseURL: "https://api.example.com/v1/"
            ),
            apiKey: "openai-secret",
            transport: transport
        )

        let models = try await catalog.models()

        XCTAssertEqual(models, ["a-model", "z-model"])
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
    }

    func testAnthropicLoadsModelsFromV1Endpoint() async throws {
        let transport = CatalogMockTransport { request in
            let data = #"{"data":[{"id":"claude-sonnet"},{"id":"claude-opus"}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let catalog = HTTPModelCatalog(
            configuration: Self.configuration(provider: .anthropic, baseURL: "https://api.anthropic.com/v1"),
            apiKey: "anthropic-secret",
            transport: transport
        )

        _ = try await catalog.models()

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testGeminiOnlyShowsGenerateContentModels() async throws {
        let transport = CatalogMockTransport { request in
            let data = #"{"models":[{"name":"models/gemini-pro","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}]}"#.data(using: .utf8)!
            return (data, Self.httpResponse(for: request, status: 200))
        }
        let catalog = HTTPModelCatalog(
            configuration: Self.configuration(
                provider: .gemini,
                baseURL: "https://generativelanguage.googleapis.com/v1beta"
            ),
            apiKey: "gemini-secret",
            transport: transport
        )

        let models = try await catalog.models()

        XCTAssertEqual(models, ["models/gemini-pro"])
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-secret")
    }

    func testLoopbackOpenAICompatibleProvidersCanLoadModelsWithoutKey() async throws {
        for providerKind in [ProviderKind.localModel, .openAICompatible, .custom] {
            let transport = CatalogMockTransport { request in
                let data = #"{"data":[{"id":"local-model"}]}"#.data(using: .utf8)!
                return (data, Self.httpResponse(for: request, status: 200))
            }
            let catalog = HTTPModelCatalog(
                configuration: Self.configuration(
                    provider: providerKind,
                    baseURL: "http://127.0.0.1:11434/v1"
                ),
                apiKey: "",
                transport: transport
            )

            let models = try await catalog.models()
            XCTAssertEqual(models, ["local-model"])
            let request = await transport.lastRequest()
            XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        }
    }

    private static func configuration(provider: ProviderKind, baseURL: String) -> LLMConfiguration {
        var configuration = LLMConfiguration()
        configuration.provider = provider
        configuration.baseURL = baseURL
        return configuration
    }

    private static func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor CatalogMockTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let handler: Handler
    private var requests: [URLRequest] = []

    init(handler: @escaping Handler) { self.handler = handler }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try await handler(request)
    }

    func lastRequest() -> URLRequest? { requests.last }
}
