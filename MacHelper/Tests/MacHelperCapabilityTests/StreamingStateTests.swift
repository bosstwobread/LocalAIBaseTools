import XCTest
@testable import MacHelperCapabilities

final class StreamingStateTests: XCTestCase {
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
        XCTAssertEqual(state.error, "Connection lost")
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
        XCTAssertNil(state.error)
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
