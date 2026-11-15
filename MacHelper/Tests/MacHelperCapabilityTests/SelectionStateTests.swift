import XCTest
@testable import MacHelperCapabilities

final class SelectionStateTests: XCTestCase {
    private func selection(_ text: String = "hello", pid: Int32 = 100, x: CGFloat = 100) -> TextSelection {
        TextSelection(text: text, sourcePID: pid, rangeLocation: 10, rangeLength: text.count,
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
        XCTAssertTrue(state.canTranslate)
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
}
