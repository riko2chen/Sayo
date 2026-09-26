import Foundation
import SayoCore

public enum BubblePhase: Equatable, Sendable {
    case hidden, idle, loading, ready, replacing, replaced, failed
}

public enum BubblePresentation: Equatable, Sendable {
    case standard, notice
}

public struct BubbleState: Equatable, Sendable {
    public var phase: BubblePhase = .hidden
    public var presentation: BubblePresentation = .standard
    public var expanded = false
    public var context: TextContext?
    public var result: String = ""
    public var message: String = ""
    public init() {}
}

/// All workflow decisions live here. UI, Accessibility and provider wire formats stay outside.
@MainActor public final class RewriteCoordinator {
    public private(set) var state = BubbleState()
    public var onChange: ((BubbleState) -> Void)?
    public var onDiagnostic: ((String, [String: String]) -> Void)?
    public private(set) var diagnosticInvocationID: String?
    private var diagnosticOrdinal = 0
    private var diagnosticSequence = 0
    private var diagnosticStarted = ProcessInfo.processInfo.systemUptime
    private var diagnosticFields: [String: String] = [:]
    private var diagnosticActive = false
    public private(set) var settings: AppSettings
    private let source: any TextInputSource
    private let replacer: any TextReplacer
    private var provider: any RewriteProvider
    private let clock: any DelayClock
    private var task: Task<Void, Never>?
    private var generation = 0
    private var snapshot: TextSnapshot?
    private var suppressed: (id: String, text: String)?
    private var completionObservation: (id: String, text: String, selection: SayoCore.TextRange)?

    public init(settings: AppSettings, source: any TextInputSource, replacer: any TextReplacer,
                provider: any RewriteProvider, clock: any DelayClock = SystemDelayClock()) {
        self.settings = settings; self.source = source; self.replacer = replacer
        self.provider = provider; self.clock = clock
    }

    public func configure(_ settings: AppSettings, provider: any RewriteProvider) {
        cancelPending()
        self.settings = settings; self.provider = provider
        state = BubbleState(); publish()
    }

    /// Applies the mode and action bindings immediately without applying the
    /// rest of an unsaved settings draft to the live rewrite provider.
    public func configureShortcutBehavior(_ settings: AppSettings) {
        let modeChanged = self.settings.mode != settings.mode
        self.settings.mode = settings.mode
        self.settings.invokeShortcut = settings.invokeShortcut
        self.settings.copyShortcut = settings.copyShortcut
        self.settings.replaceShortcut = settings.replaceShortcut
        self.settings.secondaryShortcut = settings.secondaryShortcut
        guard modeChanged else { return }
        cancelPending()
        state = BubbleState(); publish()
    }

    public func inputChanged(_ context: TextContext?) {
        guard state.phase != .replacing else { return }
        guard let context, !context.isSensitive else {
            dismiss()
            return
        }

        // Keep the completion mark anchored where the request started. The
        // replacement itself normally triggers an input observation before
        // the brief success animation has finished.
        if state.phase == .replaced,
           completionObservation?.id == context.id,
           completionObservation?.text == context.text,
           completionObservation?.selection == context.selection {
            return
        }

        // Movement and scrolling update geometry without restarting a network call.
        if let previous = state.context, previous.id == context.id,
           previous.text == context.text, previous.selection == context.selection {
            if previous.caret != context.caret { state.context = context; publish() }
            return
        }
        if let captured = snapshot,
           (state.phase == .loading || state.phase == .ready),
           matchesCurrentInput(captured, context) {
            if state.context?.caret != context.caret {
                state.context?.caret = context.caret
                publish()
            }
            return
        }
        cancelPending()
        state = BubbleState(); state.context = context
        if suppressed?.id == context.id && suppressed?.text == context.text {
            publish(); return
        }
        suppressed = nil
        guard (try? context.snapshot()) != nil else { publish(); return }
        guard settings.mode != .silent else { publish(); return }
        state.phase = .idle; publish()
    }

    public func click() { beginRewrite(autoApply: false, trigger: "bubble") }

    public func shortcut(destination: TranslationDestination = .primary) {
        guard state.phase != .loading,
              state.phase != .replacing
        else { return }
        beginRewrite(autoApply: settings.mode == .silent, trigger: "shortcut", destination: destination)
    }

    public func dismiss() {
        cancelPending(); state = BubbleState(); publish()
    }

