//
//  FocusedTextFieldInspector.swift
//  Pindrop
//
//  Created on 2026-09-09.
//

import AppKit
import ApplicationServices
import Foundation

/// Whether the frontmost app currently has an editable text destination focused.
///
/// `.unknown` is deliberately distinct from `.notEditable`: Accessibility can be
/// unavailable, denied, or simply silent about an element, and in that case the
/// caller must keep its previous paste behavior rather than swallow the transcript.
enum FocusedTextFieldState: Equatable {
    /// An editable text destination is focused; pasting will land in it.
    case editable
    /// The focused element positively reports as a non-text control.
    case notEditable
    /// Accessibility could not answer; callers should assume the paste is fine.
    case unknown
}

@MainActor
protocol FocusedTextFieldInspecting: AnyObject {
    func focusedTextFieldState() -> FocusedTextFieldState
}

/// Reads the focused AX element of the frontmost app and classifies it as an
/// editable text destination or not.
///
/// Classification is intentionally biased toward `.editable`: a false `.notEditable`
/// would divert a transcript away from the field the user was dictating into, which
/// is far worse than a paste that lands nowhere. Only elements that give a positive
/// non-text signal are reported as `.notEditable`.
@MainActor
final class SystemFocusedTextFieldInspector: FocusedTextFieldInspecting {

    /// Roles that always accept typed text.
    static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
        "AXWebArea",
    ]

    /// Roles that are positively not text destinations. Container roles such as
    /// `AXGroup` or `AXScrollArea` are absent on purpose — web and Electron apps
    /// routinely focus a container that still forwards keystrokes to an editor.
    static let nonEditableRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXMenu",
        "AXMenuItem",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXSlider",
        "AXIncrementor",
        "AXStepper",
        "AXImage",
        "AXProgressIndicator",
        "AXStaticText",
        "AXLink",
        "AXTable",
        "AXOutline",
        "AXList",
        "AXRow",
        "AXColumn",
        "AXTabGroup",
        "AXToolbar",
        "AXDisclosureTriangle",
        "AXSegmentedControl",
    ]

    private let isProcessTrusted: () -> Bool
    private let frontmostApplicationElement: () -> AXUIElement?
    private let attributeReader: (String, AXUIElement) -> AnyObject?
    private let settabilityReader: (String, AXUIElement) -> Bool

    nonisolated init(
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostApplicationElement: @escaping () -> AXUIElement? = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return AXUIElementCreateApplication(app.processIdentifier)
        },
        attributeReader: @escaping (String, AXUIElement) -> AnyObject? = { attribute, element in
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
                return nil
            }
            return value
        },
        settabilityReader: @escaping (String, AXUIElement) -> Bool = { attribute, element in
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
                return false
            }
            return settable.boolValue
        }
    ) {
        self.isProcessTrusted = isProcessTrusted
        self.frontmostApplicationElement = frontmostApplicationElement
        self.attributeReader = attributeReader
        self.settabilityReader = settabilityReader
    }

    func focusedTextFieldState() -> FocusedTextFieldState {
        guard isProcessTrusted() else { return .unknown }
        guard let appElement = frontmostApplicationElement() else { return .unknown }
        guard let focusedElement = element(kAXFocusedUIElementAttribute, of: appElement) else {
            return .unknown
        }
        return Self.classify(
            role: string(kAXRoleAttribute, of: focusedElement),
            subrole: string(kAXSubroleAttribute, of: focusedElement),
            hasSelectedTextRange: attributeReader(kAXSelectedTextRangeAttribute as String, focusedElement) != nil,
            isValueSettable: settabilityReader(kAXValueAttribute as String, focusedElement)
        )
    }

    /// Pure classification so the decision table can be tested without AX.
    nonisolated static func classify(
        role: String?,
        subrole: String?,
        hasSelectedTextRange: Bool,
        isValueSettable: Bool
    ) -> FocusedTextFieldState {
        // Secure fields accept text, but Pindrop must never dictate into them.
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" {
            return .notEditable
        }

        if let role, editableRoles.contains(role) {
            return .editable
        }

        // A caret (selected text range) or a writable value is the strongest
        // generic signal for custom editors that report an unfamiliar role.
        if hasSelectedTextRange || isValueSettable {
            return .editable
        }

        if let role, nonEditableRoles.contains(role) {
            return .notEditable
        }

        return .unknown
    }

    private func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeReader(attribute, element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ attribute: String, of element: AXUIElement) -> String? {
        attributeReader(attribute, element) as? String
    }
}
