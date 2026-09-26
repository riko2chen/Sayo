import Foundation
import SayoCore

/// AX setters acknowledge the message, not completion in the target renderer.
/// Keep every asynchronous step tied to the captured field and original text.
@MainActor
struct TextReplacementTransaction {
    struct State: Equatable {
        var text: String
        var selection: SayoCore.TextRange
    }
    struct Paste {
        var send: () throws -> Void
        var restoreClipboard: () -> Void
    }
    struct Access {
        /// Throws if the captured input is no longer focused or becomes secure.
        var read: () throws -> State
        var select: (SayoCore.TextRange) -> Bool
        var selectAll: () throws -> Void
        var collapseSelectionToEnd: () throws -> Void = { throw SayoError.unsupportedInput }
        var writeSelected: ((String) -> Bool)?
        var writeValue: ((String) -> Bool)?
        var preparePaste: (String) throws -> Paste
        var prefersPaste: Bool
        /// Frontmost keyboard editing is the closest safe approximation to a
        /// text-input client for web editors, which reject direct AX writes.
        var typeText: ((String) throws -> Void)? = nil
    }
    var access: Access
    var allowSelectAllFallback = true
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    var trace: (String, [String: String]) -> Void = { _, _ in }

    private enum AttemptFailure: Error { case unchanged }

    @discardableResult
    func replace(_ replacement: String, snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        trace("transaction_started", ["originalLength": String(snapshot.context.text.utf16.count),
            "replacementLength": String(replacement.utf16.count),
            "targetRange": "\(snapshot.range.location):\(snapshot.range.length)",
            "insertionRange": "\(snapshot.insertionRange.location):\(snapshot.insertionRange.length)",
            "prefersPaste": String(access.prefersPaste), "canWriteSelected": String(access.writeSelected != nil),
            "canWriteValue": String(access.writeValue != nil)])
        guard snapshot.range.isValid(in: snapshot.context.text),
              snapshot.insertionRange.isValid(in: snapshot.context.text) else { throw SayoError.invalidSelection }
        let original = State(text: snapshot.context.text, selection: snapshot.context.selection)
        let selected = State(text: original.text, selection: snapshot.range)
        let initial = try access.read()
        guard initial.text == original.text,
              snapshot.acceptsReplacementSelection(initial.selection)
        else { throw SayoError.staleInput }
        guard snapshot.replacing(with: replacement) != original.text else {
            trace("replacement_noop", [:]); return .replaced
        }
        defer {
            if let current = try? access.read(), current.text == original.text,
               current.selection != original.selection,
               (current.selection == selected.selection || current.selection == snapshot.insertionRange) {
                _ = access.select(original.selection)
            }
        }
        do {
            try await replaceOnly(replacement, snapshot: snapshot)
            return .replaced
        } catch AttemptFailure.unchanged {
            trace("fallback_started", ["reason": "replacement_unchanged"])
            // The target never changed. Never append after a partial write or
            // a transient result, where retrying could duplicate or corrupt text.
        } catch SayoError.unsupportedInput {
            trace("fallback_started", ["reason": "replacement_unsupported"])
        }
        try Task.checkCancellation()
        let current = try access.read()
        guard current.text == original.text,
              current.selection == original.selection || current.selection == selected.selection
        else { throw SayoError.staleInput }
        let insertion = State(text: original.text, selection: snapshot.insertionRange)
        var positioned = current == insertion
        trace("fallback_position", ["alreadyPositioned": String(positioned),
            "targetRange": "\(insertion.selection.location):0"])
        if !positioned, access.select(insertion.selection) {
            positioned = try await waitForSelection(original: current, selected: insertion)
        }
        if !positioned {
            // Right collapses an existing selection without deleting it. It is
            // usable only if that selection ends at the original insertion point.
            let beforeCollapse = try access.read()
            guard beforeCollapse == current,
                  current.selection.length > 0,
                  current.selection.location + current.selection.length == insertion.selection.location
            else { throw SayoError.replacementFailed }
            try access.collapseSelectionToEnd()
            trace("selection_collapse", ["method": "right_arrow"])
            positioned = try await waitForSelection(original: current, selected: insertion)
        }
        guard positioned else { throw SayoError.replacementFailed }
        do {
            try await paste(replacement, at: insertion, expected: snapshot.insertingAtCaret(replacement))
        } catch AttemptFailure.unchanged {
            throw SayoError.replacementFailed
        }
        return .insertedAtCaret
    }

