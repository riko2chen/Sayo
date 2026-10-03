import XCTest
import SayoCore
@testable import SayoApplication

private actor ControlledClock: DelayClock {
    var waits: [CheckedContinuation<Void, Error>] = []
    func sleep(seconds: Double) async throws { try await withCheckedThrowingContinuation { waits.append($0) } }
    var count: Int { waits.count }
    func advance() { let pending = waits; waits = []; pending.forEach { $0.resume() } }
}

private actor ControlledProvider: RewriteProvider {
    var requests: [RewriteRequest] = []
    var pending: [CheckedContinuation<RewriteResult, Error>] = []
    func rewrite(_ request: RewriteRequest) async throws -> RewriteResult {
        requests.append(request)
        // Intentionally ignores cancellation to model a late network response.
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    var count: Int { requests.count }
    func complete(_ text: String) { guard !pending.isEmpty else { return }; pending.removeFirst().resume(returning: .init(text: text)) }
    func reject() { guard !pending.isEmpty else { return }; pending.removeFirst().resume(throwing: SayoError.network("Offline")) }
}

@MainActor private final class MemoryInput: TextInputSource, AnimatedTextReplacer {
    var context: TextContext? = .init(id: "field", text: "I like 这个产品", selection: .init(location: 11, length: 0))
    var replacements: [String] = []
    var animatedReplacementCount = 0
    var appendInstead = false
    func currentContext() throws -> TextContext? { context }
    func replace(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        guard let context, snapshot.matchesForReplacement(context) else { throw SayoError.staleInput }
        replacements.append(text)
        self.context?.text = appendInstead ? snapshot.insertingAtCaret(text) : snapshot.replacing(with: text)
        self.context?.selection = .init(location: (appendInstead ? snapshot.insertionRange.location : snapshot.range.location) + text.utf16.count, length: 0)
        return appendInstead ? .insertedAtCaret : .replaced
    }
    func replaceAnimated(_ text: String, in snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        animatedReplacementCount += 1
        return try await replace(text, in: snapshot)
    }
}

@MainActor final class RewriteCoordinatorTests: XCTestCase {
    func testSecondLanguageUsesIndependentPromptAndManualReplacement() async {
        var settings = AppSettings()
        settings.prompt = "First: ${targetLanguage}"
        settings.secondaryPrompt = "Second: ${targetLanguage}"
        settings.secondaryTargetLanguage = .japanese
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)
        sut.shortcut(destination: .secondary)
        await eventually { await provider.count == 1 }
        let requests = await provider.requests
        XCTAssertEqual(requests[0].prompt, "Second: Japanese")
        XCTAssertEqual(requests[0].targetLanguage, .japanese)
        await provider.complete("この製品が好きです")
        await eventually { sut.state.phase == .ready }
        XCTAssertTrue(input.replacements.isEmpty)
        sut.applyResult()
        await eventually { sut.state.phase == .replaced }
        XCTAssertEqual(input.replacements, ["この製品が好きです"])
        await eventually { await clock.count == 1 }
        await clock.advance()
    }

    func testSecondLanguageSilentModeReplacesOnlySelection() async {
        var settings = AppSettings(); settings.mode = .silent
        settings.secondaryTargetLanguage = .french
        settings.secondaryPrompt = "Translate to ${targetLanguage}."
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        input.context = .init(id: "field", text: "Before hello after", selection: .init(location: 7, length: 5))
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)
        sut.shortcut(destination: .secondary)
        await eventually { await provider.count == 1 }
        let requests = await provider.requests
        XCTAssertEqual(requests[0].text, "hello")
        XCTAssertEqual(requests[0].prompt, "Translate to French.")
        await provider.complete("bonjour")
        await eventually { sut.state.phase == .replaced }
        XCTAssertEqual(input.context?.text, "Before bonjour after")
        await eventually { await clock.count == 1 }
        await clock.advance()
    }

    func testClickAndPrimaryShortcutDoNotReusePreviousSecondLanguagePrompt() async {
        var settings = AppSettings()
        settings.prompt = "First: ${targetLanguage}"
        settings.secondaryPrompt = "Second: ${targetLanguage}"
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.shortcut(destination: .secondary)
        await eventually { await provider.count == 1 }
        await provider.complete("second result")
        await eventually { sut.state.phase == .ready }
        sut.click()
        await eventually { await provider.count == 2 }
        await provider.complete("first result")
        await eventually { sut.state.phase == .ready }
        sut.shortcut()
        await eventually { await provider.count == 3 }
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.prompt), ["Second: Simplified Chinese", "First: English", "First: English"])
        XCTAssertEqual(requests.map(\.targetLanguage), [.simplifiedChinese, .english, .english])
        await provider.complete("first result again")
        sut.dismiss()
    }

    func testSecondLanguageLateResultCannotReplaceChangedInput() async {
        var settings = AppSettings(); settings.mode = .silent
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.shortcut(destination: .secondary)
        await eventually { await provider.count == 1 }
        input.context?.text = "changed"
        await provider.complete("stale translation")
        await eventually { sut.state.phase == .failed }
        XCTAssertTrue(input.replacements.isEmpty)
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 { if await condition() { return }; await Task.yield() }
        XCTFail("Condition did not settle", file: file, line: line)
    }
    func testDiagnosticIDsSeparateRepeatedInvocationsAndLateResponses() async throws {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        var events: [(String, [String: String])] = []
        sut.onDiagnostic = { events.append(($0, $1)) }
        sut.click(); await eventually { await provider.count == 1 }
        let first = try XCTUnwrap(sut.diagnosticInvocationID)
        sut.dismiss(); sut.shortcut(); await eventually { await provider.count == 2 }
        let second = try XCTUnwrap(sut.diagnosticInvocationID)
        XCTAssertNotEqual(first, second)
        await provider.complete("late result")
        await provider.complete("new result"); await eventually { sut.state.phase == .ready }
        XCTAssertEqual(events.filter { $0.0 == "invocation_started" }.map { $0.1["trigger"] }, ["bubble", "shortcut"])
        XCTAssertEqual(events.filter { $0.0 == "invocation_cancelled" }.map { $0.1["invocationID"] }, [first])
        XCTAssertEqual(events.filter { $0.0 == "rewrite_ready" }.map { $0.1["invocationID"] }, [second])
        XCTAssertTrue(events.allSatisfy { $0.1["elapsedMs"] != nil && $0.1["sequence"] != nil })
        sut.dismiss()
    }

    func testDiagnosticsRecordVerifiedAppendOutcomeAndNoFalseCancellation() async {
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        input.appendInstead = true
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider, clock: clock)
        var events: [(String, [String: String])] = []
        sut.onDiagnostic = { events.append(($0, $1)) }
        sut.click(); await eventually { await provider.count == 1 }
        await provider.complete("result"); await eventually { sut.state.phase == .ready }
        sut.applyResult(); await eventually { sut.state.phase == .replaced }
        await eventually { await clock.count == 1 }; await clock.advance()
        sut.dismiss()
        XCTAssertEqual(events.last { $0.0 == "invocation_completed" }?.1["outcome"], "inserted_at_caret")
        XCTAssertFalse(events.contains { $0.0 == "invocation_cancelled" })
    }

    func testSelectionIsRewrittenWhenPresent() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        input.context = .init(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.click()
        await eventually { await provider.count == 1 }
        let requests = await provider.requests
        XCTAssertEqual(requests.first?.text, "这个产品")
        await provider.complete("this product")
        await eventually { sut.state.phase == .ready }
    }

    func testNoSelectionUsesWholeField() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.click()
        await eventually { await provider.count == 1 }
        let requests = await provider.requests
        XCTAssertEqual(requests.first?.text, input.context?.text)
        await provider.complete("I like this product.")
        await eventually { sut.state.phase == .ready }
    }

    func testFallbackInsertionIsNotAutomaticallyRewritten() async {
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        input.appendInstead = true
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider, clock: clock)
        sut.click()
        await eventually { await provider.count == 1 }
        await provider.complete("[result]")
        await eventually { sut.state.phase == .ready }
        sut.applyResult()
        await eventually { sut.state.phase == .replaced }
        XCTAssertEqual(input.context?.text, "I like 这个产品[result]")
        XCTAssertFalse(sut.state.message.isEmpty)
        await eventually { await clock.count == 1 }; await clock.advance()
        await eventually { sut.state.phase == .hidden }
        sut.inputChanged(input.context)
        XCTAssertEqual(sut.state.phase, .hidden)
        let count = await provider.count
        XCTAssertEqual(count, 1)
    }

    func testManualInputDoesNotRequestUntilClicked() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.inputChanged(input.context)
        XCTAssertEqual(sut.state.phase, .idle)
        let count = await provider.count; XCTAssertEqual(count, 0)
        sut.click(); await eventually { await provider.count == 1 }
        XCTAssertEqual(sut.state.phase, .loading)
        XCTAssertFalse(sut.state.expanded)
        await provider.complete("I like this product.")
        await eventually { sut.state.phase == .ready }
        XCTAssertTrue(sut.state.expanded)
        XCTAssertTrue(input.replacements.isEmpty)
    }
    func testRewriteRequestUsesCurrentTargetLanguageAndCustomPrompt() async {
        var settings = AppSettings()
        settings.mode = .manual
        settings.prompt = "Keep punctuation exactly as intended."
        settings.targetLanguage = .traditionalChinese
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)

        sut.click()
        await eventually { await provider.count == 1 }
        let requests = await provider.requests
        XCTAssertTrue(requests[0].prompt.contains("Keep punctuation exactly as intended."))
        XCTAssertTrue(requests[0].prompt.contains("Write the final result in Traditional Chinese."))

        await provider.complete("我喜歡這個產品。")
        await eventually { sut.state.phase == .ready }
    }
    func testSilentShortcutLoadsAndApplies() async {
        var settings = AppSettings(); settings.mode = .silent
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)
        var publishedStates: [BubbleState] = []
        sut.onChange = { publishedStates.append($0) }
        sut.inputChanged(input.context); XCTAssertEqual(sut.state.phase, .hidden)
        sut.shortcut(); XCTAssertEqual(sut.state.phase, .loading)
        XCTAssertFalse(sut.state.expanded)
        await eventually { await provider.count == 1 }; await provider.complete("I like this product.")
        await eventually { input.replacements.count == 1 }
        await eventually { sut.state.phase == .replaced }
        XCTAssertFalse(sut.state.expanded)
        XCTAssertFalse(publishedStates.contains { $0.phase == .ready && $0.expanded })
        await eventually { await clock.count == 1 }; await clock.advance()
        await eventually { sut.state.phase == .hidden }
    }
    func testEnabledInputAnimationUsesAnimatedReplacer() async {
        var settings = AppSettings()
        settings.inputAnimationEnabled = true
        settings.mode = .silent
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)

        sut.shortcut()
        await eventually { await provider.count == 1 }
        await provider.complete("I like this product.")
        await eventually { input.replacements.count == 1 }

        XCTAssertEqual(input.animatedReplacementCount, 1)
        XCTAssertEqual(input.context?.text, "I like this product.")
        await eventually { await clock.count == 1 }
        await clock.advance()
    }
    func testDisabledInputAnimationUsesInstantReplacer() async {
        var settings = AppSettings()
        settings.mode = .silent
        settings.inputAnimationEnabled = false
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)

        sut.shortcut()
        await eventually { await provider.count == 1 }
        await provider.complete("I like this product.")
        await eventually { sut.state.phase == .replaced }

        XCTAssertEqual(input.animatedReplacementCount, 0)
        XCTAssertEqual(input.replacements, ["I like this product."])
        await eventually { await clock.count == 1 }
        await clock.advance()
    }
    func testSelectedTextSkipsInputAnimationEvenIfSelectionCollapsesBeforeApply() async {
        var settings = AppSettings()
        settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        input.context = .init(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)

        sut.click()
        await eventually { await provider.count == 1 }
        input.context?.selection = .init(location: 11, length: 0)
        await provider.complete("this product")
        await eventually { sut.state.phase == .ready }
        sut.applyResult()
        await eventually { sut.state.phase == .replaced }

        XCTAssertEqual(input.animatedReplacementCount, 0)
        XCTAssertEqual(input.replacements, ["this product"])
        XCTAssertEqual(input.context?.text, "Before this product after")
        await eventually { await clock.count == 1 }
        await clock.advance()
    }
    func testLateResponseAfterTypingIsDiscarded() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.click(); await eventually { await provider.count == 1 }
        input.context?.text = "new text"; input.context?.selection = .init(location: 8, length: 0); sut.inputChanged(input.context)
        await provider.complete("OLD RESULT")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(sut.state.phase, .idle); XCTAssertEqual(sut.state.result, "")
        XCTAssertTrue(input.replacements.isEmpty)
    }
    func testChangedFocusBeforeAcceptCannotOverwriteOtherField() async {
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider)
        sut.click(); await eventually { await provider.count == 1 }
        await provider.complete("English"); await eventually { sut.state.phase == .ready }
        input.context?.id = "another field"; sut.applyResult()
        await eventually { sut.state.phase == .failed }
        XCTAssertTrue(input.replacements.isEmpty)
    }
    func testSelectedTextIsRewrittenAndSurroundingTextIsPreserved() async {
        var settings = AppSettings(); settings.mode = .silent
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        input.context = .init(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)
        sut.shortcut(); await eventually { await provider.count == 1 }
        let requests = await provider.requests; XCTAssertEqual(requests.first?.text, "这个产品")
        await provider.complete("this product")
        await eventually { input.context?.text == "Before this product after" }
        XCTAssertEqual(input.animatedReplacementCount, 0)
        await eventually { await clock.count == 1 }; await clock.advance()
    }
    func testCollapsedSelectionAtCapturedBoundaryStaysValidThroughApply() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        input.context = .init(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)

        sut.click(); await eventually { await provider.count == 1 }
        input.context?.selection = .init(location: 11, length: 0)
        sut.inputChanged(input.context)
        XCTAssertEqual(sut.state.phase, .loading)

        await provider.complete("this product")
        await eventually { sut.state.phase == .ready }
        sut.applyResult()
        await eventually { sut.state.phase == .replaced }
        XCTAssertEqual(input.context?.text, "Before this product after")
        await eventually { await clock.count == 1 }; await clock.advance()
    }
    func testMovedSelectionBeforeApplyCannotReplaceCapturedText() async {
        let input = MemoryInput(), provider = ControlledProvider()
        input.context = .init(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider)
        sut.click(); await eventually { await provider.count == 1 }
        await provider.complete("this product"); await eventually { sut.state.phase == .ready }
        input.context?.selection = .init(location: 0, length: 6)
        sut.applyResult()
        await eventually { sut.state.phase == .failed }
        XCTAssertTrue(input.replacements.isEmpty)
        XCTAssertEqual(input.context?.text, "Before 这个产品 after")
    }
    func testChangedTextBeforeApplyCannotReplaceCapturedText() async {
        let input = MemoryInput(), provider = ControlledProvider()
        input.context = .init(id: "field", text: "Before 这个产品 after", selection: .init(location: 7, length: 4))
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider)
        sut.click(); await eventually { await provider.count == 1 }
        await provider.complete("this product"); await eventually { sut.state.phase == .ready }
        input.context?.text = "User changed the text"
        input.context?.selection = .init(location: 0, length: 0)
        sut.applyResult()
        await eventually { sut.state.phase == .failed }
        XCTAssertTrue(input.replacements.isEmpty)
        XCTAssertEqual(input.context?.text, "User changed the text")
    }
    func testEmptyModelOutputNeverReplaces() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.shortcut(); await eventually { await provider.count == 1 }; await provider.complete("   \n")
        await eventually { sut.state.phase == .failed }; XCTAssertTrue(input.replacements.isEmpty)
    }
    func testEmptyInputNeverRequestsProvider() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        input.context = .init(id: "field", text: "  \n\t", selection: .init(location: 4, length: 0))
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider)
        sut.shortcut()
        for _ in 0..<30 { await Task.yield() }
        let requestCount = await provider.count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(sut.state.phase, .hidden)
        XCTAssertFalse(sut.state.expanded)
        XCTAssertTrue(sut.state.message.isEmpty)
    }
    func testTypingInManualModeWaitsForExplicitAction() async {
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider, clock: clock)
        sut.inputChanged(input.context)
        input.context?.text += "!"; input.context?.selection.location += 1
        sut.inputChanged(input.context)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(sut.state.phase, .idle)
        let waits = await clock.count
        let requests = await provider.count
        XCTAssertEqual(waits, 0)
        XCTAssertEqual(requests, 0)

        sut.click()
        await eventually { await provider.count == 1 }
        XCTAssertEqual(sut.state.phase, .loading)
    }

    func testDeletingAllInputHidesManualBubble() async {
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider)
        sut.inputChanged(input.context)

        input.context = .init(id: "field", text: "", selection: .init(location: 0, length: 0))
        sut.inputChanged(input.context)
        XCTAssertEqual(sut.state.phase, .hidden)
        XCTAssertFalse(sut.state.expanded)
        let requestCount = await provider.count
        XCTAssertEqual(requestCount, 0)
    }
    func testSettingsChangeInvalidatesInflightRequest() async {
        var initialSettings = AppSettings(); initialSettings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider()
        let sut = RewriteCoordinator(settings: initialSettings, source: input, replacer: input, provider: provider)
        sut.shortcut(); await eventually { await provider.count == 1 }
        var settings = AppSettings(); settings.mode = .silent
        sut.configure(settings, provider: provider); await provider.complete("old settings result")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(sut.state.phase, .hidden); XCTAssertTrue(input.replacements.isEmpty)
    }
    func testExternalCompatibilityCaptureFailureIsPresentedWithoutCallingProvider() async {
        var settings = AppSettings(); settings.mode = .manual
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: settings, source: input, replacer: input, provider: provider, clock: clock)
        var diagnostics: [(String, [String: String])] = []
        sut.onDiagnostic = { diagnostics.append(($0, $1)) }

        sut.rejectInvocation(SayoError.compatibilitySelectionRequired, trigger: "copy_paste_compatibility")

        XCTAssertEqual(sut.state.phase, .failed)
        XCTAssertTrue(sut.state.expanded)
        XCTAssertEqual(sut.state.presentation, .notice)
        XCTAssertEqual(sut.state.message, SayoError.compatibilitySelectionRequired.message(language: settings.interfaceLanguage))
        XCTAssertEqual(diagnostics.map(\.0), ["invocation_started", "invocation_failed"])
        XCTAssertEqual(diagnostics.first?.1["trigger"], "copy_paste_compatibility")
        let requestCount = await provider.count
        XCTAssertEqual(requestCount, 0)
        await eventually { await clock.count == 1 }
        await clock.advance()
        await eventually { sut.state.phase == .hidden }
    }
    func testGeometryChangeUpdatesManualBubbleWithoutRequest() async {
        let input = MemoryInput(), provider = ControlledProvider(), clock = ControlledClock()
        let sut = RewriteCoordinator(settings: .init(), source: input, replacer: input, provider: provider, clock: clock)
        sut.inputChanged(input.context)
        input.context?.text += "!"; input.context?.selection.location += 1
        sut.inputChanged(input.context)
        input.context?.caret = .init(x: 900, y: 200, width: 1, height: 16)
        sut.inputChanged(input.context)
        let waits = await clock.count; XCTAssertEqual(waits, 0)
        XCTAssertEqual(sut.state.context?.caret?.x, 900)
        let requests = await provider.count; XCTAssertEqual(requests, 0)
    }
}
