import XCTest
@testable import MacHelperCapabilities

final class SelectionStateTests: XCTestCase {
    private func selection(_ text: String = "hello", pid: Int32 = 100, x: CGFloat = 100) -> TextSelection {
        TextSelection(text: text, sourcePID: pid, rangeLocation: 10, rangeLength: text.utf16.count,
                      bounds: CGRect(x: x, y: 200, width: 100, height: 20))
    }

    func testUnchangedPollingDoesNotInvalidateRequest() {
        var state = SelectionState()
        XCTAssertTrue(state.observe(selection()))
        let token = state.generation
        XCTAssertFalse(state.observe(selection()))
        XCTAssertTrue(state.acceptsResult(for: token))
    }

    func testNewSelectionRejectsStaleTranslation() {
        var state = SelectionState()
        state.observe(selection())
        let token = state.generation
        state.observe(selection("different text"))
        XCTAssertFalse(state.acceptsResult(for: token))
        XCTAssertTrue(state.canTranslate)
    }

    func testSameTextInDifferentAppInvalidatesRequest() {
        var state = SelectionState()
        state.observe(selection())
        let token = state.generation
        state.observe(selection(pid: 200))
        XCTAssertFalse(state.acceptsResult(for: token))
    }

    func testDismissedSelectionStaysHiddenOnPolling() {
        var state = SelectionState()
        state.observe(selection())
        let token = state.generation
        state.dismiss()
        state.observe(selection())
        XCTAssertFalse(state.canTranslate)
        XCTAssertFalse(state.acceptsResult(for: token))
        state.observe(selection(x: 150))
        XCTAssertFalse(state.canTranslate, "Changed click-fallback bounds are not a fresh selection gesture")
        XCTAssertTrue(state.dismissed)
    }

    func testDeselectionRejectsResultAndClearsText() {
        var state = SelectionState()
        state.observe(selection())
        let token = state.generation
        state.observe(nil)
        XCTAssertNil(state.selection)
        XCTAssertFalse(state.acceptsResult(for: token))
    }

    func testDeliberateReselectionRearmsSameTextButPollingDoesNot() {
        var state = SelectionState()
        state.observe(selection())
        state.dismiss()
        XCTAssertFalse(state.observe(selection()))
        XCTAssertFalse(state.canTranslate)
        state.rearmAfterSelectionGesture()
        XCTAssertTrue(state.observe(selection()))
        XCTAssertTrue(state.canTranslate)
    }

    func testDismissalSurvivesDifferentCachedTextAndApplication() {
        var state = SelectionState()
        state.observe(selection())
        let originalToken = state.generation
        state.dismiss()
        XCTAssertTrue(state.observe(selection("cached text", pid: 200, x: 400)))
        XCTAssertFalse(state.canTranslate)
        XCTAssertTrue(state.dismissed)
        XCTAssertFalse(state.acceptsResult(for: originalToken))

        state.rearmAfterSelectionGesture()
        XCTAssertTrue(state.observe(selection("new selected text", pid: 200, x: 400)))
        XCTAssertTrue(state.canTranslate)
    }

    func testTransientEmptyReadCannotUnlockDismissedSelection() {
        var state = SelectionState()
        state.observe(selection())
        state.dismiss()
        XCTAssertTrue(state.observe(nil))
        XCTAssertNil(state.selection)
        XCTAssertTrue(state.dismissed)
        XCTAssertFalse(state.observe(nil))
        XCTAssertTrue(state.observe(selection(x: 700)))
        XCTAssertFalse(state.canTranslate)
        XCTAssertTrue(state.dismissed)
    }

    func testClearingAfterAppChangeWaitsForNextSelectionGesture() {
        var state = SelectionState()
        state.observe(selection())
        state.dismiss()
        state.observe(nil)
        state.observe(selection(pid: 200))
        XCTAssertFalse(state.canTranslate)
        state.rearmAfterSelectionGesture()
        XCTAssertNil(state.selection)
        XCTAssertFalse(state.canTranslate, "Rearming alone must not reuse a stale AX value")
        state.observe(selection(pid: 200))
        XCTAssertTrue(state.canTranslate)
    }

    func testActiveGeometryChangeStillInvalidatesPreviousResult() {
        var state = SelectionState()
        state.observe(selection())
        let token = state.generation
        XCTAssertTrue(state.observe(selection(x: 150)))
        XCTAssertFalse(state.acceptsResult(for: token))
        XCTAssertTrue(state.canTranslate)
        XCTAssertFalse(state.dismissed)
    }
}
