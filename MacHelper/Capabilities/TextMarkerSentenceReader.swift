import Foundation

/// Pure policy for opaque AX text markers. Candidate ranges must be complete
/// cross-anchor semantic paragraphs, never an arbitrary whole WebArea range
/// or an anchor-clipped built-in sentence/paragraph marker range.
/// Adapters supply read-only operations; no AX calls or local-node numeric
/// offsets are used here. Prefix/suffix lengths span inline-node boundaries.
/// paragraphRange receives the selected range so an adapter can join previous
/// paragraph start from the selected END to next paragraph end from its START.
/// canRead can enforce a deadline and focus/protection checks around each read.
struct TextMarkerSentenceReader<MarkerRange, Marker> {
    let selectedRange: () -> MarkerRange?
    let equalsRange: (MarkerRange, MarkerRange) -> Bool
    let startMarker: (MarkerRange) -> Marker?
    let endMarker: (MarkerRange) -> Marker?
    let makeRange: (Marker, Marker) -> MarkerRange?
    let paragraphRange: (MarkerRange) -> MarkerRange?
    let length: (MarkerRange) -> Int?
    let string: (MarkerRange) -> String?
    let canRead: () -> Bool

    init(selectedRange: @escaping () -> MarkerRange?,
         equalsRange: @escaping (MarkerRange, MarkerRange) -> Bool,
         startMarker: @escaping (MarkerRange) -> Marker?,
         endMarker: @escaping (MarkerRange) -> Marker?,
         makeRange: @escaping (Marker, Marker) -> MarkerRange?,
         paragraphRange: @escaping (MarkerRange) -> MarkerRange?,
         length: @escaping (MarkerRange) -> Int?,
         string: @escaping (MarkerRange) -> String?,
         canRead: @escaping () -> Bool = { true }) {
        self.selectedRange = selectedRange; self.equalsRange = equalsRange
        self.startMarker = startMarker; self.endMarker = endMarker
        self.makeRange = makeRange
        self.paragraphRange = paragraphRange; self.length = length
        self.string = string; self.canRead = canRead
    }

    func read(selected: String) -> String? {
        let selectedLength = selected.utf16.count
        guard selectedLength > 0, selectedLength <= 128,
              SelectionSentenceContext.isSingleWord(selected), canRead(),
              let snapshot = selectedRange(), length(snapshot) == selectedLength,
              isCurrent(snapshot), let actual = string(snapshot),
              actual.utf16.elementsEqual(selected.utf16), isCurrent(snapshot),
              let selectionStart = startMarker(snapshot),
              let selectionEnd = endMarker(snapshot) else { return nil }

        // Built-in sentence/paragraph ranges can stop at an inline anchor.
        // Only the adapter's complete cross-anchor paragraph is trusted.
        guard isCurrent(snapshot), let paragraph = paragraphRange(snapshot) else { return nil }
        return read(paragraph, selected: selected, selectedLength: selectedLength,
                    snapshot: snapshot, selectionStart: selectionStart, selectionEnd: selectionEnd)
    }

    private func isCurrent(_ snapshot: MarkerRange) -> Bool {
        guard canRead(), let current = selectedRange() else { return false }
        return equalsRange(snapshot, current)
    }

    private func read(_ candidate: MarkerRange, selected: String, selectedLength: Int,
                      snapshot: MarkerRange, selectionStart: Marker, selectionEnd: Marker) -> String? {
        guard isCurrent(snapshot), let count = length(candidate), count > selectedLength, count <= SelectionSentenceContext.maximumUTF16,
              let contextStart = startMarker(candidate), let contextEnd = endMarker(candidate),
              let prefix = makeRange(contextStart, selectionStart),
              let suffix = makeRange(selectionEnd, contextEnd),
              let offset = length(prefix), let trailing = length(suffix),
              offset >= 0, offset <= count, selectedLength <= count - offset,
              trailing == count - offset - selectedLength,
              isCurrent(snapshot), let text = string(candidate),
              text.utf16.count == count, text.utf8.count <= SelectionSentenceContext.maximumUTF8,
              !text.contains("\0"), length(candidate) == count, isCurrent(snapshot) else { return nil }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != selected.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let wordRange = NSRange(location: offset, length: selectedLength)
        let actual = (text as NSString).substring(with: wordRange)
        guard actual.utf16.elementsEqual(selected.utf16) else { return nil }
        // The adapter promises complete semantic paragraph boundaries. Treat
        // this small paragraph as the verified window, not a document sample.
        return SelectionSentenceContext.sentence(selected: selected, selection: wordRange,
            windowText: text, windowRange: NSRange(location: 0, length: count), documentUTF16Length: count)
    }
}
