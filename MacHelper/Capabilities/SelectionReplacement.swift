import AppKit
import ApplicationServices
import MacHelper

/// Literal UTF-16 comparison protects the original selection even when an
/// editor normalizes equivalent Unicode strings into different range lengths.
struct SelectionReplacementEvidence {
    let processIdentifier: Int32
    let range: NSRange
    let text: String

    func accepts(processIdentifier: Int32?, sameFocusedElement: Bool,
                 currentRange: NSRange?, currentText: String?, protected: Bool,
                 settable: Bool, enabled: Bool = true) -> Bool {
        guard processIdentifier == self.processIdentifier, sameFocusedElement,
              !protected, enabled, settable, currentRange == range, let currentText,
              range.location >= 0, range.length > 0, range.length == text.utf16.count else { return false }
        return currentText.utf16.elementsEqual(text.utf16)
    }
}

/// AXValue writability is editable-state evidence only. Its contents are never
/// read or set by this capability; partial selections remain partial pastes.
struct SelectionPasteEditability {
    static func accepts(role: String?, enabled: Bool, protected: Bool, valueSettable: Bool) -> Bool {
        enabled && !protected && valueSettable && [kAXTextFieldRole, kAXTextAreaRole].contains(role ?? "")
    }
}

struct SelectionSourceApplicationIdentity: Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String

    init?(processIdentifier: Int32, bundleIdentifier: String?) {
        guard processIdentifier > 1, let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.processIdentifier = processIdentifier; self.bundleIdentifier = bundleIdentifier
    }

    func matches(processIdentifier: Int32?, bundleIdentifier: String?) -> Bool {
        self.processIdentifier == processIdentifier && self.bundleIdentifier == bundleIdentifier
    }
}

enum SelectionProviderContext: Equatable {
    case web, native, unknown, blocked
}

/// Inspect only roles/protection/parents on the selected control's ancestor
/// chain. No child crawl, titles, URLs, field values or surrounding text.
struct SelectionProviderContextReader<Element> {
    let role: (Element) -> String?
    let parent: (Element) -> Element?
    let isProtected: (Element) -> Bool
    let sameElement: (Element, Element) -> Bool
    let canRead: () -> Bool
    var maximumAncestors = 16

    func read(from origin: Element) -> SelectionProviderContext {
        var current = origin
        var visited: [Element] = []
        for _ in 0..<max(0, min(16, maximumAncestors)) {
            guard canRead() else { return .unknown }
            guard !visited.contains(where: { sameElement($0, current) }) else { return .blocked }
            visited.append(current)
            guard let value = role(current), !value.isEmpty else { return .blocked }
            guard canRead() else { return .unknown }
            let protected = isProtected(current)
            guard canRead() else { return .unknown }
            guard !protected else { return .blocked }
            if value == "AXWebArea" { return .web }
            if [kAXWindowRole, kAXApplicationRole].contains(value) { return .native }
            guard let ancestor = parent(current) else { return .blocked }
            current = ancestor
        }
        return .unknown
    }
}

enum SelectionReplacementStrategy: Equatable {
    case selectedText, pasteShortcut

    static func choose(bundleIdentifier: String?, providerContext: SelectionProviderContext,
                       directAvailable: Bool, pasteApproved: Bool, pasteEditable: Bool) -> Self? {
        guard let bundleIdentifier, !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Web providers can advertise AXSelectedText without editing renderer
        // state. Classify the control itself, including Electron/webview apps,
        // and select an approved alternative before any write, never after it.
        if providerContext == .web {
            return pasteApproved && pasteEditable ? .pasteShortcut : nil
        }
        if providerContext == .native {
            if directAvailable { return .selectedText }
            return pasteApproved && pasteEditable ? .pasteShortcut : nil
        }
        // A bounded/deadline-limited tree supplies no native setter proof.
        // Independent strict editable-state and target checks can still permit
        // separately approved paste; incomplete routing never authorizes AX writes.
        if providerContext == .unknown {
            return pasteApproved && pasteEditable ? .pasteShortcut : nil
        }
        return nil
    }
}