    /// Animates a verified native AXValue write in place. Web and custom
    /// editors deliberately keep the normal, atomic replacement path because
    /// their accessibility values often acknowledge writes they do not apply.
    @discardableResult
    func replaceAnimated(_ replacement: String, snapshot: TextSnapshot) async throws -> TextReplacementOutcome {
        if access.prefersPaste {
            guard let typeText = access.typeText, !replacement.isEmpty else {
                trace("replacement_animation_fallback", ["reason": "keyboard_animation_unavailable"])
                return try await replace(replacement, snapshot: snapshot)
            }
            return try await replaceUsingKeyboardAnimation(
                replacement,
                snapshot: snapshot,
                typeText: typeText
            )
        }
        guard !access.prefersPaste, let write = access.writeValue else {
            trace("replacement_animation_fallback", ["reason": "value_write_unavailable"])
            return try await replace(replacement, snapshot: snapshot)
        }
        guard snapshot.range.isValid(in: snapshot.context.text),
              snapshot.insertionRange.isValid(in: snapshot.context.text)
        else { throw SayoError.invalidSelection }

        let original = State(text: snapshot.context.text, selection: snapshot.context.selection)
        let initial = try access.read()
        guard initial.text == original.text,
              snapshot.acceptsReplacementSelection(initial.selection)
        else { throw SayoError.staleInput }

        let expected = snapshot.replacing(with: replacement)
        guard expected != original.text else {
            trace("replacement_noop", [:])
            return .replaced
        }

        let frames = animationFrames(replacement: replacement, snapshot: snapshot)
        trace("replacement_animation_started", ["frames": String(frames.count)])
        var previous = original.text
        var appliedFrames = 0

        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let current = try access.read()
            guard current.text == previous else {
                trace("replacement_animation_interrupted", ["frame": String(index), "reason": "text_changed"])
                throw SayoError.staleInput
            }

            let accepted = write(frame.text)
            trace("replacement_animation_frame", [
                "frame": String(index + 1),
                "frames": String(frames.count),
                "accepted": String(accepted),
                "length": String(frame.text.utf16.count)
            ])
            guard accepted else {
                if appliedFrames == 0, (try access.read()).text == original.text {
                    trace("replacement_animation_fallback", ["reason": "first_write_rejected"])
                    return try await replace(replacement, snapshot: snapshot)
                }
                throw SayoError.replacementFailed
            }

            let observed = try await waitForAnimatedFrame(expected: frame.text, previous: previous)
            guard observed else {
                if appliedFrames == 0 {
                    trace("replacement_animation_fallback", ["reason": "first_write_unchanged"])
                    return try await replace(replacement, snapshot: snapshot)
                }
                throw SayoError.replacementFailed
            }
            appliedFrames += 1
            previous = frame.text
            _ = access.select(frame.selection)

            if index < frames.count - 1 {
                try await pause()
            }
        }