    public func beginRewrite(autoApply: Bool, trigger: String = "direct", destination: TranslationDestination = .primary) {
        cancelPending()
        startDiagnostic(trigger: trigger)
        do {
            guard let context = try source.currentContext() else { throw SayoError.noInput }
            guard !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                diagnose("invocation_ignored"); diagnosticActive = false
                state = BubbleState()
                publish()
                return
            }
            let captured = try context.snapshot(scope: .automatic)
            snapshot = captured
            diagnosticFields = ["app": context.applicationName, "inputID": context.id]
            diagnose("input_captured", ["sourceLength": String(captured.source.utf16.count),
                "scope": context.selection.length > 0 ? "selection" : "input",
                "range": "\(captured.range.location):\(captured.range.length)"])
            diagnose("rewrite_requested")
            state = BubbleState(); state.context = context
            state.phase = .loading; state.expanded = false; publish()
            let token = generation
            let request = settings.rewriteRequest(text: captured.source, destination: destination)
            let activeProvider = provider
            task = Task { [weak self] in
                do {
                    let result = try await activeProvider.rewrite(request)
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    guard let current = try self.source.currentContext(), self.matchesCurrentInput(captured, current) else {
                        throw SayoError.staleInput
                    }
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text.utf8.count <= 256_000 else { throw SayoError.invalidResponse }
                    self.diagnose("rewrite_ready", ["resultLength": String(text.utf16.count)])
                    self.state.phase = .ready; self.state.expanded = !autoApply; self.state.result = text
                    if autoApply { self.applyResult() } else { self.publish() }
                } catch {
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    self.fail(error)
                }
            }
        } catch { fail(error) }
    }

    /// Presents a capture failure from an explicit shortcut before a TextContext exists.
    public func rejectInvocation(_ error: Error, trigger: String = "shortcut") {
        cancelPending()
        startDiagnostic(trigger: trigger)
        fail(error)
    }

    private func startDiagnostic(trigger: String) {
        diagnosticInvocationID = UUID().uuidString
        diagnosticOrdinal += 1; diagnosticSequence = 0
        diagnosticStarted = ProcessInfo.processInfo.systemUptime
        diagnosticFields = [:]; diagnosticActive = true
        diagnose("invocation_started", ["ordinal": String(diagnosticOrdinal), "trigger": trigger, "mode": settings.mode.rawValue])
    }

    public func applyResult() {
        guard state.phase == .ready, let captured = snapshot else { return }
        let text = state.result
        let token = generation
        diagnose("replacement_requested")
        state.phase = .replacing; publish()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let current = try self.source.currentContext(), self.matchesCurrentInput(captured, current) else {
                    throw SayoError.staleInput
                }
                let outcome: TextReplacementOutcome
                // The animated replacer falls back to an instant write when Reduce Motion is on.
                if captured.context.selection.length == 0,
                   let animatedReplacer = self.replacer as? any AnimatedTextReplacer {
                    outcome = try await animatedReplacer.replaceAnimated(text, in: captured)
                } else {
                    outcome = try await self.replacer.replace(text, in: captured)
                }
                guard token == self.generation else { return }
                let finalText = outcome == .insertedAtCaret ? captured.insertingAtCaret(text) : captured.replacing(with: text)
                self.suppressed = (captured.context.id, finalText)
                if let completedContext = try? self.source.currentContext() {
                    self.completionObservation = (
                        completedContext.id,
                        completedContext.text,
                        completedContext.selection
                    )
                }
                self.state.message = outcome == .insertedAtCaret
                    ? self.settings.interfaceLanguage.text("Inserted after the caret.", "已追加到光标后。") : ""
                self.diagnose("invocation_completed", ["outcome": outcome == .insertedAtCaret ? "inserted_at_caret" : "replaced"])
                self.diagnosticActive = false
                self.state.phase = .replaced; self.state.expanded = false; self.publish()
                try? await self.clock.sleep(seconds: 0.8)
                guard !Task.isCancelled, token == self.generation else { return }
                self.state.phase = .hidden; self.state.expanded = false; self.publish()
            } catch {
                guard !Task.isCancelled, token == self.generation else { return }
                self.fail(error)
            }
        }
    }

    private func matchesCurrentInput(_ captured: TextSnapshot, _ current: TextContext) -> Bool {
        captured.matchesForReplacement(current)
    }

    private func cancelPending() {
        if diagnosticActive { diagnose("invocation_cancelled") }
        diagnosticActive = false; diagnosticInvocationID = nil
        generation += 1; task?.cancel(); task = nil; snapshot = nil
        completionObservation = nil
    }
    private func diagnose(_ event: String, _ fields: [String: String] = [:]) {
        guard let id = diagnosticInvocationID else { return }
        diagnosticSequence += 1
        var all = diagnosticFields.merging(fields, uniquingKeysWith: { _, new in new })
        all["invocationID"] = id; all["sequence"] = String(diagnosticSequence)
        all["elapsedMs"] = String(Int((ProcessInfo.processInfo.systemUptime - diagnosticStarted) * 1000))
        onDiagnostic?(event, all)
    }
    private func fail(_ error: Error) {
        diagnose("invocation_failed", ["error": DiagnosticEvent.errorCode(error)])
        diagnosticActive = false
        state.phase = .failed; state.expanded = true
        if let sayoError = error as? SayoError {
            state.message = sayoError.message(language: settings.interfaceLanguage)
            state.presentation = sayoError == .compatibilitySelectionRequired ? .notice : .standard
        } else {
            state.message = error.localizedDescription
        }
        publish()
        if state.presentation == .notice {
            let token = generation
            task = Task { [weak self, clock] in
                do { try await clock.sleep(seconds: 3) } catch { return }
                guard !Task.isCancelled, let self, token == self.generation,
                      self.state.presentation == .notice
                else { return }
                self.state = BubbleState()
                self.publish()
            }
        }
    }
    private func publish() { onChange?(state) }
}
