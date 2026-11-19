import Foundation

/// A later independent AX read may recover the numeric evidence that was
/// unavailable during initial clipboard capture. Clipboard text alone is never
/// upgraded into edit authority. Applying still needs the focused edit target's
/// complete checks in AccessibilitySelectionEditTarget.
enum SelectionPromotion {
    /// `contextIsCurrent` must be computed after the AX read: the original
    /// gesture/token, process launch, Copy target and candidate AX origin must
    /// still be current. Recheck the gesture again on the main queue before
    /// publishing. Callers decide whether proof refresh may replace idle state;
    /// it must not cancel an active stream/result merely to update provenance.
    static func verifiedAXSelection(from original: TextSelection, candidate: TextSelection?,
                                    contextIsCurrent: Bool) -> TextSelection? {
        guard contextIsCurrent, original.isClipboardOnly, let candidate,
              !candidate.isClipboardOnly, original.sourcePID > 1,
              candidate.sourcePID == original.sourcePID,
              candidate.text.utf16.elementsEqual(original.text.utf16),
              SelectionSpanReader.validText(candidate.text),
              candidate.rangeLength > 0,
              candidate.rangeLength == candidate.text.utf16.count,
              SelectionSpanReader.validRange(NSRange(location: candidate.rangeLocation, length: candidate.rangeLength)),
              let origin = candidate.accessibilityOrigin,
              origin.process.processIdentifier == candidate.sourcePID,
              origin.ancestry.indices.contains(origin.sourceIndex) else { return nil }
        return candidate
    }
}