        // Keep the final result stable briefly, matching the verification used
        // by the atomic path and catching controlled-editor rollbacks.
        try await verifyWrite(expected, original: frames.dropLast().last?.text ?? original.text)
        trace("replacement_animation_finished", ["frames": String(appliedFrames)])
        return .replaced
    }

    /// Web editors commonly expose readable AX text and selection while
    /// ignoring AXValue writes. Select the captured range once, replace it
    /// with the first visible chunk, then deliver the remaining chunks as
    /// frontmost Unicode keyboard input. Every frame is read back before the
    /// next one; an unsupported first event falls back without changing text.
    private func replaceUsingKeyboardAnimation(
        _ replacement: String,
        snapshot: TextSnapshot,
        typeText: (String) throws -> Void
    ) async throws -> TextReplacementOutcome {
        guard snapshot.range.isValid(in: snapshot.context.text),
              snapshot.insertionRange.isValid(in: snapshot.context.text)
        else { throw SayoError.invalidSelection }

        let original = State(text: snapshot.context.text, selection: snapshot.context.selection)
        let initial = try access.read()
        guard initial.text == original.text,
              snapshot.acceptsReplacementSelection(initial.selection)
        else { throw SayoError.staleInput }

        let expected = snapshot.replacing(with: replacement)
        guard expected != original.text else {
            trace("replacement_noop", [:])
            return .replaced
        }

        let source = snapshot.context.text as NSString
        let prefix = source.substring(to: snapshot.range.location)
        let suffix = source.substring(from: snapshot.range.location + snapshot.range.length)
        let replacementCharacters = Array(replacement)
        let steps = min(24, replacementCharacters.count)
        var visibleValues: [String] = []
        for step in 1...steps {
            let count = Int(ceil(Double(replacementCharacters.count * step) / Double(steps)))
            let value = String(replacementCharacters.prefix(count))
            if visibleValues.last != value { visibleValues.append(value) }
        }

        trace("replacement_keyboard_animation_started", ["frames": String(visibleValues.count)])
        var previousText = original.text
        var previousVisible = ""

        for (index, visible) in visibleValues.enumerated() {
            let selection: SayoCore.TextRange
            if index == 0 {
                selection = snapshot.range
            } else {
                selection = .init(location: prefix.utf16.count + previousVisible.utf16.count, length: 0)
            }

            guard try await selectForKeyboardAnimation(selection, expectedText: previousText) else {
                if index == 0 {
                    try await restoreSelectionForFallback(original)
                    trace("replacement_animation_fallback", ["reason": "keyboard_selection_unavailable"])
                    return try await replace(replacement, snapshot: snapshot)
                }
                throw SayoError.replacementFailed
            }

            let chunk = String(visible.dropFirst(previousVisible.count))
            try typeText(chunk)
            let frameText = prefix + visible + suffix
            let observed = try await waitForAnimatedFrame(expected: frameText, previous: previousText)
            guard observed else {
                if index == 0 {
                    try await restoreSelectionForFallback(original)
                    trace("replacement_animation_fallback", ["reason": "keyboard_input_unchanged"])
                    return try await replace(replacement, snapshot: snapshot)
                }
                // Some frameworks accept the first Unicode event but ignore a
                // later one. Finish with one verified paste only while the
                // exact last animated frame is still focused and unchanged.
                try await finishKeyboardAnimationAtomically(
                    replacement,
                    currentText: previousText,
                    currentLength: previousVisible.utf16.count,
                    prefixLength: prefix.utf16.count,
                    expected: expected
                )
                trace("replacement_keyboard_animation_finished", ["frames": String(index), "atomicFinish": "true"])
                return .replaced
            }

            previousText = frameText
            previousVisible = visible
            _ = access.select(.init(location: prefix.utf16.count + visible.utf16.count, length: 0))
            trace("replacement_animation_frame", [
                "frame": String(index + 1),
                "frames": String(visibleValues.count),
                "length": String(frameText.utf16.count),
                "method": "keyboard_unicode"
            ])
            if index < visibleValues.count - 1 { try await pause() }
        }

        try await verifyWrite(expected, original: visibleValues.dropLast().last.map { prefix + $0 + suffix } ?? original.text)
        trace("replacement_keyboard_animation_finished", ["frames": String(visibleValues.count), "atomicFinish": "false"])
        return .replaced
    }

    private func selectForKeyboardAnimation(
        _ selection: SayoCore.TextRange,
        expectedText: String
    ) async throws -> Bool {
        let current = try access.read()
        guard current.text == expectedText, selection.isValid(in: expectedText) else {
            throw SayoError.staleInput
        }
        let selected = State(text: expectedText, selection: selection)
        if current == selected { return true }
        guard access.select(selection) else { return false }
        return try await waitForSelection(original: current, selected: selected)
    }

    private func restoreSelectionForFallback(_ original: State) async throws {
        let current = try access.read()
        guard current.text == original.text else { throw SayoError.staleInput }
        if current.selection == original.selection { return }
        guard access.select(original.selection),
              try await waitForSelection(original: current, selected: original)
        else { throw SayoError.replacementFailed }
    }

    private func finishKeyboardAnimationAtomically(
        _ replacement: String,
        currentText: String,
        currentLength: Int,
        prefixLength: Int,
        expected: String
    ) async throws {
        let range = SayoCore.TextRange(location: prefixLength, length: currentLength)
        guard try await selectForKeyboardAnimation(range, expectedText: currentText) else {
            throw SayoError.replacementFailed
        }
        do {
            try await paste(replacement, at: .init(text: currentText, selection: range), expected: expected)
        } catch AttemptFailure.unchanged {
            throw SayoError.replacementFailed
        }
    }

    private func animationFrames(
        replacement: String,
        snapshot: TextSnapshot
    ) -> [(text: String, selection: SayoCore.TextRange)] {
        let source = snapshot.context.text as NSString
        let prefix = source.substring(to: snapshot.range.location)
        let selected = source.substring(with: snapshot.range.nsRange)
        let suffix = source.substring(from: snapshot.range.location + snapshot.range.length)
        let oldCharacters = Array(selected)
        let newCharacters = Array(replacement)
        var values: [String] = []

        let deletionSteps = min(5, oldCharacters.count)
        if deletionSteps > 0 {
            for step in 1...deletionSteps {
                let removed = Int(ceil(Double(oldCharacters.count * step) / Double(deletionSteps)))
                values.append(prefix + String(oldCharacters.prefix(oldCharacters.count - removed)) + suffix)
            }
        }

        let revealSteps = min(24, newCharacters.count)
        if revealSteps > 0 {
            for step in 1...revealSteps {
                let visible = Int(ceil(Double(newCharacters.count * step) / Double(revealSteps)))
                values.append(prefix + String(newCharacters.prefix(visible)) + suffix)
            }
        }

        let finalText = snapshot.replacing(with: replacement)
        if values.last != finalText { values.append(finalText) }

        var last: String?
        return values.compactMap { value in
            guard value != last else { return nil }
            last = value
            let insertedLength = value.utf16.count - prefix.utf16.count - suffix.utf16.count
            return (value, .init(location: prefix.utf16.count + insertedLength, length: 0))
        }
    }

    private func waitForAnimatedFrame(expected: String, previous: String) async throws -> Bool {
        for attempt in 0..<11 {
            try Task.checkCancellation()
            let current = try access.read()
            if current.text == expected { return true }
            guard current.text == previous else {
                trace("replacement_animation_interrupted", ["reason": "unexpected_text", "actualLength": String(current.text.utf16.count)])
                throw SayoError.staleInput
            }
            if attempt < 10 { try await pause() }
        }
        return false
    }

    private func replaceOnly(_ replacement: String, snapshot: TextSnapshot) async throws {
        let original = State(text: snapshot.context.text, selection: snapshot.context.selection)
        let selected = State(text: original.text, selection: snapshot.range)
        let expected = snapshot.replacing(with: replacement)
        let initial = try access.read()
        guard initial.text == original.text,
              snapshot.acceptsReplacementSelection(initial.selection)
        else { throw SayoError.staleInput }
        var selectionReady = initial == selected
        if !selectionReady {
            let accepted = access.select(snapshot.range)
            trace("selection_requested", ["method": "accessibility", "accepted": String(accepted)])
            if accepted {
                selectionReady = try await waitForSelection(original: initial, selected: selected)
            }
        }
        if !selectionReady && allowSelectAllFallback
            && access.prefersPaste && snapshot.range == SayoCore.TextRange(location: 0, length: original.text.utf16.count) {
            // A full-field keyboard selection is allowed only for entire-input
            // scope. Read back the exact range before sending any replacement.
            guard try access.read() == initial else { throw SayoError.staleInput }
            try access.selectAll()
            trace("selection_requested", ["method": "select_all_shortcut", "accepted": "true"])
            selectionReady = try await waitForSelection(original: initial, selected: selected)
        }

        if !access.prefersPaste {
            if selectionReady, let write = access.writeSelected {
                try require(selected)
                let accepted = write(replacement)
                trace("direct_write", ["method": "selected_text", "accepted": String(accepted)])
                if accepted {
                    do {
                        try await verifyWrite(expected, original: original.text)
                        return
                    } catch AttemptFailure.unchanged {
                        // AX only acknowledges delivery of the setter. Some
                        // contenteditables return success while ignoring it.
                        // Keep the verified original selection and retry there
                        // with a normal paste before considering caret insertion.
                        trace("direct_write_unchanged", ["method": "selected_text"])
                    }
                }
            }
            if let write = access.writeValue {
                try require(selectionReady ? selected : original)
                let accepted = write(expected)
                trace("direct_write", ["method": "entire_value", "accepted": String(accepted)])
                if accepted {
                    do {
                        try await verifyWrite(expected, original: original.text)
                        return
                    } catch AttemptFailure.unchanged {
                        trace("direct_write_unchanged", ["method": "entire_value"])
                    }
                }
            }
        }

        guard selectionReady else {
            trace("selection_unavailable", [:]); throw SayoError.unsupportedInput
        }
        try await paste(replacement, at: selected, expected: expected)
    }

    private func paste(_ replacement: String, at selected: State, expected: String) async throws {
        try require(selected)
        let paste = try access.preparePaste(replacement)
        trace("clipboard_prepared", [:])
        defer { paste.restoreClipboard(); trace("clipboard_restore_attempted", [:]) }
        try require(selected)
        try paste.send()
        trace("paste_sent", ["targetRange": "\(selected.selection.location):\(selected.selection.length)"])
        try await verifyWrite(expected, original: selected.text)
    }

    private func require(_ state: State) throws {
        try Task.checkCancellation()
        guard try access.read() == state else { throw SayoError.staleInput }
    }

    private func waitForSelection(original: State, selected: State) async throws -> Bool {
        for attempt in 0..<26 {
            try Task.checkCancellation()
            let current = try access.read()
            if current == selected {
                trace("selection_verified", ["samples": String(attempt + 1), "range": "\(current.selection.location):\(current.selection.length)"])
                return true
            }
            guard current == original else {
                trace("selection_changed_unexpectedly", ["range": "\(current.selection.location):\(current.selection.length)"])
                throw SayoError.staleInput
            }
            if attempt < 25 { try await pause() }
        }
        trace("selection_timeout", ["samples": "26", "actualRange": "\(original.selection.location):\(original.selection.length)",
            "targetRange": "\(selected.selection.location):\(selected.selection.length)"])
        return false
    }

    private func verifyWrite(_ expected: String, original: String) async throws {
        var stableSamples = 0
        var observedResult = false
        for attempt in 0..<51 {
            try Task.checkCancellation()
            let current = try access.read()
            if current.text == expected {
                observedResult = true
                stableSamples += 1
                // Allow controlled editors to render before reporting success.
                if stableSamples >= 7 {
                    trace("write_verified", ["samples": String(attempt + 1), "stableSamples": "7", "expectedLength": String(expected.utf16.count)])
                    return
                }
            } else {
                guard current.text == original, !observedResult else {
                    trace("write_changed_unexpectedly", ["actualLength": String(current.text.utf16.count),
                        "expectedLength": String(expected.utf16.count), "revertedAfterResult": String(observedResult)])
                    throw SayoError.replacementFailed
                }
                stableSamples = 0
            }
            if attempt < 50 { try await pause() }
        }
        trace("write_unchanged", ["samples": "51", "originalLength": String(original.utf16.count)])
        throw AttemptFailure.unchanged
    }
}
