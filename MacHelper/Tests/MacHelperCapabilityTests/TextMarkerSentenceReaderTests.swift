import Foundation
import XCTest
@testable import MacHelperCapabilities

final class TextMarkerSentenceReaderTests: XCTestCase {
    private struct Marker: Hashable { let node: Int; let offset: Int }
    private struct MarkerRange: Hashable { let start: Marker; let end: Marker }

    private final class Fixture {
        let nodes: [String]
        let document: NSString
        var selected: MarkerRange
        var paragraph: MarkerRange?
        var lengths: [MarkerRange: Int] = [:]
        var unavailableLengths = Set<MarkerRange>()
        var strings: [MarkerRange: String] = [:]
        var reads: [MarkerRange] = []
        var paragraphCalls = 0
        var readable = true
        var supportsRangeCreation = true
        var onRead: ((MarkerRange) -> Void)?

        init(_ nodes: [String], word: String = "ready", last: Bool = false) {
            self.nodes = nodes
            document = nodes.joined() as NSString
            selected = MarkerRange(start: Marker(node: 0, offset: 0), end: Marker(node: 0, offset: 0))
            let location = document.range(of: word, options: last ? .backwards : [])
            selected = range(location)
        }
        func marker(_ position: Int) -> Marker {
            var remaining = position
            for (index, node) in nodes.enumerated() {
                if remaining < node.utf16.count || index == nodes.count - 1 { return Marker(node: index, offset: remaining) }
                remaining -= node.utf16.count
            }
            fatalError("Fixture position is outside its synthetic document")
        }
        func position(_ marker: Marker) -> Int { nodes.prefix(marker.node).reduce(0) { $0 + $1.utf16.count } + marker.offset }
        func range(_ range: NSRange) -> MarkerRange { MarkerRange(start: marker(range.location), end: marker(NSMaxRange(range))) }
        var whole: MarkerRange { range(NSRange(location: 0, length: document.length)) }
        func reader() -> TextMarkerSentenceReader<MarkerRange, Marker> {
            TextMarkerSentenceReader(selectedRange: { self.selected }, equalsRange: ==,
                startMarker: { $0.start }, endMarker: { $0.end },
                makeRange: { self.supportsRangeCreation ? MarkerRange(start: $0, end: $1) : nil },
                paragraphRange: { _ in self.paragraphCalls += 1; return self.paragraph },
                length: { self.unavailableLengths.contains($0) ? nil : self.lengths[$0] ?? abs(self.position($0.end) - self.position($0.start)) },
                string: { range in
                    self.reads.append(range)
                    let value = self.strings[range] ?? self.document.substring(with: NSRange(location: self.position(range.start), length: self.position(range.end) - self.position(range.start)))
                    self.onRead?(range)
                    return value
                }, canRead: { self.readable })
        }
    }

    func testParagraphCrossesInlineNodesAndUsesCorrectRepeatedWordOffset() {
        let fixture = Fixture(["🙂 First ", "ready", " example. The project is ", "rea", "dy", " for review."], last: true)
        fixture.paragraph = fixture.whole
        XCTAssertEqual(fixture.reader().read(selected: "ready"), "The project is ready for review.")
        XCTAssertNotEqual(fixture.selected.start.node, fixture.selected.end.node)
        XCTAssertEqual(fixture.paragraphCalls, 1)
        XCTAssertEqual(fixture.reads, [fixture.selected, fixture.whole])
    }

    func testCompleteParagraphPermitsFirstAndLastSentence() {
        for (document, expected) in [("We are ready. Another sentence.", "We are ready."),
                                     ("Another sentence. We are ready.", "We are ready.")] {
            let fixture = Fixture([document])
            fixture.paragraph = fixture.whole
            XCTAssertEqual(fixture.reader().read(selected: "ready"), expected)
        }
    }

