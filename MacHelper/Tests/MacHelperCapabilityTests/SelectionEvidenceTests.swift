import XCTest
@testable import MacHelperCapabilities

final class SelectionEvidenceTests: XCTestCase {
    func testValidNumericRangeProvesSelectionWithoutMarkers() {
        XCTAssertTrue(SelectionEvidence.isSelected(text: "hello", numericRange: NSRange(location: 10, length: 5)))
    }

    func testCollapsedNumericRangeCannotUseMarkerFallback() {
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: NSRange(location: 10, length: 0),
                                                   markerLength: 5, markerText: "hello"))
    }

    func testMalformedNumericRangesAreRejectedWithoutOverflow() {
        let ranges = [NSRange(location: -1, length: 5), NSRange(location: NSNotFound, length: 5),
                      NSRange(location: Int.max - 3, length: 5), NSRange(location: 10, length: 4),
                      NSRange(location: 10, length: -1)]
        for range in ranges {
            XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: range,
                                                       markerLength: 5, markerText: "hello"), "\(range)")
        }
    }

    func testMissingRangeRequiresCompleteMatchingMarkerEvidence() {
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil))
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil, markerLength: 5))
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil, markerText: "hello"))
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil, markerLength: 0, markerText: "hello"))
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil, markerLength: -1, markerText: "hello"))
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil, markerLength: 4, markerText: "hello"))
        XCTAssertFalse(SelectionEvidence.isSelected(text: "hello", numericRange: nil, markerLength: 5, markerText: "other"))
    }

    func testOrderedBrowserMarkerRangeSupportsForwardsAndBackwardsSelections() {
        // Providers order opaque endpoints before supplying their length/text.
        // This policy intentionally does not infer offsets from marker bytes.
        for selectedText in ["useful", "crane", "a linked phrase"] {
            XCTAssertTrue(SelectionEvidence.isSelected(text: selectedText, numericRange: nil,
                                                      markerLength: selectedText.utf16.count, markerText: selectedText))
        }
    }

    func testUTF16LengthsHandleEmojiAndCombiningMarks() {
        for text in ["👩🏽‍💻", "e\u{301}", "中文"] {
            XCTAssertTrue(SelectionEvidence.isSelected(text: text, numericRange: NSRange(location: 0, length: text.utf16.count)))
            XCTAssertTrue(SelectionEvidence.isSelected(text: text, numericRange: nil,
                                                      markerLength: text.utf16.count, markerText: text))
        }
        XCTAssertFalse(SelectionEvidence.isSelected(text: "👩🏽‍💻", numericRange: NSRange(location: 0, length: 1)))
    }

    func testCanonicallyEquivalentMarkerTextIsNotExactSelectionEvidence() {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(SelectionEvidence.isSelected(text: composed, numericRange: nil,
                                                   markerLength: composed.utf16.count, markerText: decomposed))
    }

    func testEmptyWhitespaceNullAndOversizedSourceTextAreRejected() {
        for text in ["", " \n\t", "a\0b", String(repeating: "a", count: 24_001), String(repeating: "👩🏽‍💻", count: 7_000)] {
            XCTAssertFalse(SelectionEvidence.isSelected(text: text, numericRange: NSRange(location: 0, length: text.utf16.count)))
            XCTAssertFalse(SelectionEvidence.isSelected(text: text, numericRange: nil,
                                                       markerLength: text.utf16.count, markerText: text))
        }
    }
}
