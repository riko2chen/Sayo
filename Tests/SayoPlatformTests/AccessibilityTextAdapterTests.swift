import XCTest
@testable import SayoPlatform

@MainActor
final class AccessibilityTextAdapterTests: XCTestCase {
    func testDOMMetadataIdentifiesDetachedChromiumContenteditable() {
        XCTAssertTrue(AccessibilityTextAdapter.hasWebTextInputMetadata(
            domClasses: ["ProseMirror", "ProseMirror-focused"],
            domIdentifier: nil
        ))
        XCTAssertTrue(AccessibilityTextAdapter.hasWebTextInputMetadata(
            domClasses: [],
            domIdentifier: nil
        ))
        XCTAssertTrue(AccessibilityTextAdapter.hasWebTextInputMetadata(
            domClasses: nil,
            domIdentifier: "composer"
        ))
        XCTAssertFalse(AccessibilityTextAdapter.hasWebTextInputMetadata(
            domClasses: nil,
            domIdentifier: nil
        ))
    }

    func testContainedPlaceholderIsFilteredThroughInclusiveDoubleLengthBoundary() {
        for value in ["hint", "\nhint", "xxhintxx", "hinthint"] {
            let resolved = AccessibilityTextAdapter.resolveAccessibleText(
                value: value, placeholder: "hint", characterCount: value.utf16.count,
                selection: .init(location: value.utf16.count, length: 0)
            )
            XCTAssertEqual(resolved.text, "", value)
            XCTAssertEqual(resolved.selection, .init(location: 0, length: 0))
            XCTAssertTrue(resolved.placeholderContainmentMatch)
        }
    }