    func testUnsupportedCandidateAttributesReadOnlyTheBoundedSelection() {
        let fixture = Fixture(["We are ready."])
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected])
    }

    func testAnchorClippedWordCannotMasqueradeAsSurroundingSentence() {
        let fixture = Fixture(["We are ready."])
        fixture.paragraph = fixture.selected
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected])
    }

    func testUnsupportedRangeLengthNeverStartsTheCorrespondingStringRead() {
        for unavailableSelection in [true, false] {
            let fixture = Fixture(["We are ready."])
            fixture.paragraph = fixture.whole
            fixture.unavailableLengths.insert(unavailableSelection ? fixture.selected : fixture.whole)
            XCTAssertNil(fixture.reader().read(selected: "ready"))
            XCTAssertEqual(fixture.reads, unavailableSelection ? [] : [fixture.selected])
        }
    }

    func testSelectedMarkerLengthAndExactTextMustMatchBeforeContextRead() {
        for invalidLength in [-1, 0, 4, 129] {
            let fixture = Fixture(["We are ready."])
            fixture.paragraph = fixture.whole
            fixture.lengths[fixture.selected] = invalidLength
            XCTAssertNil(fixture.reader().read(selected: "ready"))
            XCTAssertTrue(fixture.reads.isEmpty)
        }
        let fixture = Fixture(["We are ready."])
        fixture.paragraph = fixture.whole
        fixture.strings[fixture.selected] = "other"
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected])
        XCTAssertNil(fixture.reader().read(selected: String(repeating: "a", count: 129)))
        XCTAssertEqual(fixture.reads, [fixture.selected])
    }

    func testOversizedParagraphIsRejectedBeforeItsStringRead() {
        let fixture = Fixture(["We are ready. Another sentence."])
        fixture.paragraph = fixture.whole
        fixture.lengths[fixture.whole] = 2_001
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertFalse(fixture.reads.contains(fixture.whole))
        XCTAssertEqual(fixture.reads, [fixture.selected])
    }

    func testChangedSelectionBeforeOrDuringContextReadNeverReturnsStaleSentence() {
        for changeDuringContextRead in [false, true] {
            let fixture = Fixture(["We are ready."])
            fixture.paragraph = fixture.whole
            let trigger = changeDuringContextRead ? fixture.whole : fixture.selected
            fixture.onRead = { range in
                if range == trigger { fixture.selected = fixture.range(NSRange(location: 0, length: 2)) }
            }
            XCTAssertNil(fixture.reader().read(selected: "ready"))
            XCTAssertEqual(fixture.reads.count, changeDuringContextRead ? 2 : 1)
        }
    }

    func testRangesMustContainTheActualSelectionBeforeContextStringRead() {
        let fixture = Fixture(["Other sentence. We are ready."])
        fixture.paragraph = fixture.range(fixture.document.range(of: "Other sentence."))
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected])
        fixture.reads = []
        fixture.paragraph = fixture.whole
        fixture.supportsRangeCreation = false
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected])
    }

    func testCandidateLengthAndSelectedOffsetAreValidatedAgainstReturnedText() {
        for replacement in ["We are other.", "We are ready\0", "Different length"] {
            let fixture = Fixture(["We are ready."])
            fixture.paragraph = fixture.whole
            fixture.strings[fixture.whole] = replacement
            XCTAssertNil(fixture.reader().read(selected: "ready"))
        }
    }

    func testCandidateLengthChangingDuringStringReadIsRejected() {
        let fixture = Fixture(["We are ready."])
        fixture.paragraph = fixture.whole
        fixture.onRead = { range in
            if range == fixture.whole { fixture.lengths[range] = fixture.document.length + 1 }
        }
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected, fixture.whole])
    }

    func testReadPermissionOrFocusGatePreventsAdditionalTextReads() {
        let fixture = Fixture(["We are ready."])
        fixture.paragraph = fixture.whole
        fixture.readable = false
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertTrue(fixture.reads.isEmpty)
        fixture.readable = true
        fixture.onRead = { _ in fixture.readable = false }
        XCTAssertNil(fixture.reader().read(selected: "ready"))
        XCTAssertEqual(fixture.reads, [fixture.selected])
    }
}
