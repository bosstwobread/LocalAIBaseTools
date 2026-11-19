import Foundation
import ApplicationServices
import XCTest
@testable import MacHelperCapabilities

final class AccessibilitySelectedTextTests: XCTestCase {
    private func reader(text: @escaping () -> SelectedTextAttributeRead = { .text("draft") },
                        range: @escaping () -> SelectedNumericRangeRead = { .value(NSRange(location: 7, length: 5)) },
                        fallback: @escaping (NSRange) -> String? = { _ in XCTFail("Unexpected parameter read"); return nil },
                        protected: @escaping () -> Bool = { false },
                        canRead: @escaping () -> Bool = { true },
                        marker: @escaping (String?) -> String? = { _ in nil }) -> SelectionSpanReader {
        .init(selectedText: text, numericRange: range, stringForRange: fallback,
              isProtected: protected, canRead: canRead, markerText: marker)
    }

    func testDirectTextRequiresStableOwnRangeAndLiteralText() {
        XCTAssertEqual(reader().read(), .selected(.init(text: "draft", range: NSRange(location: 7, length: 5))))
        XCTAssertEqual(reader(range: { .missing }).read(), .unavailable,
                       "Direct text without numeric range must still have independent selected-marker proof")
        XCTAssertEqual(reader(range: { .missing }, marker: { $0 }).read(), .selected(.init(text: "draft", range: nil)))
        XCTAssertEqual(reader(text: { .text("") }, range: { .missing }).read(), .empty)
        XCTAssertEqual(reader(text: { .missing }, range: { .missing }).read(), .unavailable)
    }

    func testMarkerOnlyReadRequiresMissingNumericRangeAndNoContradictoryRawText() {
        for raw in [SelectedTextAttributeRead.missing, .text("")] {
            var expected: [String?] = []
            XCTAssertEqual(reader(text: { raw }, range: { .missing }, marker: { expected.append($0); return "draft" }).read(),
                           .selected(.init(text: "draft", range: nil)))
            XCTAssertEqual(expected.count, 2)
            XCTAssertTrue(expected.allSatisfy { $0 == nil })
        }
        XCTAssertEqual(reader(text: { .text("other") }, range: { .missing }, marker: { _ in "draft" }).read(), .unavailable)
        for numeric in [SelectedNumericRangeRead.invalid, .value(NSRange(location: 7, length: 0))] {
            var markerReads = 0
            _ = reader(text: { .missing }, range: { numeric }, marker: { _ in markerReads += 1; return "draft" }).read()
            XCTAssertEqual(markerReads, 0, "An explicit caret or invalid numeric range cannot be replaced by marker evidence")
        }
        var markerReads = 0
        XCTAssertEqual(reader(text: { .invalid }, range: { .missing }, marker: { _ in markerReads += 1; return "draft" }).read(), .unavailable)
        XCTAssertEqual(markerReads, 0)
    }

    func testMissingAndEmptyDirectTextReadOnlyExactSelectedRange() {
        for direct in [SelectedTextAttributeRead.missing, .text("")] {
            var queried: [NSRange] = []
            let selection = reader(text: { direct }, fallback: { range in queried.append(range); return "draft" }).read()
            XCTAssertEqual(selection, .selected(.init(text: "draft", range: NSRange(location: 7, length: 5))))
            XCTAssertEqual(queried, [NSRange(location: 7, length: 5), NSRange(location: 7, length: 5)])
        }
    }

    func testExplicitCaretMalformedAmbiguousAndUnboundedRangesNeverReadText() {
        let ranges: [SelectedNumericRangeRead] = [
            .value(NSRange(location: 7, length: 0)), .invalid,
            .value(NSRange(location: -1, length: 5)), .value(NSRange(location: NSNotFound, length: 1)),
            .value(NSRange(location: 0, length: 96_001)), .value(NSRange(location: Int.max - 2, length: 5))
        ]
        for (index, range) in ranges.enumerated() {
            var textReads = 0
            let result = reader(text: { textReads += 1; return .text("draft") }, range: { range }).read()
            XCTAssertEqual(result, index == 0 ? .empty : .unavailable)
            XCTAssertEqual(textReads, 0)
        }
    }

    func testContradictoryDirectTextCannotBeReplacedByParameterRead() {
        XCTAssertEqual(reader(text: { .text("other length") }).read(), .unavailable)
        XCTAssertEqual(reader(text: { .invalid }).read(), .unavailable)
        XCTAssertEqual(reader(text: { .text("     ") }).read(), .unavailable)
    }

