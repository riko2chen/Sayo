import Foundation
import XCTest
import SayoCore

/// Executes only our resources in clean shells. The editable-buffer APIs and
/// CLI are mocked; no user rc file, app, bridge directory, or model is involved.
final class TerminalShellBehaviorTests: XCTestCase {
    func testZshPreservesExactInputOutputAndReverseUnicodeSelection() throws {
        let original = "e\u{301} 中👋\nquotes ' \" \\ $HOME\n\n"
        try exerciseWidget(shell: .zsh, input: original, output: literalOutput, cursor: 1, mark: 5)
    }

    func testZshKeepsOriginalBufferCursorAndSelectionOnErrorTimeoutOrCancel() throws {
        for code in [1, 124, 130] {
            try exerciseWidget(shell: .zsh, input: "中👋\nkeep\n\n", output: literalOutput, cursor: 2, mark: 4, exitCode: code)
        }
    }

    func testZshPreservesEmptyBuffersAndSingleOrRepeatedTrailingNewlines() throws {
        for value in ["", " \t\n", "\n\n"] {
            try exerciseWidget(shell: .zsh, input: value, output: literalOutput, cursor: 0, expectInvocation: false)
        }
        for value in ["one line", "one line\n"] {
            try exerciseWidget(shell: .zsh, input: value, output: value, cursor: 0, regionActive: false)
        }
        try exerciseWidget(shell: .zsh, input: "erase this", output: "", cursor: 1, regionActive: false)
    }

