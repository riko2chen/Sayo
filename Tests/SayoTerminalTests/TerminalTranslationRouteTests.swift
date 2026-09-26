import XCTest
import SayoCore
@testable import SayoTerminal

final class TerminalTranslationRouteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func request(pid: Int32 = 42, createdAt: Date) -> TerminalRequest {
        TerminalRequest(text: "draft", selection: .init(location: 5, length: 0), applicationPID: pid, createdAt: createdAt)
    }

    func testSecondLanguageShortcutAppliesToOnlyItsNextTerminalRequest() {
        var route = TerminalTranslationRoute()
        let request = request(createdAt: now.addingTimeInterval(1))
        XCTAssertEqual(route.consume(for: request, now: now), .primary)
        route.arm(destination: .secondary, applicationPID: 42, now: now)
        XCTAssertEqual(route.consume(for: request, now: now.addingTimeInterval(1)), .secondary)
        XCTAssertEqual(route.consume(for: request, now: now.addingTimeInterval(2)), .primary)
    }

    func testUnrelatedAndOlderRequestsCannotConsumeTheShortcut() {
        var route = TerminalTranslationRoute()
        route.arm(destination: .secondary, applicationPID: 42, now: now)
        XCTAssertEqual(route.consume(for: request(pid: 43, createdAt: now), now: now), .primary)
        XCTAssertEqual(route.consume(for: request(createdAt: now.addingTimeInterval(-1)), now: now), .primary)
        XCTAssertEqual(route.consume(for: request(createdAt: now), now: now), .secondary)
    }

    func testFailedOrExpiredHandoffCannotAffectLaterRequest() {
        var route = TerminalTranslationRoute()
        let id = route.arm(destination: .secondary, applicationPID: 42, now: now)
        route.clear(id: id)
        XCTAssertEqual(route.consume(for: request(createdAt: now), now: now), .primary)
        route.arm(destination: .secondary, applicationPID: 42, now: now)
        let later = now.addingTimeInterval(11)
        XCTAssertEqual(route.consume(for: request(createdAt: later), now: later), .primary)
    }

    func testCancellationOfPreviousDispatchDoesNotClearNewRoute() {
        var route = TerminalTranslationRoute()
        let oldID = route.arm(destination: .primary, applicationPID: 42, now: now)
        route.arm(destination: .secondary, applicationPID: 42, now: now)
        route.clear(id: oldID)
        XCTAssertEqual(route.consume(for: request(createdAt: now), now: now), .secondary)
    }
}
