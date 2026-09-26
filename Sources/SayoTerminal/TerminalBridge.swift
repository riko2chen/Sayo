import Foundation

@MainActor
public final class TerminalBridge {
    public typealias Handler = @MainActor (TerminalRequest) async -> TerminalResponse

    private let store: BridgeFileStore
    private let pollInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var handler: Handler?

    public convenience init() throws {
        try self.init(directoryURL: nil)
    }

    init(directoryURL: URL?, pollInterval: Duration = .milliseconds(200)) throws {
        self.store = try BridgeFileStore(directoryURL: directoryURL)
        self.pollInterval = pollInterval
    }

    public func start(handler: @escaping Handler) {
        stop()
        self.handler = handler
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.scan()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        handler = nil
    }

    deinit {
        pollingTask?.cancel()
        for task in requestTasks.values { task.cancel() }
    }

    private func scan() {
        cancelAbandonedRequests()
        guard let ids = try? store.requestIDs() else { return }
        for id in ids where requestTasks[id] == nil {
            guard let claimedURL = try? store.claimRequest(id: id) else { continue }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.process(id: id, fileURL: claimedURL)
            }
            requestTasks[id] = task
        }
    }

    private func cancelAbandonedRequests() {
        for id in Array(requestTasks.keys) {
            guard let task = requestTasks[id] else { continue }
            if !store.processingFileExists(id: id) {
                task.cancel()
                requestTasks[id] = nil
            }
        }
    }

    private func process(id: UUID, fileURL: URL) async {
        defer {
            store.remove(fileURL)
            requestTasks[id] = nil
        }

        let request: TerminalRequest
        do {
            request = try store.readRequest(at: fileURL, expectedID: id)
        } catch {
            try? store.writeResponse(
                TerminalResponse(error: error.localizedDescription),
                id: id
            )
            return
        }

        guard !Task.isCancelled, let handler else { return }
        var response = await handler(request)
        do {
            try response.validate()
        } catch {
            response = TerminalResponse(error: error.localizedDescription)
        }
        if !Task.isCancelled {
            try? store.writeResponse(response, id: id)
        }
    }
}
