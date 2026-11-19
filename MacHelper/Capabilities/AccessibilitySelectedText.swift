import Foundation
import ApplicationServices

struct SelectedTextSpan: Equatable {
    let text: String
    /// A nil range has selected-marker proof and remains read-only evidence.
    let range: NSRange?
}

enum SelectedTextReadResult: Equatable {
    case selected(SelectedTextSpan)
    case empty
    case unavailable
}

enum SelectedTextAttributeRead {
    case text(String)
    case missing
    case invalid
}

enum SelectedNumericRangeRead: Equatable {
    case value(NSRange)
    case missing
    case invalid
}

/// Reads only a control's own selected span. Injected operations keep changing
/// AX providers, deadlines and malformed ranges testable without accessing apps.
struct SelectionSpanReader {
    let selectedText: () -> SelectedTextAttributeRead
    let numericRange: () -> SelectedNumericRangeRead
    let stringForRange: (NSRange) -> String?
    let isProtected: () -> Bool
    let canRead: () -> Bool
    /// Only a provider with no numeric range may supply a separately verified
    /// selected-marker span. This never expands to an enclosing paragraph.
    var markerText: (String?) -> String? = { _ in nil }

    static func validRange(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
            range.length <= 96_000 && range.location <= Int.max - range.length
    }

    static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            text.count <= 24_000 && text.utf8.count <= 96_000 && !text.contains("\0")
    }

    func read() -> SelectedTextReadResult {
        guard permitted() else { return .unavailable }
        let firstRange = numericRange()
        guard canRead() else { return .unavailable }
        switch firstRange {
        case .invalid: return .unavailable
        case .value(let range):
            guard Self.validRange(range) else { return .unavailable }
            // An explicit caret always wins over stale selected text/markers.
            guard range.length > 0 else { return .empty }
        case .missing: break
        }
        let firstText = selectedText()
        guard canRead() else { return .unavailable }
        let range: NSRange?
        switch firstRange {
        case .value(let value): range = value
        case .missing: range = nil
        case .invalid: return .unavailable
        }
        guard let text = resolve(firstText, range: range) else {
            if range == nil, case .text(let value) = firstText, value.isEmpty { return .empty }
            return .unavailable
        }
        guard permitted(), numericRange() == firstRange, canRead() else { return .unavailable }
        let repeatedText = selectedText()
        guard canRead(), let repeated = resolve(repeatedText, range: range),
              repeated.utf16.elementsEqual(text.utf16), permitted(),
              numericRange() == firstRange, permitted() else { return .unavailable }
        return .selected(.init(text: text, range: range))
    }

    private func resolve(_ value: SelectedTextAttributeRead, range: NSRange?) -> String? {
        let text: String
        switch value {
        case .invalid: return nil
        case .text(let direct) where !direct.isEmpty:
            if range == nil {
                guard Self.validText(direct), permitted(), let selected = markerText(direct), canRead(),
                      selected.utf16.elementsEqual(direct.utf16) else { return nil }
                return selected
            }
            text = direct
        case .missing, .text:
            if range == nil {
                guard permitted(), let selected = markerText(nil), canRead(),
                      Self.validText(selected) else { return nil }
                return selected
            }
            // No document/value read: this parameter is exactly the separately
            // verified, bounded, positive numeric selection on this element.
            guard let range, Self.validRange(range), range.length > 0,
                  permitted(), let selected = stringForRange(range), canRead() else { return nil }
            text = selected
        }
        guard Self.validText(text), range.map({ $0.length == text.utf16.count }) ?? true else { return nil }
        return text
    }

    private func permitted() -> Bool {
        guard canRead() else { return false }
        let protected = isProtected()
        return canRead() && !protected
    }
}

enum AccessibilitySelectedText {
    static func read(_ element: AXUIElement, continuing: () -> Bool = { true }) -> SelectedTextReadResult {
        withoutActuallyEscaping(continuing) { continuing in
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            let canRead = { continuing() && ProcessInfo.processInfo.systemUptime < deadline }
            AXUIElementSetMessagingTimeout(element, 0.10)
            return SelectionSpanReader(selectedText: { textAttribute(element) },
                numericRange: { rangeAttribute(element, continuing: canRead) },
                stringForRange: { range in string(in: element, range: range, continuing: canRead) },
                isProtected: { isProtected(element) }, canRead: canRead,
                markerText: { markerText(in: element, expectedText: $0, continuing: canRead) }).read()
        }
    }

