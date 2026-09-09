//
//  FocusedTextFieldInspectorTests.swift
//  PindropTests
//
//  Created on 2026-09-09.
//

import AppKit
import Foundation
import Testing
@testable import Pindrop

@MainActor
private final class StubFocusedTextFieldInspector: FocusedTextFieldInspecting {
    var state: FocusedTextFieldState
    private(set) var callCount = 0

    init(state: FocusedTextFieldState) {
        self.state = state
    }

    func focusedTextFieldState() -> FocusedTextFieldState {
        callCount += 1
        return state
    }
}

@Suite struct FocusedTextFieldClassificationTests {
    @Test func knownTextRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"] {
            #expect(
                SystemFocusedTextFieldInspector.classify(
                    role: role,
                    subrole: nil,
                    hasSelectedTextRange: false,
                    isValueSettable: false
                ) == .editable
            )
        }
    }

    @Test func secureFieldsAreNeverDictationTargets() {
        #expect(
            SystemFocusedTextFieldInspector.classify(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                hasSelectedTextRange: true,
                isValueSettable: true
            ) == .notEditable
        )
    }

    @Test func controlsWithoutTextAreNotEditable() {
        #expect(
            SystemFocusedTextFieldInspector.classify(
                role: "AXButton",
                subrole: nil,
                hasSelectedTextRange: false,
                isValueSettable: false
            ) == .notEditable
        )
    }

    // A custom editor may report an unfamiliar role; a caret or a writable value is
    // enough to treat it as a text destination.
    @Test func caretOrWritableValueOutweighsAnUnfamiliarRole() {
        #expect(
            SystemFocusedTextFieldInspector.classify(
                role: "AXUnknownEditor",
                subrole: nil,
                hasSelectedTextRange: true,
                isValueSettable: false
            ) == .editable
        )
        #expect(
            SystemFocusedTextFieldInspector.classify(
                role: "AXUnknownEditor",
                subrole: nil,
                hasSelectedTextRange: false,
                isValueSettable: true
            ) == .editable
        )
    }

    // Containers like AXGroup routinely forward keystrokes to a real editor, so an
    // unrecognized role must stay `.unknown` rather than divert the transcript.
    @Test func unrecognizedRolesStayUnknown() {
        #expect(
            SystemFocusedTextFieldInspector.classify(
                role: "AXGroup",
                subrole: nil,
                hasSelectedTextRange: false,
                isValueSettable: false
            ) == .unknown
        )
        #expect(
            SystemFocusedTextFieldInspector.classify(
                role: nil,
                subrole: nil,
                hasSelectedTextRange: false,
                isValueSettable: false
            ) == .unknown
        )
    }
}

@MainActor
@Suite struct OutputManagerFocusedFieldGateTests {
    private func makeSUT(
        state: FocusedTextFieldState,
        requiresFocusedTextField: Bool = true
    ) -> (outputManager: OutputManager, clipboard: MockClipboard, keySimulation: MockKeySimulation, inspector: StubFocusedTextFieldInspector) {
        let clipboard = MockClipboard()
        let keySimulation = MockKeySimulation()
        let inspector = StubFocusedTextFieldInspector(state: state)
        let outputManager = OutputManager(
            outputMode: .directInsert,
            clipboard: clipboard,
            keySimulation: keySimulation,
            accessibilityPermissionChecker: { true },
            frontmostApplicationProvider: { nil },
            focusedTextFieldInspector: inspector,
            requiresFocusedTextField: requiresFocusedTextField
        )
        return (outputManager, clipboard, keySimulation, inspector)
    }

    @Test func nonTextFocusCopiesInsteadOfPasting() async throws {
        let fixture = makeSUT(state: .notEditable)
        fixture.clipboard.clipboardContent = "previous"

        let result = try await fixture.outputManager.output("Dictated words")

        #expect(result.clipboardFallbackReason == .noFocusedTextField)
        #expect(fixture.keySimulation.pasteSimulated == false)
        #expect(fixture.clipboard.clipboardContent == "Dictated words")

        // The prior pasteboard rides along so the toast can offer Undo.
        let snapshot = try #require(result.previousClipboardSnapshot)
        #expect(fixture.outputManager.restoreClipboardSnapshot(snapshot))
        #expect(fixture.clipboard.clipboardContent == "previous")
    }

    @Test func editableFocusPastesAsBefore() async throws {
        let fixture = makeSUT(state: .editable)

        let result = try await fixture.outputManager.output("Dictated words")

        #expect(result.didPaste)
        #expect(fixture.keySimulation.pasteSimulated)
    }

    // Accessibility that cannot classify the focus must not cost the user a paste.
    @Test func unknownFocusStillPastes() async throws {
        let fixture = makeSUT(state: .unknown)

        let result = try await fixture.outputManager.output("Dictated words")

        #expect(result.didPaste)
        #expect(fixture.keySimulation.pasteSimulated)
    }

    @Test func gateIsSkippedWhenTheSettingIsOff() async throws {
        let fixture = makeSUT(state: .notEditable, requiresFocusedTextField: false)

        let result = try await fixture.outputManager.output("Dictated words")

        #expect(result.didPaste)
        #expect(fixture.inspector.callCount == 0)
    }

    @Test func setRequiresFocusedTextFieldTogglesTheGate() async throws {
        let fixture = makeSUT(state: .notEditable, requiresFocusedTextField: false)
        fixture.outputManager.setRequiresFocusedTextField(true)

        let result = try await fixture.outputManager.output("Dictated words")

        #expect(result.clipboardFallbackReason == .noFocusedTextField)
    }
}
