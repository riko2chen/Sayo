import XCTest
import SayoCore
@testable import SayoUI

final class StatusIconPreviewTests: XCTestCase {
    func testSelectingAnotherStyleStartsTheMatchingTransition() {
        var state = StatusIconPreviewState(initialStyle: .brand)

        XCTAssertEqual(state.select(.monochrome), .brandToMonochrome)
        XCTAssertEqual(state.activeTransition, .brandToMonochrome)
        XCTAssertEqual(state.displayedStyle, .brand)
    }

    func testSelectionsDuringPlaybackAreCoalescedToTheLatestStyle() {
        var state = StatusIconPreviewState(initialStyle: .brand)

        XCTAssertEqual(state.select(.monochrome), .brandToMonochrome)
        XCTAssertNil(state.select(.brand))
        XCTAssertEqual(state.finishPlayback(), .monochromeToBrand)
        XCTAssertEqual(state.displayedStyle, .monochrome)
        XCTAssertEqual(state.activeTransition, .monochromeToBrand)
    }

    func testNoFollowUpPlaybackWhenLatestSelectionMatchesCompletedDestination() {
        var state = StatusIconPreviewState(initialStyle: .brand)

        XCTAssertEqual(state.select(.monochrome), .brandToMonochrome)
        XCTAssertNil(state.select(.brand))
        XCTAssertNil(state.select(.monochrome))
        XCTAssertNil(state.finishPlayback())
        XCTAssertEqual(state.displayedStyle, .monochrome)
        XCTAssertNil(state.activeTransition)
    }
}