enum SelectionReplacementOutcome: Equatable {
    case confirmed
    case unverified
    case changedByEditor
    case pasteRequested

    static func verify(expected: String, actual: String?, originalText: String? = nil) -> Self {
        guard let actual else { return .unverified }
        if actual.utf16.elementsEqual(expected.utf16) { return .confirmed }
        if let originalText, actual.utf16.elementsEqual(originalText.utf16) { return .unverified }
        return .changedByEditor
    }
}

/// This memory-only target retains actual focused/source AX objects. An
/// extension cannot access its clipboard or keyboard implementation directly.
@MainActor
final class AccessibilitySelectionEditTarget {
    private let application: AXUIElement
    private let focus: SelectionFocusPath<AXUIElement>
    private let source: AXUIElement
    private let evidence: SelectionReplacementEvidence
    private let sourceIdentity: SelectionSourceApplicationIdentity
    private let strategy: SelectionReplacementStrategy

    private init(application: AXUIElement, focus: SelectionFocusPath<AXUIElement>, source: AXUIElement,
                 evidence: SelectionReplacementEvidence, sourceIdentity: SelectionSourceApplicationIdentity, strategy: SelectionReplacementStrategy) {
        self.application = application; self.focus = focus; self.source = source
        self.evidence = evidence; self.sourceIdentity = sourceIdentity; self.strategy = strategy
    }

