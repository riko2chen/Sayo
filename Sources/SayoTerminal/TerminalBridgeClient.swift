import Foundation

public struct TerminalBridgeClient: Sendable {
    private let store: BridgeFileStore
    private let pollNanoseconds: UInt64

    public init() throws {
        try self.init(directoryURL: nil)
    }

    init(directoryURL: URL?, pollNanoseconds: UInt64 = 50_000_000) throws {
        self.store = try BridgeFileStore(directoryURL: directoryURL)
        self.pollNanoseconds = pollNanoseconds
    }

    public func rewrite(_ request: TerminalRequest, timeout: TimeInterval = 120) async throws -> String {
        guard timeout > 0, timeout <= 300 else {
            throw TerminalBridgeError.invalidRequest("The terminal timeout must be greater than 0 and at most 300 seconds.")
        }
        try store.writeRequest(request)
        defer { store.removeFiles(id: request.id) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if let response = try store.readResponse(id: request.id) {
                if let text = response.text { return text }
                throw TerminalBridgeError.invalidResponse(response.error ?? "Sayo could not rewrite the command.")
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        throw TerminalBridgeError.timeout
    }
}
