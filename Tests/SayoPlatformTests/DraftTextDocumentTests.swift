import XCTest
import SayoCore
@testable import SayoPlatform

final class DraftTextDocumentTests: XCTestCase {
    func testEmptyParagraphsAndLiteralLineBreaksRemainDistinct() throws {
        let document = ParagraphText(paragraphs: ["Before marker.", "", "我很喜欢这个功能。", "After marker."])
        XCTAssertEqual(document.text, "Before marker.\n\n我很喜欢这个功能。\nAfter marker.")
        let start = try document.offset(paragraph: 2, localOffset: 0)
        let end = try document.offset(paragraph: 2, localOffset: 9)
        let snapshot = try TextContext(id: "draft", text: document.text, selection: .init(location: start, length: end - start)).snapshot()
        XCTAssertEqual(snapshot.source, "我很喜欢这个功能。")
        XCTAssertEqual(snapshot.replacing(with: "I like this feature."), "Before marker.\n\nI like this feature.\nAfter marker.")
        XCTAssertEqual(ParagraphText(paragraphs: ["", "a\nb", "", ""]).text, "\na\nb\n\n")
    }

    func testAdjacentParagraphBoundaryPositionsDoNotCollapseTogether() throws {
        let document = ParagraphText(paragraphs: ["First", "Second"])
        XCTAssertEqual(try document.offset(paragraph: 0, localOffset: 5), 5)
        XCTAssertEqual(try document.offset(paragraph: 1, localOffset: 0), 6)
    }

    func testWholeFieldAndEmojiSelectionUseCanonicalUTF16Offsets() throws {
        let document = ParagraphText(paragraphs: ["👋", "", "中文!"])
        let caret = try document.offset(paragraph: 2, localOffset: 3)
        let snapshot = try TextContext(id: "draft", text: document.text, selection: .init(location: caret, length: 0)).snapshot()
        XCTAssertEqual(snapshot.source, "👋\n\n中文!")
        XCTAssertEqual(snapshot.replacing(with: "Hello\n\nText!"), "Hello\n\nText!")
        XCTAssertThrowsError(try document.offset(paragraph: 0, localOffset: 1))
        XCTAssertThrowsError(try document.offset(paragraph: 3, localOffset: 0))
        XCTAssertThrowsError(try document.offset(paragraph: 2, localOffset: 4))
    }
}