    static func capture(_ selection: TextSelection, allowsPaste: Bool = false) -> AccessibilitySelectionEditTarget? {
        let trusted = AXIsProcessTrusted()
        let currentApplication = NSWorkspace.shared.frontmostApplication
        guard trusted, selection.rangeLocation >= 0,
              let sourceApplication = currentApplication,
              sourceApplication.processIdentifier == selection.sourcePID,
              let identity = SelectionSourceApplicationIdentity(processIdentifier: selection.sourcePID, bundleIdentifier: sourceApplication.bundleIdentifier) else { return nil }
        let application = AXUIElementCreateApplication(selection.sourcePID)
        AXUIElementSetMessagingTimeout(application, 0.18)
        guard let focus = AccessibilityFocusResolver.read(application: application) else { return nil }
        var source = focus.leaf
        let classificationDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        for _ in 0..<4 {
            AXUIElementSetMessagingTimeout(source, 0.18)
            guard !isProtected(source) else {
                return nil
            }
            let text = attribute(kAXSelectedTextAttribute, of: source) as? String
            let range = selectedRange(source)
            let selectionMatches = text?.utf16.elementsEqual(selection.text.utf16) == true
            if let text, selectionMatches, let range,
               range == NSRange(location: selection.rangeLocation, length: selection.rangeLength) {
                let context = providerContext(of: source, deadline: classificationDeadline)
                let directAvailable = isSettable(kAXSelectedTextAttribute, in: source) && !isDisabled(source)
                let pasteEditable = canPaste(source)
                if let strategy = SelectionReplacementStrategy.choose(bundleIdentifier: identity.bundleIdentifier,
                    providerContext: context, directAvailable: directAvailable,
                    pasteApproved: allowsPaste, pasteEditable: pasteEditable) {
                    let target = AccessibilitySelectionEditTarget(application: application, focus: focus, source: source,
                        evidence: .init(processIdentifier: selection.sourcePID, range: range, text: text), sourceIdentity: identity, strategy: strategy)
                    let current = target.isCurrent
                    if current { return target }
                } else {
                }
            } else {
            }
            guard let parent = attribute(kAXParentAttribute, of: source),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return nil
            }
            source = parent as! AXUIElement
        }
        return nil
    }

    var isCurrent: Bool {
        guard AXIsProcessTrusted(), let currentApplication = NSWorkspace.shared.frontmostApplication,
              sourceIdentity.matches(processIdentifier: currentApplication.processIdentifier, bundleIdentifier: currentApplication.bundleIdentifier) else { return false }
        let writable = strategy == .selectedText ? Self.isSettable(kAXSelectedTextAttribute, in: source) : Self.canPaste(source)
        return evidence.accepts(processIdentifier: currentApplication.processIdentifier,
            sameFocusedElement: AccessibilityFocusResolver.matches(focus, application: application),
            currentRange: Self.selectedRange(source),
            currentText: Self.attribute(kAXSelectedTextAttribute, of: source) as? String,
            protected: Self.protectedChain(focus.leaf), settable: writable, enabled: !Self.isDisabled(source))
    }

    func replace(with text: String, validateInvocation: () -> Bool = { true }) throws -> SelectionReplacementOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 96_000, !text.contains("\0"),
              evidence.range.location <= Int.max - text.utf16.count, validateInvocation(), isCurrent else {
            throw CapabilityError.invalid(L("The original selection changed. Select the text again, or use Copy."))
        }
        if strategy == .pasteShortcut {
            let transaction = SelectionPasteTransaction(pasteboard: SystemSelectionPasteboard(), eventPoster: SystemSelectionPasteEventPoster())
            try transaction.perform(text: text, sourcePID: evidence.processIdentifier) { validateInvocation() && self.isCurrent }
            return .pasteRequested
        }
        // Prefer one direct selected-text setter. A failure never starts an
        // automatic paste fallback, and no entire-field value is rewritten.
        guard validateInvocation(), isCurrent else {
            throw CapabilityError.invalid(L("The original selection changed. Select the text again, or use Copy."))
        }
        guard AXUIElementSetAttributeValue(source, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw CapabilityError.invalid(L("This app could not replace the selected text. Use Copy instead."))
        }
        guard validateInvocation(), AXIsProcessTrusted(), !Self.protectedChain(focus.leaf),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == evidence.processIdentifier,
              AccessibilityFocusResolver.matches(focus, application: application) else {
            return .unverified
        }
        var range = CFRange(location: evidence.range.location, length: text.utf16.count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return .unverified }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(source,
            kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        return .verify(expected: text, actual: status == .success ? value as? String : nil, originalText: evidence.text)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: -1, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func isSettable(_ name: String, in element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func canPaste(_ element: AXUIElement) -> Bool {
        SelectionPasteEditability.accepts(role: attribute(kAXRoleAttribute, of: element) as? String,
            enabled: attribute(kAXEnabledAttribute, of: element) as? Bool == true,
            protected: isProtected(element), valueSettable: isSettable(kAXValueAttribute, in: element))
    }

    private static func providerContext(of source: AXUIElement, deadline: TimeInterval) -> SelectionProviderContext {
        SelectionProviderContextReader<AXUIElement>(
            role: { element in
                AXUIElementSetMessagingTimeout(element, 0.10)
                return attribute(kAXRoleAttribute, of: element) as? String
            }, parent: { element in
                guard let parent = attribute(kAXParentAttribute, of: element), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                return (parent as! AXUIElement)
            }, isProtected: isProtected, sameElement: { CFEqual($0, $1) },
            canRead: { ProcessInfo.processInfo.systemUptime < deadline })
            .read(from: source)
    }


    private static func isDisabled(_ element: AXUIElement) -> Bool { attribute(kAXEnabledAttribute, of: element) as? Bool == false }
    private static func isProtected(_ element: AXUIElement) -> Bool {
        (attribute(kAXSubroleAttribute, of: element) as? String) == kAXSecureTextFieldSubrole ||
            (attribute("AXProtectedContent", of: element) as? Bool) == true
    }
    private static func protectedChain(_ focused: AXUIElement) -> Bool {
        var element = focused
        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(element, 0.18)
            if isProtected(element) { return true }
            guard let parent = attribute(kAXParentAttribute, of: element), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = parent as! AXUIElement
        }
        return false
    }
}
