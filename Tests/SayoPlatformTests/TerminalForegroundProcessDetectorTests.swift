import XCTest
import SayoCore
@testable import SayoPlatform

final class TerminalForegroundProcessDetectorTests: XCTestCase {
    func testDiagnosticEvidenceExplainsTitleTTYAndAmbiguousRoutesWithoutText() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Otty /Applications/Otty.app/Contents/MacOS/Otty
          101   100   101   201 ttys000  zsh -zsh
          201   101   201   201 ttys000  claude /usr/local/bin/claude private-argument
          102   100   102   301 ttys001  zsh -zsh
          301   102   301   301 ttys001  codex /usr/local/bin/codex
        """)
        let titled = TerminalForegroundProcessDetector.detectWithDiagnostics(records: records, terminalPID: 100,
            focusedTTY: nil, focusedText: "private text", focusedTitle: "Claude Code private-title")
        XCTAssertEqual(titled.route, .cli(.init(program: .claude, tty: "ttys000")))
        XCTAssertEqual(titled.fields["detectionMethod"], "focused_title")
        XCTAssertEqual(titled.fields["program"], "claude")
        XCTAssertEqual(titled.fields["candidateCount"], "2")
        XCTAssertEqual(titled.fields["sessionCount"], "2")
        XCTAssertFalse(titled.fields.values.contains { $0.contains("private") })
        let tty = TerminalForegroundProcessDetector.detectWithDiagnostics(records: records, terminalPID: 100, focusedTTY: "ttys001")
        XCTAssertEqual(tty.fields["detectionMethod"], "focused_tty")
        XCTAssertEqual(tty.fields["program"], "codex")
        let ambiguous = TerminalForegroundProcessDetector.detectWithDiagnostics(records: records, terminalPID: 100, focusedTTY: nil)
        XCTAssertEqual(ambiguous.route, .unknown)
        XCTAssertEqual(ambiguous.fields["detectionMethod"], "ambiguous_sessions")
    }
    func testRoutesFocusedGhosttyTTYToCodexWhileClaudeRunsInAnotherTab() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Ghostty /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100   101   201 ttys000  login -login
          102   101   102   201 ttys000  zsh -zsh
          201   102   201   201 ttys000  codex /opt/homebrew/bin/codex
          103   100   103   301 ttys001  login -login
          104   103   104   301 ttys001  zsh -zsh
          301   104   301   301 ttys001  claude /opt/homebrew/bin/claude
        """)

        XCTAssertEqual(
            TerminalForegroundProcessDetector.detect(records: records, terminalPID: 100, focusedTTY: "ttys000"),
            .cli(.init(program: .codex, tty: "ttys000"))
        )
    }

    func testIgnoresBackgroundCLIAndRoutesShell() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Ghostty /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100   101   102 ttys000  login -login
          102   101   102   102 ttys000  zsh -zsh
          201   102   201   102 ttys000  codex /opt/homebrew/bin/codex
        """)

        XCTAssertEqual(
            TerminalForegroundProcessDetector.detect(records: records, terminalPID: 100, focusedTTY: "ttys000"),
            .shell
        )
    }

    func testRecognizesNodeHostedAgyFromArguments() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Ghostty /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100   101   201 ttys000  login -login
          102   101   102   201 ttys000  zsh -zsh
          201   102   201   201 ttys000  node /usr/local/bin/node /opt/antigravity/bin/agy.js
        """)

        XCTAssertEqual(
            TerminalForegroundProcessDetector.detect(records: records, terminalPID: 100, focusedTTY: "ttys000"),
            .cli(.init(program: .agy, tty: "ttys000"))
        )
    }

    func testDoesNotGuessFocusedTabWhenMultipleSessionsAreAmbiguous() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Ghostty /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100   101   201 ttys000  login -login
          201   101   201   201 ttys000  codex /usr/local/bin/codex
          102   100   102   301 ttys001  login -login
          301   102   301   301 ttys001  claude /usr/local/bin/claude
        """)

        XCTAssertEqual(
            TerminalForegroundProcessDetector.detect(records: records, terminalPID: 100, focusedTTY: nil),
            .unknown
        )
    }

    func testExtractsLastTTYMentionFromAccessibilityText() {
        XCTAssertEqual(
            TerminalForegroundProcessDetector.tty(in: "Last login on ttys001\nLast login on ttys007"),
            "ttys007"
        )
    }

    func testFocusedCLITitleOverridesStaleScrollbackTTY() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Ghostty /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100   101   102 ttys000  login -login
          102   101   102   102 ttys000  zsh -zsh
          103   100   103   203 ttys002  login -login
          104   103   104   203 ttys002  zsh -zsh
          203   104   203   203 ttys002  agy agy
        """)

        XCTAssertEqual(
            TerminalForegroundProcessDetector.detect(
                records: records,
                terminalPID: 100,
                focusedTTY: "ttys000",
                focusedText: "Last login on ttys000",
                focusedTitle: "agy"
            ),
            .cli(.init(program: .agy, tty: "ttys002"))
        )
    }

    func testRecognizesClaudeCodePathComponent() {
        let records = TerminalForegroundProcessDetector.parseProcessSnapshot("""
          100     1   100   100 ??       Ghostty /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100   101   201 ttys003  login -login
          102   101   102   201 ttys003  zsh -zsh
          201   102   201   201 ttys003  node /opt/node /opt/node_modules/@anthropic-ai/claude-code/cli.js
        """)

        XCTAssertEqual(
            TerminalForegroundProcessDetector.detect(records: records, terminalPID: 100, focusedTTY: "ttys003"),
            .cli(.init(program: .claude, tty: "ttys003"))
        )
    }
}