    func testContainedPlaceholderAboveDoubleLengthIsPreserved() {
        let value = "xxhintxxx"
        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: value, placeholder: "hint", characterCount: 9,
            selection: .init(location: 9, length: 0)
        )
        XCTAssertEqual(resolved.text, value)
        XCTAssertEqual(resolved.selection, .init(location: 9, length: 0))
        XCTAssertFalse(resolved.rawValueIsPlaceholder)
        XCTAssertFalse(resolved.placeholderContainmentMatch)
    }

    func testMissingEmptyOrNonmatchingPlaceholderDoesNotMatchLengthRule() {
        for placeholder in [nil, "", "HINT", "other"] as [String?] {
            XCTAssertFalse(AccessibilityTextAdapter.matchesPlaceholderLengthRule(value: "hint", placeholder: placeholder))
        }
        XCTAssertFalse(AccessibilityTextAdapter.matchesPlaceholderLengthRule(value: "", placeholder: "hint"))
    }

    func testLengthRuleUsesAXUTF16UnitsForChineseAndEmoji() {
        let placeholder = "想法😀" // Four UTF-16 units.
        XCTAssertTrue(AccessibilityTextAdapter.matchesPlaceholderLengthRule(value: placeholder + "1234", placeholder: placeholder))
        XCTAssertFalse(AccessibilityTextAdapter.matchesPlaceholderLengthRule(value: placeholder + "12345", placeholder: placeholder))
    }

    func testMarkedPlaceholderWithLeadingNewlineWorksWithoutWebArea() {
        XCTAssertTrue(AccessibilityTextAdapter.isPlaceholderDecoration(classes: ["placeholder"]))
        XCTAssertTrue(AccessibilityTextAdapter.isPlaceholderDecoration(classes: ["is-empty", "is-editor-empty"]))
        XCTAssertFalse(AccessibilityTextAdapter.isPlaceholderDecoration(classes: ["ProseMirror"]))
        XCTAssertFalse(AccessibilityTextAdapter.isPlaceholderDecoration(classes: ["is-empty"]))
        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: "\nDo anything", placeholder: "Do anything", characterCount: 12,
            isWebTextInput: false
        )
        XCTAssertEqual(resolved.text, "")
        XCTAssertTrue(resolved.placeholderContainmentMatch)
    }

    func testPlaceholderExposedAsValueIsEmptyWhenCharacterCountIsZero() {
        XCTAssertEqual(
            AccessibilityTextAdapter.resolveAccessibleText(
                value: "Do whatever you want",
                placeholder: "Do whatever you want",
                characterCount: 0
            ).text,
            ""
        )
    }

    func testExactPlaceholderMatchIsFilteredEvenWithNonzeroCharacterCount() {
        let text = "Do whatever you want"
        XCTAssertEqual(
            AccessibilityTextAdapter.resolveAccessibleText(
                value: text,
                placeholder: text,
                characterCount: text.utf16.count
            ).text,
            ""
        )
    }

    func testWebPlaceholderIsEmptyWhenCharacterCountIsUnavailableAfterDeletion() {
        let text = "Do whatever you want"
        XCTAssertEqual(
            AccessibilityTextAdapter.resolveAccessibleText(
                value: text,
                placeholder: text,
                characterCount: nil,
                selection: .init(location: 0, length: 0),
                isWebTextInput: true
            ).text,
            ""
        )
    }

    func testLengthRuleAlsoAppliesOutsideWebInputs() {
        let text = "Do whatever you want"
        XCTAssertEqual(
            AccessibilityTextAdapter.resolveAccessibleText(
                value: text,
                placeholder: text,
                characterCount: nil,
                selection: .init(location: 0, length: 0),
                isWebTextInput: false
            ).text,
            ""
        )
    }

    func testLengthRuleAlsoAppliesWhenCaretIsAtEnd() {
        let text = "Do whatever you want"
        XCTAssertEqual(
            AccessibilityTextAdapter.resolveAccessibleText(
                value: text,
                placeholder: text,
                characterCount: nil,
                selection: .init(location: text.utf16.count, length: 0),
                isWebTextInput: true
            ).text,
            ""
        )
    }

    func testNestedWebPlaceholderEvidenceWinsOverIncorrectCharacterCount() {
        let text = "Do whatever you want"
        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: text,
            placeholder: text,
            characterCount: text.utf16.count,
            selection: .init(location: 0, length: 0),
            isWebTextInput: true,
            webPlaceholderEvidence: true
        )

        XCTAssertEqual(resolved.text, "")
        XCTAssertEqual(resolved.selection, .init(location: 0, length: 0))
        XCTAssertTrue(resolved.rawValueIsPlaceholder)
    }

    func testFlomoPlaceholderWithBlockEndingNewlineIsFilteredAfterClearing() {
        let staticText = "现在的想法是..."
        let value = staticText + "\n"
        let evidence = AccessibilityTextAdapter.webValue(value, matchesStaticText: staticText)
            && AccessibilityTextAdapter.canContainWebPlaceholder(
                editorClasses: ["tiptap", "ProseMirror", "ProseMirror-focused"],
                childClasses: ["is-empty", "is-editor-empty"]
            )
        XCTAssertTrue(evidence)

        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: value,
            placeholder: evidence ? value : nil,
            characterCount: 10,
            selection: .init(location: 0, length: 0),
            isWebTextInput: true,
            webPlaceholderEvidence: evidence
        )
        XCTAssertEqual(resolved.text, "")
        XCTAssertTrue(resolved.rawValueIsPlaceholder)
    }

    func testDirectRealWebTextWithBlockEndingNewlineStillVetoesPlaceholderInference() {
        // The direct-child check must recognize the same representation difference
        // as the nested-placeholder check, including at the beginning of real text.
        let text = "现在的想法是..."
        XCTAssertTrue(AccessibilityTextAdapter.webValue(text + "\n", matchesStaticText: text))
        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: text + "\n",
            placeholder: nil,
            characterCount: 10,
            selection: .init(location: 0, length: 0),
            isWebTextInput: true,
            webPlaceholderEvidence: false
        )
        XCTAssertEqual(resolved.text, text + "\n")
        XCTAssertFalse(resolved.rawValueIsPlaceholder)
    }

    func testWebStaticTextComparisonPreservesMeaningfulWhitespaceAndOtherContent() {
        let text = "现在的想法是..."
        XCTAssertTrue(AccessibilityTextAdapter.webValue(text, matchesStaticText: text))
        for value in [" " + text, text + " ", text + "\n\n", text + "\n正文"] {
            XCTAssertFalse(AccessibilityTextAdapter.webValue(value, matchesStaticText: text))
        }
        XCTAssertFalse(AccessibilityTextAdapter.webValue("\n", matchesStaticText: ""))
        XCTAssertFalse(AccessibilityTextAdapter.webValue(text, matchesStaticText: nil))
    }

    func testFlomoRealParagraphAtStartIsNotPlaceholderEvenWhenTextMatches() {
        let text = "现在的想法是..."
        for childClasses in [[], ["is-empty"], ["is-editor-empty"]] {
            let evidence = AccessibilityTextAdapter.canContainWebPlaceholder(
                editorClasses: ["tiptap", "ProseMirror", "ProseMirror-focused"],
                childClasses: childClasses
            )
            XCTAssertFalse(evidence)
            let resolved = AccessibilityTextAdapter.resolveAccessibleText(
                value: text,
                placeholder: evidence ? text : nil,
                characterCount: 9,
                selection: .init(location: 0, length: 0),
                isWebTextInput: true,
                webPlaceholderEvidence: evidence
            )
            XCTAssertEqual(resolved.text, text)
            XCTAssertFalse(resolved.rawValueIsPlaceholder)
        }
    }

    func testPlaceholderMetadataStaysAtAccessibilityBoundary() {
        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: "Whatever you want",
            placeholder: "Whatever you want",
            characterCount: 0,
            selection: .init(location: 17, length: 0),
            isWebTextInput: true
        )

        XCTAssertEqual(resolved.text, "")
        XCTAssertEqual(resolved.selection, .init(location: 0, length: 0))
        XCTAssertEqual(resolved.placeholder, "Whatever you want")
        XCTAssertTrue(resolved.rawValueIsPlaceholder)
    }

    func testRealTextNeverGetsMarkedAsPlaceholderMetadata() {
        let resolved = AccessibilityTextAdapter.resolveAccessibleText(
            value: "Actual text",
            placeholder: "Whatever you want",
            characterCount: 11,
            selection: .init(location: 11, length: 0),
            isWebTextInput: true
        )

        XCTAssertEqual(resolved.text, "Actual text")
        XCTAssertEqual(resolved.selection, .init(location: 11, length: 0))
        XCTAssertEqual(resolved.placeholder, "Whatever you want")
        XCTAssertFalse(resolved.rawValueIsPlaceholder)
    }

    func testDifferentPlaceholderNeverChangesValue() {
        XCTAssertEqual(
            AccessibilityTextAdapter.resolveAccessibleText(
                value: "Actual text",
                placeholder: "Do whatever you want",
                characterCount: 0
            ).text,
            "Actual text"
        )
    }
}
