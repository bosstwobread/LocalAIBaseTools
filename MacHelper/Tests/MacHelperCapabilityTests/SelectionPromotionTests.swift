import ApplicationServices
import XCTest
@testable import MacHelperCapabilities

final class SelectionPromotionTests: XCTestCase {
    private func copied(_ text: String = "selected", pid: Int32 = 42) -> TextSelection {
        var value = TextSelection(text: text, sourcePID: pid, rangeLocation: -1,
            rangeLength: text.utf16.count, bounds: .zero)
        value.isClipboardOnly = true
        return value
    }

    /// Construct inert AX handles only; tests do not query applications or the
    /// global clipboard. The reader/caller is responsible for live AX proof.
    private func proved(_ text: String = "selected", pid: Int32 = 42, location: Int = 10,
                        length: Int? = nil, originPID: Int32? = nil, sourceIndex: Int = 0) -> TextSelection {
        let process = SelectionCompatibilityProcess(processIdentifier: originPID ?? pid,
            bundleIdentifier: "com.example.fixture", launchDate: nil)
        let node = AXUIElementCreateApplication(process.processIdentifier)
        let origin = AccessibilitySelectionOrigin(process: process, ancestry: [node], sourceIndex: sourceIndex,
            focus: SelectionFocusPath(elements: [node]), hitPoint: nil)
        return TextSelection(text: text, sourcePID: pid, rangeLocation: location,
            rangeLength: length ?? text.utf16.count, bounds: .zero, accessibilityOrigin: origin)
    }

    func testLaterIndependentNumericAXProofCanRecoverClipboardSelection() throws {
        let candidate = proved()
        let promoted = try XCTUnwrap(SelectionPromotion.verifiedAXSelection(from: copied(),
            candidate: candidate, contextIsCurrent: true))
        XCTAssertEqual(promoted, candidate)
        XCTAssertFalse(promoted.isClipboardOnly)
        XCTAssertEqual(promoted.rangeLocation, 10)
    }

    func testStaleGestureOrChangedSourceCannotPromote() {
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved(), contextIsCurrent: false))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved(pid: 43), contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: nil, contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(pid: 1), candidate: proved(pid: 1), contextIsCurrent: true))
    }

    func testDifferentTextAndCanonicallyEquivalentButDifferentUTF16AreRejected() {
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved("different"), contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied("é"), candidate: proved("e\u{301}"), contextIsCurrent: true))
    }

    func testClipboardAndMarkerOnlyEvidenceNeverBecomeNumericEditProof() {
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: copied(), contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved(location: -1), contextIsCurrent: true))
        var noOrigin = proved()
        noOrigin.accessibilityOrigin = nil
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: noOrigin, contextIsCurrent: true))
    }

    func testCaretMalformedLengthAndOverflowAreRejected() {
        for candidate in [proved(length: 0), proved(length: 7), proved(location: NSNotFound),
                          proved(location: Int.max - 1), proved(location: -2)] {
            XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: candidate, contextIsCurrent: true))
        }
    }

    func testAXOriginMustBelongToSameProcessAndHaveValidSourceIndex() {
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved(originPID: 43), contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved(sourceIndex: 1), contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(), candidate: proved(sourceIndex: -1), contextIsCurrent: true))
    }

    func testNormalAXSelectionDoesNotEnterClipboardPromotionPath() {
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: proved(), candidate: proved(), contextIsCurrent: true))
    }

    func testUTF16OffsetsAndLengthsPreserveEmoji() {
        let text = "A😀B"
        XCTAssertNotNil(SelectionPromotion.verifiedAXSelection(from: copied(text), candidate: proved(text), contextIsCurrent: true))
        XCTAssertNil(SelectionPromotion.verifiedAXSelection(from: copied(text), candidate: proved(text, length: text.count), contextIsCurrent: true))
    }

    func testStateProofRefreshPreservesGenerationAndExistingResultTicket() {
        let original = copied()
        let candidate = proved()
        var state = SelectionState()
        state.observe(original)
        let ticket = state.generation

        XCTAssertTrue(state.promoteAXProof(from: original, to: candidate, contextIsCurrent: true))
        XCTAssertEqual(state.generation, ticket, "Independent proof refresh is not a new user selection")
        XCTAssertTrue(state.acceptsResult(for: ticket), "The operation that requested proof keeps its ticket")
        XCTAssertEqual(state.selection, candidate)
        XCTAssertFalse(state.selection?.isClipboardOnly ?? true)
        XCTAssertFalse(state.observe(candidate), "The next identical AX poll must preserve the same operation too")
        XCTAssertTrue(state.acceptsResult(for: ticket))
    }

    func testChangedOrDismissedStateRejectsPromotionWithoutResurrection() {
        let original = copied()
        for changed in [copied("different"), copied(pid: 43), nil] as [TextSelection?] {
            var state = SelectionState()
            state.observe(original)
            state.observe(changed)
            let generation = state.generation
            XCTAssertFalse(state.promoteAXProof(from: original, to: proved(), contextIsCurrent: true))
            XCTAssertEqual(state.selection, changed)
            XCTAssertEqual(state.generation, generation)
        }

        var dismissed = SelectionState()
        dismissed.observe(original)
        dismissed.dismiss()
        let generation = dismissed.generation
        XCTAssertFalse(dismissed.promoteAXProof(from: original, to: proved(), contextIsCurrent: true))
        XCTAssertTrue(dismissed.dismissed)
        XCTAssertFalse(dismissed.canTranslate)
        XCTAssertEqual(dismissed.selection, original)
        XCTAssertEqual(dismissed.generation, generation)
    }

    func testLiteralUTF16StateChangeAndStaleContextCannotRefreshOldProof() {
        let original = copied("é")
        var state = SelectionState()
        state.observe(original)
        let ticket = state.generation
        XCTAssertFalse(state.promoteAXProof(from: original, to: proved("é"), contextIsCurrent: false))
        XCTAssertEqual(state.generation, ticket)
        XCTAssertEqual(state.selection, original)

        let changed = copied("e\u{301}")
        state.observe(changed)
        let changedGeneration = state.generation
        XCTAssertFalse(state.promoteAXProof(from: original, to: proved("é"), contextIsCurrent: true))
        XCTAssertEqual(state.selection, changed)
        XCTAssertEqual(state.generation, changedGeneration)
        XCTAssertFalse(state.acceptsResult(for: ticket))
    }
}
