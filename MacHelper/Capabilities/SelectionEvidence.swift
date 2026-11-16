import Foundation

/// Proves a nonempty Accessibility selection without reading surrounding text.
/// A numeric range, when supplied, is authoritative. Browser text markers are
/// accepted only when the provider has no numeric range and their selected
/// length and text agree exactly with AXSelectedText.
enum SelectionEvidence {
    static func isSelected(text: String, numericRange: NSRange?,
                           markerLength: Int? = nil, markerText: String? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 24_000, text.utf8.count <= 96_000,
              !text.contains("\0") else { return false }
        let selectedLength = text.utf16.count
        if let range = numericRange {
            return range.location >= 0 && range.length > 0 &&
                range.length == selectedLength && range.location <= Int.max - range.length
        }
        guard let markerLength, markerLength > 0, markerLength == selectedLength,
              let markerText else { return false }
        return markerText.utf16.elementsEqual(text.utf16)
    }
}