    func testBash3DoesNotDefineWidgetOrChangeExistingBindings() throws {
        let version = try run("/bin/bash", arguments: ["--noprofile", "--norc", "-c", "printf %s \"${BASH_VERSINFO[0]}\""])
        guard version.output == Data("3".utf8) else { throw XCTSkip("System Bash is not version 3") }
        let script = #"""
        bind() { printf 'binding was modified'; }
        READLINE_LINE='keep this'
        READLINE_POINT=3
        source "$SAYO_TEST_RESOURCE"
        declare -F __sayo_rewrite_widget && exit 9
        printf '%s:%s' "$READLINE_LINE" "$READLINE_POINT"
        """#
        let result = try run("/bin/bash", arguments: ["--noprofile", "--norc", "-c", script], environment: [
            "SAYO_TEST_RESOURCE": resource(.bash).path
        ])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Data("keep this:3".utf8))
        XCTAssertTrue(result.error.contains("requires Bash 4 or newer"))
    }

    func testBash4UsesByteCursorAndPreservesBuffersOnSuccessAndFailure() throws {
        _ = try executable(for: .bash)
        let original = "e\u{301} 中👋\nkeep\n\n"
        let byteCursor = "e\u{301} 中👋".utf8.count
        try exerciseWidget(shell: .bash, input: original, output: literalOutput, cursor: byteCursor)
        for code in [1, 124, 130] {
            try exerciseWidget(shell: .bash, input: original, output: literalOutput, cursor: byteCursor, exitCode: code)
        }
        try exerciseWidget(shell: .bash, input: original, output: "", cursor: byteCursor)
        try exerciseWidget(shell: .bash, input: " \t\n", output: literalOutput, cursor: 2, expectInvocation: false)
    }

    func testFishSyntaxAndExactBuffersWithMockCommandline() throws {
        let fish = try executable(for: .fish)
        let syntax = try run(fish, arguments: ["--no-config", "--no-execute", resource(.fish).path])
        XCTAssertEqual(syntax.status, 0, syntax.error)
        for value in ["", " \t\n", "\n\n"] {
            try exerciseWidget(shell: .fish, input: value, output: literalOutput, cursor: 0, expectInvocation: false)
        }
        for value in ["中👋 e\u{301}", "one\ntwo", "one\ntwo\n", "one\ntwo\n\n"] {
            try exerciseWidget(shell: .fish, input: value, output: literalOutput, cursor: 0)
        }
        try exerciseWidget(shell: .fish, input: "empty result", output: "", cursor: 3)
        // Exercise the /tmp fallback as well as a TMPDIR containing spaces.
        try exerciseWidget(shell: .fish, input: "one\n", output: "\n\n", cursor: 1, useTMPDIR: false)
        for code in [1, 124, 130] {
            try exerciseWidget(shell: .fish, input: "中👋\nkeep\n\n", output: literalOutput, cursor: 2, exitCode: code)
        }
    }

    private enum Shell: String {
        case zsh, bash, fish
    }

    private var literalOutput: String {
        // Both command-substitution spellings, metacharacters, Unicode and
        // trailing newlines must stay literal. Execution would create a marker.
        #"-n 'quotes' "double" \ $HOME $(touch "$SAYO_TEST_MARKER") `touch "$SAYO_TEST_MARKER"`; 中👋"# + "\nnext\n\n"
    }

    private func exerciseWidget(
        shell: Shell, input: String, output: String, cursor: Int,
        mark: Int = 0, regionActive: Bool = true, exitCode: Int = 0,
        useTMPDIR: Bool = true, expectInvocation: Bool = true
    ) throws {
        let executable = try executable(for: shell)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sayo shell test '\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeCLI = root.appendingPathComponent("fake sayo")
        let inputFile = root.appendingPathComponent("input")
        let argsFile = root.appendingPathComponent("args")
        let cursorFile = root.appendingPathComponent("cursor")
        let selectionFile = root.appendingPathComponent("selection")
        let markerFile = root.appendingPathComponent("must-not-execute")
        let fakeScript = #"""
        #!/bin/sh
        /bin/cat > "$SAYO_TEST_INPUT_FILE"
        printf '%s\0' "$@" > "$SAYO_TEST_ARGS_FILE"
        printf '%s' "$SAYO_TEST_OUTPUT"
        exit "$SAYO_TEST_EXIT"
        """#
        try Data(fakeScript.utf8).write(to: fakeCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        var environment = [
            "SAYO_CLI": fakeCLI.path,
            "SAYO_TEST_RESOURCE": resource(shell).path,
            "SAYO_TEST_INPUT": input,
            "SAYO_TEST_OUTPUT": output,
            "SAYO_TEST_EXIT": String(exitCode),
            "SAYO_TEST_CURSOR": String(cursor),
            "SAYO_TEST_MARK": String(mark),
            "SAYO_TEST_REGION": regionActive ? "1" : "0",
            "SAYO_TEST_INPUT_FILE": inputFile.path,
            "SAYO_TEST_ARGS_FILE": argsFile.path,
            "SAYO_TEST_CURSOR_FILE": cursorFile.path,
            "SAYO_TEST_SELECTION_FILE": selectionFile.path,
            "SAYO_TEST_MARKER": markerFile.path
        ]
        if useTMPDIR { environment["TMPDIR"] = root.path }
        let arguments: [String]
        switch shell {
        case .zsh: arguments = ["-f", "-c", zshHarness]
        case .bash: arguments = ["--noprofile", "--norc", "-c", bashHarness]
        case .fish: arguments = ["--no-config", "-c", fishHarness]
        }
        let result = try run(executable, arguments: arguments, environment: environment)
        XCTAssertEqual(result.status, 0, result.error)
        if expectInvocation {
            XCTAssertEqual(try Data(contentsOf: inputFile), Data(input.utf8), "\(shell) altered stdin")
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: inputFile.path), "\(shell) invoked Sayo for blank input")
            XCTAssertFalse(FileManager.default.fileExists(atPath: argsFile.path), "\(shell) invoked Sayo for blank input")
            XCTAssertTrue(result.error.isEmpty, "\(shell) printed an error for blank input: \(result.error)")
        }
        let expected = expectInvocation && exitCode == 0 ? output : input
        XCTAssertEqual(result.output, Data(expected.utf8), "\(shell) altered the buffer or executed its contents: \(result.error)")
        let expectedCursor = expectInvocation && exitCode == 0
            ? (shell == .bash ? output.utf8.count : output.unicodeScalars.count)
            : cursor
        XCTAssertEqual(try String(contentsOf: cursorFile, encoding: .utf8), String(expectedCursor))
        if expectInvocation {
            var expectedArguments = ["rewrite", shell == .bash ? "--cursor-byte" : "--cursor", String(cursor)]
            if shell == .zsh && regionActive {
                expectedArguments += ["--selection-start", String(min(cursor, mark)), "--selection-length", String(abs(cursor - mark))]
            }
            XCTAssertEqual(try Data(contentsOf: argsFile), Data((expectedArguments.joined(separator: "\0") + "\0").utf8))
        }
        if shell == .zsh {
            let expectedRegion = expectInvocation && exitCode == 0 ? "0" : (regionActive ? "1" : "0")
            XCTAssertEqual(try String(contentsOf: selectionFile, encoding: .utf8), "\(mark):\(expectedRegion)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerFile.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix("sayo-rewrite.") }, "Widget leaked a temporary response")
    }

    private var zshHarness: String {
        #"""
        zle() { :; }
        bindkey() { :; }
        source "$SAYO_TEST_RESOURCE"
        BUFFER="$SAYO_TEST_INPUT"
        CURSOR="$SAYO_TEST_CURSOR"
        MARK="$SAYO_TEST_MARK"
        REGION_ACTIVE="$SAYO_TEST_REGION"
        __sayo_rewrite_widget
        printf '%s' "$BUFFER"
        printf '%s' "$CURSOR" > "$SAYO_TEST_CURSOR_FILE"
        printf '%s:%s' "$MARK" "$REGION_ACTIVE" > "$SAYO_TEST_SELECTION_FILE"
        """#
    }

    private var bashHarness: String {
        #"""
        bind() { :; }
        source "$SAYO_TEST_RESOURCE"
        READLINE_LINE="$SAYO_TEST_INPUT"
        READLINE_POINT="$SAYO_TEST_CURSOR"
        __sayo_rewrite_widget
        printf '%s' "$READLINE_LINE"
        printf '%s' "$READLINE_POINT" > "$SAYO_TEST_CURSOR_FILE"
        """#
    }

    private var fishHarness: String {
        #"""
        function bind
        end
        set -g mock_buffer "$SAYO_TEST_INPUT"
        set -g mock_cursor "$SAYO_TEST_CURSOR"
        function commandline
            switch "$argv[1]"
                case --current-buffer
                    # Match the official builtin's one added newline.
                    printf '%s\n' "$mock_buffer"
                case --cursor
                    if test (count $argv) -eq 1
                        printf '%s\n' "$mock_cursor"
                    else
                        set -g mock_cursor "$argv[2]"
                    end
                case --replace
                    test "$argv[2]" = --; or return 9
                    test (count $argv) -eq 3; or return 9
                    set -g mock_buffer "$argv[3]"
                case '*'
                    printf '%s\n' 'Unexpected commandline operation' >&2
                    return 9
            end
        end
        source "$SAYO_TEST_RESOURCE"
        __sayo_rewrite_widget
        printf '%s' "$mock_buffer"
        printf '%s' "$mock_cursor" > "$SAYO_TEST_CURSOR_FILE"
        """#
    }

    private func resource(_ shell: Shell) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SayoTerminal/Resources/sayo.\(shell.rawValue)")
    }

    private func executable(for shell: Shell) throws -> String {
        if shell == .zsh { return "/bin/zsh" }
        let override = ProcessInfo.processInfo.environment["SAYO_TEST_\(shell.rawValue.uppercased())"]
        let candidates = [override, "/opt/homebrew/bin/\(shell.rawValue)", "/usr/local/bin/\(shell.rawValue)"]
            .compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if shell == .bash {
                let version = try run(path, arguments: ["--noprofile", "--norc", "-c", "printf %s \"${BASH_VERSINFO[0]}\""])
                guard let major = Int(String(decoding: version.output, as: UTF8.self)), major >= 4 else { continue }
            }
            return path
        }
        throw XCTSkip("\(shell.rawValue)\(shell == .bash ? " 4+" : "") is unavailable; runtime behavior is unverified. Set SAYO_TEST_\(shell.rawValue.uppercased()) to a test executable.")
    }

    private func run(_ executable: String, arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "en_US.UTF-8"]
            .merging(environment) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, String(decoding: error, as: UTF8.self))
    }
}
