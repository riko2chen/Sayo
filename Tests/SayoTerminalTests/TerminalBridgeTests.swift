import Foundation
import SayoCore
@testable import SayoTerminal
import XCTest

final class TerminalBridgeTests: XCTestCase {
    @MainActor
    func testBridgeCallsHandlerOnceAndReturnsWholeBuffer() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try TerminalBridge(directoryURL: directory, pollInterval: .milliseconds(10))
        let client = try TerminalBridgeClient(directoryURL: directory, pollNanoseconds: 5_000_000)
        var calls = 0
        bridge.start { request in
            calls += 1
            XCTAssertEqual(request.text, "git statsu")
            return TerminalResponse(text: "git status")
        }

        let request = TerminalRequest(
            text: "git statsu",
            selection: SayoCore.TextRange(location: 10, length: 0),
            applicationPID: 12
        )
        let result = try await client.rewrite(request, timeout: 2)
        XCTAssertEqual(result, "git status")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, 1)
        bridge.stop()
    }

    @MainActor
    func testStaleRequestReturnsErrorWithoutCallingHandler() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeFileStore(directoryURL: directory)
        let bridge = try TerminalBridge(directoryURL: directory, pollInterval: .milliseconds(10))
        var calls = 0
        bridge.start { _ in
            calls += 1
            return TerminalResponse(text: "unexpected")
        }

        let stale = TerminalRequest(
            text: "echo old",
            selection: SayoCore.TextRange(location: 8, length: 0),
            applicationPID: 12,
            createdAt: Date().addingTimeInterval(-60)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stale)
        let requestURL = store.requestURL(for: stale.id)
        try data.write(to: requestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var response: TerminalResponse?
        while ContinuousClock.now < deadline, response == nil {
            response = try store.readResponse(id: stale.id)
            if response == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertNotNil(response?.error)
        XCTAssertEqual(calls, 0)
        bridge.stop()
    }

    func testStoreCreatesPrivateDirectoryAndFiles() throws {
        let directory = temporaryDirectory()
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeFileStore(directoryURL: directory)
        let request = TerminalRequest(
            text: "echo safe",
            selection: SayoCore.TextRange(location: 9, length: 0),
            applicationPID: 12
        )
        try store.writeRequest(request)

        let directoryMode = try permissions(at: directory)
        let fileMode = try permissions(at: store.requestURL(for: request.id))
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    @MainActor
    func testClientTimeoutCancelsInFlightHandlerAndCleansFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try TerminalBridge(directoryURL: directory, pollInterval: .milliseconds(5))
        let client = try TerminalBridgeClient(directoryURL: directory, pollNanoseconds: 2_000_000)
        let cancelled = expectation(description: "handler cancelled")
        bridge.start { _ in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                if Task.isCancelled { cancelled.fulfill() }
            }
            return TerminalResponse(text: "too late")
        }
        let request = TerminalRequest(
            text: "echo waiting",
            selection: SayoCore.TextRange(location: 12, length: 0),
            applicationPID: 12
        )

        do {
            _ = try await client.rewrite(request, timeout: 0.05)
            XCTFail("Expected the client to time out")
        } catch {
            XCTAssertEqual(error as? TerminalBridgeError, .timeout)
        }
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("processing-\(request.id.uuidString.lowercased()).json").path))
        bridge.stop()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
