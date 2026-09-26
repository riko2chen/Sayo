import Foundation
import SayoCore
@testable import SayoTerminal
import XCTest

final class TerminalModelsTests: XCTestCase {
    func testRequestAndResponseCodableRoundTrip() throws {
        let request = TerminalRequest(
            id: UUID(uuidString: "A70C8E89-0B84-468F-B875-C2CE5A2B74B3")!,
            text: "echo 👋",
            selection: SayoCore.TextRange(location: 5, length: 2),
            applicationPID: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(TerminalRequest.self, from: requestData), request)

        let response = TerminalResponse(text: "printf 'hello'", error: nil)
        let responseData = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(TerminalResponse.self, from: responseData), response)
    }

    func testValidationRejectsStaleAndInvalidRequests() throws {
        let now = Date()
        let stale = TerminalRequest(
            text: "echo hi",
            selection: SayoCore.TextRange(location: 0, length: 0),
            applicationPID: 1,
            createdAt: now.addingTimeInterval(-31)
        )
        XCTAssertThrowsError(try stale.validate(now: now))

        let splitSurrogate = TerminalRequest(
            text: "👋",
            selection: SayoCore.TextRange(location: 1, length: 0),
            applicationPID: 1,
            createdAt: now
        )
        XCTAssertThrowsError(try splitSurrogate.validate(now: now))

        XCTAssertThrowsError(try TerminalResponse().validate())
        XCTAssertThrowsError(try TerminalResponse(text: "ok", error: "also an error").validate())
    }

    func testShellUnicodeScalarOffsetsConvertToUTF16() throws {
        let text = "e\u{301} 👨‍👩‍👧"
        XCTAssertEqual(text.count, 3, "The fixture must differ in grapheme and scalar counts")

        XCTAssertEqual(
            TerminalTextOffsets.utf16Range(in: text, start: 2, length: 1),
            SayoCore.TextRange(location: 2, length: 1)
        )
        XCTAssertEqual(
            TerminalTextOffsets.utf16Range(in: text, start: 3, length: 1),
            SayoCore.TextRange(location: 3, length: 2)
        )
        XCTAssertNil(TerminalTextOffsets.utf16Range(in: text, start: 20, length: 0))
    }

    func testReadlineByteOffsetsConvertAtEveryUnicodeScalarBoundary() {
        // A combining mark, CJK, a supplementary scalar, and a ZWJ sequence.
        let text = "e\u{301} 中👋👨‍👩‍👧\n"
        var expected: [Int: Int] = [0: 0]
        var bytes = 0
        var utf16 = 0
        for scalar in text.unicodeScalars {
            bytes += scalar.utf8.count
            utf16 += scalar.utf16.count
            expected[bytes] = utf16
        }
        for byteOffset in 0...text.utf8.count {
            let actual = TerminalTextOffsets.utf16Cursor(in: text, byteOffset: byteOffset)
            if let location = expected[byteOffset] {
                XCTAssertEqual(actual, SayoCore.TextRange(location: location, length: 0), "byte \(byteOffset)")
            } else {
                XCTAssertNil(actual, "Interior UTF-8 byte \(byteOffset) must be rejected")
            }
        }
        for offset in [-1, Int.min, text.utf8.count + 1, Int.max] {
            XCTAssertNil(TerminalTextOffsets.utf16Cursor(in: text, byteOffset: offset))
        }
        XCTAssertEqual(
            TerminalTextOffsets.utf16Cursor(in: "", byteOffset: 0),
            SayoCore.TextRange(location: 0, length: 0)
        )
    }
}
