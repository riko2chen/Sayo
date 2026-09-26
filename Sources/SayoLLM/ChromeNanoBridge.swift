import Foundation
import Network
import SayoCore

/// A single authenticated, loopback-only connection to a user-opened Chrome page.
/// The app never enables debugging, reads browsing data, or downloads model weights.
@MainActor public final class ChromeNanoBridge {
    public static let shared = ChromeNanoBridge()
    private var listener: NWListener?
    private var listenerReady = false
    private var listenerError: Error?
    private var connections: [UUID: NWConnection] = [:]
    private var token = UUID().uuidString + UUID().uuidString
    private var lastPoll = Date.distantPast
    private var ready = false
    private var pending: Pending?
    private var timeout: Task<Void, Never>?
    private let requestTimeout: TimeInterval
    private let heartbeatTimeout: TimeInterval

    private struct Pending {
        let id: UUID
        let payload: Data
        let continuation: CheckedContinuation<RewriteResult, Error>
        var dispatched = false
    }

    public init(requestTimeout: TimeInterval = 90, heartbeatTimeout: TimeInterval = 8) {
        self.requestTimeout = requestTimeout
        self.heartbeatTimeout = heartbeatTimeout
    }

    public var isConnected: Bool { ready && Date().timeIntervalSince(lastPoll) < heartbeatTimeout }

    /// Called only by the explicit Connect button; invalidates any older bridge page.
    public func connectionURL(interfaceLanguage: InterfaceLanguage = .system) async throws -> URL {
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { @MainActor in self?.listenerReady = true }
                }
                if case .failed(let error) = state {
                    Task { @MainActor in self?.listenerError = error; self?.stop() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let error = listenerError { listenerError = nil; throw error }
            if listenerReady, let port = listener?.port, port.rawValue > 0 {
                finish(.failure(SayoError.network("Chrome connection restarted. Try again.")))
                token = UUID().uuidString + UUID().uuidString
                ready = false
                let language = interfaceLanguage.resolved == .simplifiedChinese ? "zh-CN" : "en"
                return URL(string: "http://127.0.0.1:\(port.rawValue)/#token=\(token)&lang=\(language)")!
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop()
        throw SayoError.network("Could not start the Chrome local connection.")
    }

    public func stop() {
        listener?.cancel(); listener = nil
        listenerReady = false
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        ready = false
        finish(.failure(SayoError.network("Chrome local connection closed.")))
    }

    public func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        try Task.checkCancellation()
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SayoError.emptyInput }
        guard request.text.utf8.count + request.prompt.utf8.count <= 64_000 else { throw SayoError.inputTooLong }
        guard isConnected else {
            throw SayoError.network("Connect Gemini Nano in Settings → Language Model, then keep its Chrome tab open. / 请在模型设置中连接，并保留 Chrome 标签页。")
        }
        guard pending == nil else { throw SayoError.network("Gemini Nano is busy. Try again when the current request finishes.") }
        let id = UUID()
        // Preserve the source and configured prompt, including experimental languages.
        // Chrome's optional language declarations can reject them before inference.
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "text": request.text, "prompt": request.prompt
        ])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, payload: payload, continuation: continuation)
                timeout = Task { [weak self] in
                    let started = Date()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        guard let self, self.pending?.id == id else { return }
                        if !self.isConnected || Date().timeIntervalSince(started) >= self.requestTimeout {
                            self.finish(.failure(SayoError.network("Gemini Nano timed out or its Chrome tab disconnected. Reconnect and try again.")))
                            return
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.id == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<RewriteResult, Error>) {
        let current = pending
        pending = nil
        timeout?.cancel(); timeout = nil
        current?.continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let buffer = buffer + (data ?? Data())
                do {
                    if let request = try NanoHTTPRequest.parse(buffer) {
                        let response = self.handle(request)
                        self.send(response, on: connection, id: id)
                    } else if complete || error != nil {
                        self.connections.removeValue(forKey: id)?.cancel()
                    } else {
                        self.receive(connection, id: id, buffer: buffer)
                    }
                } catch {
                    self.send((400, "text/plain", Data("Invalid request".utf8)), on: connection, id: id)
                }
            }
        }
    }

    private typealias Response = (Int, String, Data)

    private func handle(_ request: NanoHTTPRequest) -> Response {
        guard let port = listener?.port else { return (503, "text/plain", Data()) }
        let host = "127.0.0.1:\(port.rawValue)"
        guard request.headers["host"] == host,
              request.headers["origin"].map({ $0 == "http://\(host)" }) ?? true else {
            return (403, "text/plain", Data())
        }
        if request.method == "GET", request.path == "/" || request.path == "/bridge.js" {
            let ext = request.path == "/" ? "html" : "js"
            guard let url = Bundle.module.url(forResource: "bridge", withExtension: ext, subdirectory: "Resources"),
                  let data = try? Data(contentsOf: url) else { return (500, "text/plain", Data()) }
            return (200, ext == "html" ? "text/html; charset=utf-8" : "text/javascript; charset=utf-8", data)
        }
        guard request.headers["authorization"] == "Bearer \(token)" else { return (403, "text/plain", Data()) }
        if request.method == "POST", request.path == "/poll",
           let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let available = object["ready"] as? Bool {
            ready = available
            lastPoll = Date()
            let activeID = pending?.id.uuidString
            var job: Any = NSNull()
            if available, let current = pending, !current.dispatched {
                job = (try? JSONSerialization.jsonObject(with: current.payload)) ?? NSNull()
                pending?.dispatched = true
            }
            let data = (try? JSONSerialization.data(withJSONObject: ["job": job, "activeID": activeID as Any? ?? NSNull()])) ?? Data()
            return (200, "application/json", data)
        }
        if request.method == "POST", request.path == "/result",
           let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let id = object["id"] as? String, id == pending?.id.uuidString {
            if let code = object["error"] as? String {
                // Do not surface arbitrary browser error text (which can contain source input).
                let message: String
                switch code {
                case "unsupported": message = "Chrome could not run this request with the current model. Try another passage or model. / Chrome 当前模型无法执行此请求，请尝试其他文本或模型。"
                case "too-long": message = "This passage exceeds Gemini Nano's context window. Select a shorter passage."
                case "unavailable": message = "Gemini Nano is unavailable. Reconnect from model settings and check Chrome's on-device-internals page."
                default: message = "Gemini Nano could not complete this request. Check the Chrome connection and try again."
                }
                finish(.failure(SayoError.network(message)))
            } else if let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finish(.success(RewriteResult(text: text)))
            } else { finish(.failure(SayoError.invalidResponse)) }
            return (200, "application/json", Data("{}".utf8))
        }
        return (404, "text/plain", Data())
    }

    private func send(_ response: Response, on connection: NWConnection, id: UUID) {
        let (status, type, body) = response
        let headers = "HTTP/1.1 \(status) Response\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.connections.removeValue(forKey: id)?.cancel() }
        })
    }
}

struct NanoHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 131_072 else { throw SayoError.invalidResponse }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw SayoError.invalidResponse }
            return nil
        }
        guard separator.lowerBound <= 16_384,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw SayoError.invalidResponse }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw SayoError.invalidResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw SayoError.invalidResponse }
            let name = String(line[..<colon]).lowercased()
            guard headers[name] == nil else { throw SayoError.invalidResponse }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...114_688).contains(length) else { throw SayoError.invalidResponse }
        let body = data[separator.upperBound...]
        guard body.count <= length else { throw SayoError.invalidResponse }
        guard body.count == length else { return nil }
        return Self(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))
    }
}
