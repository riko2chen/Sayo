import Foundation
import SayoCore

public struct HTTPRewriteProvider: RewriteProvider {
    private static let requestTimeout: TimeInterval = 60

    private let configuration: LLMConfiguration
    private let apiKey: String
    private let transport: any HTTPTransport

    public init(
        configuration: LLMConfiguration,
        apiKey: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        guard configuration.provider != .chromeNano else {
            throw SayoError.network("Gemini Nano requires the Chrome local connection.")
        }
        try Task.checkCancellation()
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SayoError.emptyInput
        }
        let urlRequest = try makeRequest(for: request)

        do {
            let (data, response) = try await transport.data(for: urlRequest)
            try Task.checkCancellation()

            guard (200..<300).contains(response.statusCode) else {
                throw Self.error(forHTTPStatus: response.statusCode)
            }

            let text = try parseResponse(data)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SayoError.invalidResponse
            }
            return RewriteResult(text: text)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SayoError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw Self.networkError(for: error.code)
        } catch {
            throw SayoError.network(
                "The language model request failed. Check your connection and provider settings."
            )
        }
    }

    private func makeRequest(for rewriteRequest: RewriteRequest) throws -> URLRequest {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw SayoError.missingConfiguration
        }

        let baseURL = try Self.validatedBaseURL(configuration.baseURL)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let permitsEmptyKey = [.localModel, .openAICompatible, .custom].contains(configuration.provider)
            && Self.isLoopback(baseURL.host ?? "")
        guard
            (permitsEmptyKey || !key.isEmpty),
            !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw SayoError.missingConfiguration
        }
        let endpoint: URL
        let body: Data
        var headers = ["Content-Type": "application/json"]

        switch configuration.resolvedAPIFormat {
        case .chatCompletions:
            endpoint = Self.appending(path: "chat/completions", to: baseURL)
            if !key.isEmpty {
                headers["Authorization"] = "Bearer \(key)"
            }
            body = try Self.encode(OpenAIRequest(
                model: model,
                messages: [
                    .init(role: "system", content: rewriteRequest.prompt),
                    .init(role: "user", content: rewriteRequest.text)
                ]
            ))

        case .responses:
            endpoint = Self.appending(path: "responses", to: baseURL)
            headers["Authorization"] = "Bearer \(key)"
            body = try Self.encode(ResponsesRequest(model: model, instructions: rewriteRequest.prompt,
                input: rewriteRequest.text))

        case .anthropic:
            endpoint = Self.anthropicMessagesEndpoint(for: baseURL)
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
            body = try Self.encode(AnthropicRequest(
                model: model,
                maxTokens: 4_096,
                system: rewriteRequest.prompt,
                messages: [.init(role: "user", content: rewriteRequest.text)]
            ))

        case .gemini:
            let geminiModel = Self.normalizedGeminiModel(model)
            guard !geminiModel.isEmpty else {
                throw SayoError.missingConfiguration
            }
            let encodedModel = Self.percentEncodedPathSegment(geminiModel)
            endpoint = Self.appending(
                percentEncodedPath: "models/\(encodedModel):generateContent",
                to: baseURL
            )
            headers["x-goog-api-key"] = key
            body = try Self.encode(GeminiRequest(
                systemInstruction: .init(
                    role: nil,
                    parts: [.init(text: rewriteRequest.prompt)]
                ),
                contents: [.init(
                    role: "user",
                    parts: [.init(text: rewriteRequest.text)]
                )]
            ))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func parseResponse(_ data: Data) throws -> String {
        do {
            switch configuration.resolvedAPIFormat {
            case .chatCompletions:
                let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                if let reason = response.choices.first?.finish_reason, reason != "stop" { throw SayoError.invalidResponse }
                guard let content = response.choices.first?.message.content.text else {
                    throw SayoError.invalidResponse
                }
                return content

            case .responses:
                let response = try JSONDecoder().decode(ResponsesResponse.self, from: data)
                guard response.status == "completed" else { throw SayoError.invalidResponse }
                let text = response.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
                    .filter { $0.type == "output_text" }.compactMap(\.text).joined()
                guard !text.isEmpty else { throw SayoError.invalidResponse }
                return text

            case .anthropic:
                let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                if let reason = response.stop_reason, reason != "end_turn" { throw SayoError.invalidResponse }
                let text = response.content.compactMap(\.text).joined()
                guard !text.isEmpty else { throw SayoError.invalidResponse }
                return text

            case .gemini:
                let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
                if let reason = response.candidates.first?.finishReason, reason != "STOP" { throw SayoError.invalidResponse }
                let text = response.candidates.first?.content.parts.compactMap(\.text).joined()
                guard let text else { throw SayoError.invalidResponse }
                return text
            }
        } catch let error as SayoError {
            throw error
        } catch {
            throw SayoError.invalidResponse
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw SayoError.network("The language model request could not be created.")
        }
    }

    private static func validatedBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            (scheme == "https" || (scheme == "http" && isLoopback(host))),
            let url = components.url
        else {
            throw SayoError.network(
                "The language model base URL is invalid. Use HTTPS; HTTP is allowed only for loopback addresses."
            )
        }
        return url
    }

    private static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { octet in
            guard let value = UInt8(octet) else { return false }
            return String(value) == octet || octet == "0"
        }
    }

    private static func appending(path: String, to baseURL: URL) -> URL {
        appending(percentEncodedPath: path, to: baseURL)
    }

    private static func anthropicMessagesEndpoint(for baseURL: URL) -> URL {
        let finalPathComponent = baseURL.path.split(separator: "/").last
        let path = finalPathComponent == "v1" ? "messages" : "v1/messages"
        return appending(path: path, to: baseURL)
    }

    private static func appending(percentEncodedPath path: String, to baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + path
        return components.url!
    }

    private static func normalizedGeminiModel(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    }

    private static func percentEncodedPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func error(forHTTPStatus status: Int) -> SayoError {
        switch status {
        case 401, 403:
            return .network("Authentication failed (HTTP \(status)). Check the API key and provider access.")
        case 404:
            return .network("The model endpoint was not found (HTTP 404). Check the base URL and model name.")
        case 408, 504:
            return .network("The language model request timed out (HTTP \(status)). Please try again.")
        case 429:
            return .network("The provider rate limit was reached (HTTP 429). Wait briefly and try again.")
        case 500...599:
            return .network("The language model provider is unavailable (HTTP \(status)). Please try again.")
        default:
            return .network(
                "The provider rejected the request (HTTP \(status)). Check the base URL, model, and provider settings."
            )
        }
    }

    private static func networkError(for code: URLError.Code) -> SayoError {
        switch code {
        case .timedOut:
            return .network("The language model request timed out. Please try again.")
        case .notConnectedToInternet:
            return .network("There is no internet connection. Connect to a network and try again.")
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .network("Could not connect to the language model provider. Check the base URL and connection.")
        case .networkConnectionLost:
            return .network("The network connection was lost. Please try again.")
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .network("A secure connection to the language model provider could not be established.")
        default:
            return .network("The language model request failed. Check your connection and provider settings.")
        }
    }
}

private struct OpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: TextContent
        }
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]
}

private enum TextContent: Decodable {
    struct Part: Decodable {
        let text: String?
    }

    case string(String)
    case parts([Part])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .parts(try container.decode([Part].self))
        }
    }

    var text: String? {
        switch self {
        case .string(let value): return value
        case .parts(let parts): return parts.compactMap(\.text).joined()
        }
    }
}

private struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicResponse: Decodable {
    struct Content: Decodable {
        let type: String?
        let text: String?
    }
    let content: [Content]
    let stop_reason: String?
}

private struct GeminiRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let role: String?
        let parts: [Part]
    }

    let systemInstruction: Content
    let contents: [Content]
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]
        }
        let content: Content
        let finishReason: String?
    }
    let candidates: [Candidate]
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store = false
}

private struct ResponsesResponse: Decodable {
    struct Item: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let type: String
        let content: [Content]?
    }
    let status: String
    let output: [Item]
}
