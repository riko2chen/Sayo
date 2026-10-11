import AppKit
import Foundation
import SayoCore

enum TerminalFocusedAgent: Equatable {
    case supported(CLIEditorProgram)
    case unsupported
}

/// Otty's focused-pane metadata survives custom titles and full-screen redraws.
/// Only the agent kind is retained; paths, session IDs and titles are not logged.
enum OttyFocusedPaneDetector {
    static func detect(in application: NSRunningApplication) -> TerminalFocusedAgent? {
        guard application.bundleIdentifier == "io.appmakes.otty",
              let bundleURL = application.bundleURL else { return nil }
        let executable = bundleURL.appendingPathComponent("Contents/MacOS/otty-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["pane", "show", "--json", "--timeout", "200"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OTTY_PANE_ID")
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parse(data)
        } catch {
            return nil
        }
    }

    static func parse(_ data: Data) -> TerminalFocusedAgent? {
        struct Response: Decodable {
            struct Pane: Decodable {
                let active: Bool
                let agent: String
            }
            let ok: Bool
            let data: Pane
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.ok, response.data.active else { return nil }
        switch response.data.agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "claude code", "claude-code": return .supported(.claude)
        case "codex", "codex cli": return .supported(.codex)
        case "agy", "antigravity", "antigravity cli": return .supported(.agy)
        case "": return nil // No hook evidence: use the ordinary process/AX checks.
        default: return .unsupported
        }
    }
}
