import Foundation
import XCTest
@testable import MacHelperCapabilities

final class SelectedMarkerTextReaderTests: XCTestCase {
    private struct Span: Equatable { let start: Int; let end: Int }

    private func reader(selection: @escaping () -> Span? = { .init(start: 7, end: 12) },
                        order: @escaping (Span) -> Span? = { .init(start: min($0.start, $0.end), end: max($0.start, $0.end)) },
                        length: @escaping (Span) -> Int? = { $0.end - $0.start },
                        string: @escaping (Span) -> String? = { _ in "draft" },
                        protected: @escaping () -> Bool = { false },
                        canRead: @escaping () -> Bool = { true }) -> SelectedMarkerTextReader<Span> {
        .init(selectedRange: selection, equalsRange: ==, orderedRange: order, length: length,
              string: string, isProtected: protected, canRead: canRead)
    }

    func testReadsOnlyOrderedSelectedSpanAndVerifiesLiteralExpectedText() {
        var queried: [Span] = []
        XCTAssertEqual(reader(selection: { .init(start: 12, end: 7) }, string: { queried.append($0); return "draft" }).read(), "draft")
        XCTAssertEqual(queried, [.init(start: 7, end: 12), .init(start: 7, end: 12)])
        XCTAssertEqual(reader().read(expectedText: "draft"), "draft")
        XCTAssertNil(reader().read(expectedText: "other"))
        XCTAssertNil(reader(length: { _ in 1 }, string: { _ in "é" }).read(expectedText: "e\u{301}"))
    }

    func testEmptyInvalidUnorderedAndOversizedMarkersNeverReadText() {
        for size in [0, -1, 96_001] {
            var reads = 0
            XCTAssertNil(reader(length: { _ in size }, string: { _ in reads += 1; return "draft" }).read())
            XCTAssertEqual(reads, 0)
        }
        var reads = 0
        XCTAssertNil(reader(order: { _ in nil }, string: { _ in reads += 1; return "draft" }).read())
        XCTAssertNil(reader(selection: { nil }, string: { _ in reads += 1; return "draft" }).read())
        XCTAssertEqual(reads, 0)
    }

    func testChangingRangeLengthTextProtectionOrBudgetRejectsPublication() {
        var ranges = 0
        XCTAssertNil(reader(selection: { ranges += 1; return .init(start: ranges == 1 ? 7 : 8, end: ranges == 1 ? 12 : 13) }).read())
        var lengths = 0
        XCTAssertNil(reader(length: { _ in lengths += 1; return lengths == 1 ? 5 : 6 }).read())
        var texts = 0
        XCTAssertNil(reader(string: { _ in texts += 1; return texts == 1 ? "draft" : "other" }).read())
        var protected = false
        XCTAssertNil(reader(string: { _ in protected = true; return "draft" }, protected: { protected }).read())
        var allowed = true
        XCTAssertNil(reader(string: { _ in allowed = false; return "draft" }, canRead: { allowed }).read())
        XCTAssertNil(reader(protected: { true }).read())
        XCTAssertNil(reader(canRead: { false }).read())
        XCTAssertNil(reader(string: { _ in "wrong length" }).read())
        XCTAssertNil(reader(string: { _ in "ab\0cd" }).read())
    }

    func testAttributedFallbackIsOnlyForAbsentPlainRepresentation() {
        var calls = 0
        let attributed = { () -> SelectedTextAttributeRead in calls += 1; return .text("draft") }
        XCTAssertEqual(SelectionRangeTextReader(plain: { .missing }, attributed: attributed, canRead: { true }).read(), "draft")
        XCTAssertEqual(calls, 1)
        for value in [SelectedTextAttributeRead.invalid, .text(""), .text("plain")] {
            _ = SelectionRangeTextReader(plain: { value }, attributed: attributed, canRead: { true }).read()
        }
        XCTAssertEqual(calls, 1, "An empty or malformed plain response is not permission to replace it with another representation")
        XCTAssertNil(SelectionRangeTextReader(plain: { .missing }, attributed: { .invalid }, canRead: { true }).read())
        XCTAssertNil(SelectionRangeTextReader(plain: { .missing }, attributed: attributed, canRead: { false }).read())
        var allowed = true
        XCTAssertNil(SelectionRangeTextReader(plain: { allowed = false; return .missing }, attributed: attributed, canRead: { allowed }).read())
    }
}
