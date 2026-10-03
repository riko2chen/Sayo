import XCTest
@testable import SayoPlatform

final class TerminalDetectorTests: XCTestCase {
    func testOttyUsesTerminalRouting() {
        XCTAssertTrue(TerminalDetector.isTerminal("io.appmakes.otty"))
    }

    func testOrdinaryEditorsDoNotUseTerminalRouting() {
        XCTAssertFalse(TerminalDetector.isTerminal("com.apple.TextEdit"))
        XCTAssertFalse(TerminalDetector.isTerminal(nil))
    }
}
