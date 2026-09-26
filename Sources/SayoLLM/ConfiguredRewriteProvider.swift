import SayoCore

/// Routes every app entry point, including connection tests and diagnostics.
public struct ConfiguredRewriteProvider: RewriteProvider {
    private let configuration: LLMConfiguration
    private let apiKey: String

    public init(configuration: LLMConfiguration, apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        if configuration.provider == .chromeNano {
            return try await ChromeNanoBridge.shared.rewrite(request)
        }
        return try await HTTPRewriteProvider(configuration: configuration, apiKey: apiKey).rewrite(request)
    }
}
