import Foundation
import ApplicationServices

/// Read exactly the provider's selected opaque marker range. Ordering and
/// UTF-16 length are supplied by the provider; no document offsets are guessed.
struct SelectedMarkerTextReader<MarkerRange> {
    let selectedRange: () -> MarkerRange?
    let equalsRange: (MarkerRange, MarkerRange) -> Bool
    let orderedRange: (MarkerRange) -> MarkerRange?
    let length: (MarkerRange) -> Int?
    let string: (MarkerRange) -> String?
    let isProtected: () -> Bool
    let canRead: () -> Bool

    func read(expectedText: String? = nil) -> String? {
        guard permitted(), let snapshot = selectedRange(), permitted(),
              let ordered = orderedRange(snapshot), permitted(),
              let count = length(ordered), count > 0, count <= 96_000,
              current(snapshot), let text = string(ordered), permitted(),
              SelectionSpanReader.validText(text), text.utf16.count == count,
              expectedText.map({ $0.utf16.elementsEqual(text.utf16) }) ?? true,
              current(snapshot), length(ordered) == count, permitted(),
              let repeated = string(ordered), permitted(),
              repeated.utf16.elementsEqual(text.utf16), current(snapshot) else { return nil }
        return text
    }

    private func permitted() -> Bool {
        guard canRead() else { return false }
        let protected = isProtected()
        return canRead() && !protected
    }

    private func current(_ snapshot: MarkerRange) -> Bool {
        guard permitted(), let current = selectedRange(), canRead() else { return false }
        return equalsRange(snapshot, current)
    }
}

/// A missing plain range representation permits the attributed representation
/// of that identical selected range. Malformed or contradictory data does not.
struct SelectionRangeTextReader {
    let plain: () -> SelectedTextAttributeRead
    let attributed: () -> SelectedTextAttributeRead
    let canRead: () -> Bool

    func read() -> String? {
        guard canRead() else { return nil }
        let value = plain()
        guard canRead() else { return nil }
        switch value {
        case .invalid: return nil
        case .text(let text): return text
        case .missing:
            guard canRead() else { return nil }
            let fallback = attributed()
            guard canRead(), case .text(let text) = fallback else { return nil }
            return text
        }
    }
}

extension AccessibilitySelectedText {
    static func markerText(in element: AXUIElement, expectedText: String? = nil,
                           continuing: () -> Bool) -> String? {
        withoutActuallyEscaping(continuing) { continuing in
            AXUIElementSetMessagingTimeout(element, 0.10)
            func range(_ value: CFTypeRef?) -> AXTextMarkerRange? {
                guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
                return (value as! AXTextMarkerRange)
            }
            func parameter(_ name: String, _ value: CFTypeRef) -> CFTypeRef? {
                guard continuing() else { return nil }
                var result: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success,
                      continuing() else { return nil }
                return result
            }
            return SelectedMarkerTextReader<AXTextMarkerRange>(selectedRange: {
                guard continuing() else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success,
                      continuing() else { return nil }
                return range(value)
            }, equalsRange: { CFEqual($0, $1) }, orderedRange: { selected in
                let start = AXTextMarkerRangeCopyStartMarker(selected)
                let end = AXTextMarkerRangeCopyEndMarker(selected)
                guard !CFEqual(start, end) else { return nil }
                return range(parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray))
            }, length: { selected in
                let value = parameter("AXLengthForTextMarkerRange", selected)
                // CFBoolean also bridges to Int; it is not a valid length.
                guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
                return value as? Int
            }, string: { selected in
                guard let value = parameter("AXStringForTextMarkerRange", selected),
                      CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
                return value as? String
            }, isProtected: { isProtected(element) }, canRead: continuing).read(expectedText: expectedText)
        }
    }
}
