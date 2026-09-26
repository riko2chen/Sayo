import Foundation
import SayoCore

public struct HTTPModelCatalog: Sendable {
    private static let requestTimeout: TimeInterval = 30

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

    public func models() async throws -> [String] {
        try Task.checkCancellation()
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
        var headers = ["Accept": "application/json"]
        guard configuration.provider != .chromeNano else {
            throw SayoError.network("Gemini Nano is managed by Chrome; connect from its model settings.")
        }
        switch configuration.resolvedAPIFormat {
        case .chatCompletions, .responses:
            endpoint = Self.appending(path: "models", to: baseURL)
            if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }

        case .anthropic:
            endpoint = Self.anthropicModelsEndpoint(for: baseURL)
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"

        case .gemini:
            endpoint = Self.appending(path: "models", to: baseURL)
            headers["x-goog-api-key"] = key
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                throw Self.error(forHTTPStatus: response.statusCode)
            }
            let result = try parse(data)
            guard !result.isEmpty else {
                throw SayoError.network("The provider returned an empty model list.")
            }
            return Array(Set(result)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SayoError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw Self.networkError(for: error.code)
        } catch {
            throw SayoError.network("The provider returned an invalid model list.")
        }
    }

    private func parse(_ data: Data) throws -> [String] {
        guard configuration.provider != .chromeNano else {
            throw SayoError.invalidResponse
        }
        switch configuration.resolvedAPIFormat {
        case .chatCompletions, .responses, .anthropic:
            return try JSONDecoder().decode(ModelListResponse.self, from: data).data
                .map(\.id)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        case .gemini:
            return try JSONDecoder().decode(GeminiModelListResponse.self, from: data).models
                .filter { model in
                    model.supportedGenerationMethods?.contains("generateContent") ?? true
                }
                .map(\.name)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { octet in
            guard let value = UInt8(octet) else { return false }
            return String(value) == octet || octet == "0"
        }
    }

    private static func appending(path: String, to baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + path
        return components.url!
    }

    private static func anthropicModelsEndpoint(for baseURL: URL) -> URL {
        let finalPathComponent = baseURL.path.split(separator: "/").last
        return appending(path: finalPathComponent == "v1" ? "models" : "v1/models", to: baseURL)
    }

    private static func error(forHTTPStatus status: Int) -> SayoError {
        switch status {
        case 401, 403:
            return .network("Authentication failed (HTTP \(status)). Check the API key and provider access.")
        case 404:
            return .network("The model list endpoint was not found (HTTP 404). Check the base URL.")
        case 408, 504:
            return .network("Loading models timed out (HTTP \(status)). Please try again.")
        case 429:
            return .network("The provider rate limit was reached (HTTP 429). Wait briefly and try again.")
        case 500...599:
            return .network("The language model provider is unavailable (HTTP \(status)). Please try again.")
        default:
            return .network("The provider rejected the model list request (HTTP \(status)).")
        }
    }

    private static func networkError(for code: URLError.Code) -> SayoError {
        switch code {
        case .timedOut:
            return .network("Loading models timed out. Please try again.")
        case .notConnectedToInternet:
            return .network("There is no internet connection. Connect to a network and try again.")
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return .network("Could not connect to the language model provider. Check the base URL and connection.")
        case .networkConnectionLost:
            return .network("The network connection was lost. Please try again.")
        default:
            return .network("Could not load models from the language model provider.")
        }
    }
}

private struct ModelListResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private struct GeminiModelListResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }
    let models: [Model]
}
