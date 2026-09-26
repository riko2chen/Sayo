import Darwin
import Foundation

struct BridgeFileStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL? = nil) throws {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directoryURL = support
                .appendingPathComponent("Sayo", isDirectory: true)
                .appendingPathComponent("Bridge", isDirectory: true)
        }
        try Self.preparePrivateDirectory(self.directoryURL)
    }

    func requestURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("request-\(id.uuidString.lowercased()).json")
    }

    func processingURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("processing-\(id.uuidString.lowercased()).json")
    }

    func responseURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("response-\(id.uuidString.lowercased()).json")
    }

    func requestIDs() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            Self.identifier(in: url.lastPathComponent, prefix: "request-")
        }
    }

    func claimRequest(id: UUID) throws -> URL? {
        let source = requestURL(for: id)
        let destination = processingURL(for: id)
        guard rename(source.path, destination.path) == 0 else {
            if errno == ENOENT { return nil }
            throw TerminalBridgeError.io("Could not claim the terminal request.")
        }
        return destination
    }

    func writeRequest(_ request: TerminalRequest) throws {
        try request.validate()
        let data = try Self.encoder.encode(request)
        guard data.count <= TerminalBridgeLimits.maximumFileBytes else {
            throw TerminalBridgeError.invalidRequest("The terminal request is too large.")
        }
        try writeAtomically(data, to: requestURL(for: request.id))
    }

    func readRequest(at url: URL, expectedID: UUID) throws -> TerminalRequest {
        let data = try readPrivateFile(at: url)
        let request: TerminalRequest
        do {
            request = try Self.decoder.decode(TerminalRequest.self, from: data)
        } catch {
            throw TerminalBridgeError.invalidRequest("The terminal request is not valid JSON.")
        }
        guard request.id == expectedID else {
            throw TerminalBridgeError.invalidRequest("The terminal request identifier does not match its file.")
        }
        try request.validate()
        return request
    }

    func writeResponse(_ response: TerminalResponse, id: UUID) throws {
        try response.validate()
        let data = try Self.encoder.encode(response)
        guard data.count <= TerminalBridgeLimits.maximumFileBytes else {
            throw TerminalBridgeError.invalidResponse("The terminal response is too large.")
        }
        try writeAtomically(data, to: responseURL(for: id))
    }

    func readResponse(id: UUID) throws -> TerminalResponse? {
        let url = responseURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readPrivateFile(at: url)
        let response: TerminalResponse
        do {
            response = try Self.decoder.decode(TerminalResponse.self, from: data)
        } catch {
            throw TerminalBridgeError.invalidResponse("Sayo returned malformed terminal data.")
        }
        try response.validate()
        return response
    }

    func removeFiles(id: UUID) {
        for url in [requestURL(for: id), processingURL(for: id), responseURL(for: id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func processingFileExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: processingURL(for: id).path)
    }

    private func readPrivateFile(at url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw TerminalBridgeError.io("Could not read terminal bridge data.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              info.st_size >= 0,
              info.st_size <= TerminalBridgeLimits.maximumFileBytes else {
            throw TerminalBridgeError.io("Terminal bridge data failed its security checks.")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw TerminalBridgeError.io("Could not create terminal bridge data.")
        }

        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { try? FileManager.default.removeItem(at: temporary) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), remaining)
                guard count > 0 else {
                    throw TerminalBridgeError.io("Could not write terminal bridge data.")
                }
                remaining -= count
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, destination.path) == 0 else {
            throw TerminalBridgeError.io("Could not publish terminal bridge data.")
        }
        succeeded = true
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TerminalBridgeError.io("The terminal bridge path is not a directory.")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw TerminalBridgeError.io("The terminal bridge directory failed its security checks.")
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw TerminalBridgeError.io("Could not secure the terminal bridge directory.")
        }
    }

    private static func identifier(in filename: String, prefix: String) -> UUID? {
        guard filename.hasPrefix(prefix), filename.hasSuffix(".json") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -5)
        return UUID(uuidString: String(filename[start..<end]))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
