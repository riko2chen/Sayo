import XCTest
@testable import SayoCore

final class CLIShortcutTests: XCTestCase {
    func testPortableKeysRoundTripAndDisplay() throws {
        for key in ["ctrl+g", "ctrl+e", "alt+g", "f1", "f6", "f12"] {
            let shortcut = try XCTUnwrap(CLIShortcut.shortcut(for: key))
            XCTAssertEqual(CLIShortcut.key(for: shortcut), key)
        }
        XCTAssertEqual(CLIShortcut.label("ctrl+g"), "⌃G")
        XCTAssertEqual(CLIShortcut.label("f6"), "F6")
    }
    func testRecorderRejectsUnsupportedModifiersBareLettersAndReservedKeys() {
        for shortcut in [
            Shortcut(keyCode: 5, command: true, shift: false),
            Shortcut(keyCode: 5, command: false, control: true, shift: true),
            Shortcut(keyCode: 5, command: false, option: true, control: true, shift: false),
            Shortcut(keyCode: 5, command: false, shift: false),
            Shortcut(keyCode: 8, command: false, control: true, shift: false),
            Shortcut(keyCode: 97, command: false, control: true, shift: false)
        ] { XCTAssertNil(CLIShortcut.key(for: shortcut)) }
        XCTAssertNil(CLIShortcut.shortcut(for: "ctrl+c"))
        XCTAssertNil(CLIShortcut.shortcut(for: "f13"))
    }
    func testDefaultIsASelectableCodexOption() {
        XCTAssertEqual(CLIShortcut.defaultKey, "ctrl+g")
        XCTAssertEqual(CLIShortcut.codexOptions.first, CLIShortcut.defaultKey)
        XCTAssertEqual(CLIShortcut.codexOptions.count, 8)
        XCTAssertFalse(CLIShortcut.codexOptions.contains("ctrl+e"))
    }
}
