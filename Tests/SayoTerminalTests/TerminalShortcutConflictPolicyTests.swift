import XCTest
import SayoCore
@testable import SayoTerminal

final class TerminalShortcutConflictPolicyTests: XCTestCase {
    func testOptionECanBeTheUnifiedGlobalEntryPoint() throws {
        XCTAssertNoThrow(try TerminalShortcutConflictPolicy.validateGlobalShortcuts(
            [.optionE],
            shellIntegrationInstalled: true,
            cliShortcuts: [.agy: "ctrl+g", .codex: "ctrl+g", .claude: "ctrl+g"]
        ))
    }

    func testInstalledShellReservesBothRelayKeys() {
        for key in ["ctrl+x", "ctrl+r"] {
            let shortcut = try! XCTUnwrap(CLIShortcut.shortcut(for: key))
            XCTAssertThrowsError(try TerminalShortcutConflictPolicy.validateGlobalShortcuts(
                [shortcut], shellIntegrationInstalled: true, cliShortcuts: [:]
            )) { error in
                XCTAssertEqual(error as? TerminalShortcutConflict, .shell(key: key))
            }
        }
    }

    func testCLIInternalKeyCannotAlsoBeGlobal() throws {
        let shortcut = try XCTUnwrap(CLIShortcut.shortcut(for: "ctrl+g"))
        XCTAssertThrowsError(try TerminalShortcutConflictPolicy.validateGlobalShortcuts(
            [shortcut], shellIntegrationInstalled: false, cliShortcuts: [.codex: "ctrl+g"]
        )) { error in
            XCTAssertEqual(error as? TerminalShortcutConflict, .cli(program: .codex, key: "ctrl+g"))
        }
    }

    func testCLISettingChecksEveryStoredGlobalShortcut() throws {
        let shortcut = try XCTUnwrap(CLIShortcut.shortcut(for: "f6"))
        XCTAssertThrowsError(try TerminalShortcutConflictPolicy.validateCLIShortcut(
            "f6", program: .claude, globalShortcuts: [.optionE, shortcut]
        )) { error in
            XCTAssertEqual(error as? TerminalShortcutConflict, .sayo(program: .claude, key: "f6"))
        }
    }

    func testInactiveIntegrationsDoNotReserveTheirKeys() throws {
        let shortcut = try XCTUnwrap(CLIShortcut.shortcut(for: "ctrl+g"))
        XCTAssertNoThrow(try TerminalShortcutConflictPolicy.validateGlobalShortcuts(
            [shortcut], shellIntegrationInstalled: false, cliShortcuts: [:]
        ))
    }
}