    static func numericRange(of element: AXUIElement, continuing: () -> Bool = { true }) -> NSRange? {
        guard continuing() else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.10)
        guard case .value(let range) = rangeAttribute(element, continuing: continuing),
              continuing(), SelectionSpanReader.validRange(range), range.length > 0 else { return nil }
        return range
    }

    /// Copy capture distinguishes absent selection attributes from an explicit
    /// caret or malformed range; absence is not permission to edit.
    static func rangeEvidence(of element: AXUIElement, continuing: () -> Bool,
                              onTimeout: () -> Void = {}) -> SelectedNumericRangeRead {
        rangeAttribute(element, continuing: continuing, onTimeout: onTimeout)
    }

    /// Singular range errors cannot silently become plural range evidence.
    /// Only an absent/unsupported singular attribute permits the plural probe.
    static func decodeRange(singular: AccessibilityAttributeRead,
                            plural: () -> AccessibilityAttributeRead) -> SelectedNumericRangeRead {
        switch singular {
        case .value(let value): return decodeOneRange(value)
        case .invalid: return .invalid
        case .missing:
            switch plural() {
            case .missing: return .missing
            case .invalid: return .invalid
            case .value(let value):
                guard CFGetTypeID(value) == CFArrayGetTypeID(),
                      let ranges = value as? [AnyObject], ranges.count == 1 else { return .invalid }
                return decodeOneRange(ranges[0])
            }
        }
    }

    private static func decodeOneRange(_ value: CFTypeRef) -> SelectedNumericRangeRead {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return .invalid }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return .invalid }
        var range = CFRange(location: -1, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return .invalid }
        let result = NSRange(location: range.location, length: range.length)
        return SelectionSpanReader.validRange(result) ? .value(result) : .invalid
    }

    private static func rangeAttribute(_ element: AXUIElement, continuing: () -> Bool,
                                       onTimeout: () -> Void = {}) -> SelectedNumericRangeRead {
        guard continuing() else { return .invalid }
        let singular = attribute(kAXSelectedTextRangeAttribute, element, onTimeout: onTimeout)
        guard continuing() else { return .invalid }
        let result = decodeRange(singular: singular) {
            guard continuing() else { return .invalid }
            return attribute(kAXSelectedTextRangesAttribute, element, onTimeout: onTimeout)
        }
        return continuing() ? result : .invalid
    }

    private static func textAttribute(_ element: AXUIElement) -> SelectedTextAttributeRead {
        switch attribute(kAXSelectedTextAttribute, element) {
        case .missing: return .missing
        case .invalid: return .invalid
        case .value(let value):
            guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else { return .invalid }
            return .text(text)
        }
    }

    private static func string(in element: AXUIElement, range: NSRange, continuing: () -> Bool) -> String? {
        guard SelectionSpanReader.validRange(range), range.length > 0 else { return nil }
        var selected = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &selected) else { return nil }
        return withoutActuallyEscaping(continuing) { continuing in
            SelectionRangeTextReader(plain: {
                parameterText(kAXStringForRangeParameterizedAttribute, parameter: parameter, element: element, attributed: false)
            }, attributed: {
                parameterText(kAXAttributedStringForRangeParameterizedAttribute, parameter: parameter, element: element, attributed: true)
            }, canRead: continuing).read()
        }
    }

    /// An attributed-string fallback still requests only the independently
    /// proved selected numeric span. A malformed plain response is not absence.
    private static func parameterText(_ name: String, parameter: CFTypeRef, element: AXUIElement,
                                      attributed: Bool) -> SelectedTextAttributeRead {
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value)
        if status == .parameterizedAttributeUnsupported || status == .attributeUnsupported || status == .noValue { return .missing }
        guard status == .success, let value else { return .invalid }
        if attributed {
            guard CFGetTypeID(value) == CFAttributedStringGetTypeID() else { return .invalid }
            return .text(CFAttributedStringGetString((value as! CFAttributedString)) as String)
        }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else { return .invalid }
        return .text(text)
    }

    static func isProtected(_ element: AXUIElement, onTimeout: () -> Void = {}) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.10)
        switch attribute(kAXSubroleAttribute, element, onTimeout: onTimeout) {
        case .invalid: return true
        case .missing: break
        case .value(let value):
            guard CFGetTypeID(value) == CFStringGetTypeID(), let subrole = value as? String else { return true }
            if subrole == kAXSecureTextFieldSubrole { return true }
        }
        switch attribute("AXProtectedContent", element, onTimeout: onTimeout) {
        case .missing: return false
        case .invalid: return true
        case .value(let value):
            guard CFGetTypeID(value) == CFBooleanGetTypeID(), let flag = value as? Bool else { return true }
            return flag
        }
    }

    private static func attribute(_ name: String, _ element: AXUIElement,
                                  onTimeout: () -> Void = {}) -> AccessibilityAttributeRead {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status == .cannotComplete { onTimeout() }
        if status == .attributeUnsupported || status == .noValue { return .missing }
        guard status == .success, let value else { return .invalid }
        return .value(value)
    }
}

enum AccessibilityAttributeRead {
    case value(CFTypeRef)
    case missing
    case invalid
}