    func testBoundedFallbackRejectsInvalidOutput() {
        for output in ["", "     ", "ab\0cd", "different length", String(repeating: "a", count: 96_001)] {
            XCTAssertEqual(reader(text: { .missing }, fallback: { _ in output }).read(), .unavailable)
        }
        XCTAssertEqual(reader(text: { .missing }, fallback: { _ in nil }).read(), .unavailable)
        let tooManyCharacters = String(repeating: "a", count: 24_001)
        XCTAssertEqual(reader(text: { .text(tooManyCharacters) },
            range: { .value(NSRange(location: 0, length: tooManyCharacters.utf16.count)) }).read(), .unavailable)
        // One extended character can contain arbitrarily many UTF-8 bytes.
        let tooManyBytes = "a" + String(repeating: "\u{301}", count: 48_000)
        XCTAssertEqual(reader(text: { .text(tooManyBytes) },
            range: { .value(NSRange(location: 0, length: tooManyBytes.utf16.count)) }).read(), .unavailable)
    }

    func testChangingRangeTextOrProtectionRejectsPublication() {
        var ranges = 0
        XCTAssertEqual(reader(range: {
            ranges += 1
            return .value(NSRange(location: ranges == 1 ? 7 : 8, length: 5))
        }).read(), .unavailable)
        var texts = 0
        XCTAssertEqual(reader(text: {
            texts += 1
            return .text(texts == 1 ? "draft" : "other")
        }).read(), .unavailable)
        var checks = 0
        XCTAssertEqual(reader(protected: { checks += 1; return checks > 1 }).read(), .unavailable)
        XCTAssertEqual(reader(protected: { true }).read(), .unavailable)
        XCTAssertEqual(reader(canRead: { false }).read(), .unavailable)
    }

    func testSecondSnapshotCannotChangeRangeEvidenceOrFallbackText() {
        var ranges = 0
        XCTAssertEqual(reader(range: { ranges += 1; return ranges == 1 ? .missing : .value(NSRange(location: 7, length: 5)) }).read(), .unavailable)
        var reads = 0
        XCTAssertEqual(reader(text: { .missing }, fallback: { _ in reads += 1; return reads == 1 ? "draft" : "other" }).read(), .unavailable)
        var budget = true
        XCTAssertEqual(reader(text: { budget = false; return .text("draft") }, canRead: { budget }).read(), .unavailable)
    }

    func testEquivalentUnicodeWithDifferentUTF16IsNotStableSelection() {
        var read = 0
        let result = reader(text: { read += 1; return .text(read == 1 ? "\u{e9}" : "e\u{301}") },
                            range: { .missing }, marker: { _ in "\u{e9}" }).read()
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(reader(text: { .text("😀") }, range: { .value(NSRange(location: 3, length: 2)) }).read(),
                       .selected(.init(text: "😀", range: NSRange(location: 3, length: 2))))
    }

    private func value(_ range: CFRange) throws -> AXValue {
        var range = range
        return try XCTUnwrap(AXValueCreate(.cfRange, &range))
    }

    func testPluralRangeIsFallbackOnlyAndMustContainExactlyOneTypedRange() throws {
        let one = try value(CFRange(location: 7, length: 5))
        let caret = try value(CFRange(location: 7, length: 0))
        let single: CFArray = [one] as CFArray
        let multiple: CFArray = [one, one] as CFArray
        let empty: CFArray = [] as CFArray
        var pluralReads = 0
        let plural = { () -> AccessibilityAttributeRead in pluralReads += 1; return .value(single) }
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .value(one), plural: plural), .value(NSRange(location: 7, length: 5)))
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .value(caret), plural: plural), .value(NSRange(location: 7, length: 0)))
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .invalid, plural: plural), .invalid)
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .value("wrong" as CFString), plural: plural), .invalid)
        XCTAssertEqual(pluralReads, 0)
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .missing, plural: plural), .value(NSRange(location: 7, length: 5)))
        for invalid in [multiple, empty, ["wrong"] as CFArray] {
            XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .missing, plural: { .value(invalid) }), .invalid)
        }
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .missing, plural: { .missing }), .missing)
        XCTAssertEqual(AccessibilitySelectedText.decodeRange(singular: .missing, plural: { .invalid }), .invalid)
    }
}
