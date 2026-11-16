import XCTest
@testable import MacHelperCapabilities

final class StreamingStateTests: XCTestCase {
    func testIncrementalTextUpdateUsesLiteralUTF16Prefix() {
        XCTAssertEqual(CapabilityTextUpdate.between(old: "你😊", new: "你😊好"), .append("好"))
        XCTAssertEqual(CapabilityTextUpdate.between(old: "e", new: "e\u{301}"), .append("\u{301}"))
        XCTAssertEqual(CapabilityTextUpdate.between(old: "same", new: "same"), .unchanged)
        // Normalizing an existing prefix must replace it, never slice using the
        // old decomposed prefix's larger UTF-16 offset.
        let old = "e\u{301}\u{323}"
        let normalized = old.precomposedStringWithCanonicalMapping
        let final = normalized + "!"
        guard case .replace(let replacement) = CapabilityTextUpdate.between(old: old, new: final) else {
            return XCTFail("Unicode normalization must replace the displayed prefix")
        }
        XCTAssertEqual(Array(replacement.utf16), Array(final.utf16))
        let decomposedKorean = "\u{1100}\u{1161}\u{11A8}"
        XCTAssertLessThan(("각!" as NSString).length, (decomposedKorean as NSString).length)
        XCTAssertEqual(CapabilityTextUpdate.between(old: decomposedKorean, new: "각!"), .replace("각!"))
        XCTAssertEqual(CapabilityTextUpdate.between(old: "earlier preview", new: "final"), .replace("final"))
    }

    func testProgressBecomesCopyableOnlyAfterTerminalSuccess() {
        var state = CapabilityPresentationState()
        state.begin()
        XCTAssertTrue(state.progress(.init(text: "first", model: "actual-model")))
        XCTAssertEqual(state.text, "first")
        XCTAssertNil(state.copyText)
        state.progress(.init(text: "first second"))
        XCTAssertEqual(state.model, "actual-model")
        XCTAssertNil(state.copyText)
        state.complete(.init(text: "authoritative final"))
        XCTAssertEqual(state.copyText, "authoritative final")
        XCTAssertEqual(state.model, "actual-model")
        XCTAssertFalse(state.progress(.init(text: "late unverified preview")))
        XCTAssertEqual(state.text, "authoritative final")
    }

    func testFailureRetainsPartialButMarksItIncompleteAndUncopyable() {
        var state = CapabilityPresentationState()
        state.begin()
        state.progress(.init(text: "unfinished sentence", model: "actual-model"))
        state.fail("Connection lost")
        XCTAssertEqual(state.text, "unfinished sentence")
        XCTAssertTrue(state.isIncomplete)
        XCTAssertNil(state.copyText)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertFalse(state.progress(.init(text: "late output")))
    }

    func testFailureBeforeProgressShowsErrorAndRetryClearsOldPartial() {
        var state = CapabilityPresentationState()
        state.begin()
        state.fail("Provider unavailable")
        XCTAssertEqual(state.text, "Provider unavailable")
        XCTAssertFalse(state.isIncomplete)
        state.begin()
        XCTAssertEqual(state.text, "")
        XCTAssertNil(state.model)
        XCTAssertNil(state.copyText)
    }

    func testNewSelectionAndCancellationRejectEscapingProgress() {
        var selection = SelectionState()
        selection.observe(sample("first"))
        var gate = CapabilityOperationGate()
        let first = gate.begin(selectionGeneration: selection.generation)
        XCTAssertTrue(gate.accepts(first, selection: selection, running: true, cancelled: false))
        selection.observe(sample("second"))
        XCTAssertFalse(gate.accepts(first, selection: selection, running: true, cancelled: false))
        let second = gate.begin(selectionGeneration: selection.generation)
        XCTAssertFalse(gate.accepts(first, selection: selection, running: true, cancelled: false))
        XCTAssertFalse(gate.accepts(second, selection: selection, running: true, cancelled: true))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(second, selection: selection, running: true, cancelled: false))
    }

    func testTerminalResultClosesTicketAndOlderFinishCannotCloseNewRequest() {
        var selection = SelectionState()
        selection.observe(sample("same text"))
        var gate = CapabilityOperationGate()
        let first = gate.begin(selectionGeneration: selection.generation)
        let second = gate.begin(selectionGeneration: selection.generation)
        gate.finish(first)
        XCTAssertTrue(gate.accepts(second, selection: selection, running: true, cancelled: false))
        gate.finish(second)
        XCTAssertFalse(gate.accepts(second, selection: selection, running: true, cancelled: false))
    }

    private func sample(_ text: String) -> TextSelection {
        TextSelection(text: text, sourcePID: 100, rangeLocation: 0, rangeLength: text.count,
                      bounds: CGRect(x: 100, y: 100, width: 100, height: 20))
    }
}
