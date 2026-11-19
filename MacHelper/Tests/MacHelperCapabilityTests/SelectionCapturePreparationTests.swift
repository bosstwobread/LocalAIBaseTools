import XCTest
@testable import MacHelperCapabilities

final class SelectionCapturePreparationTests: XCTestCase {
    func testDoubleClickWaitsForPossibleThirdDownIncludingSlowClickPreference() {
        for interval in [0.5, 0.9, 1.25] {
            let deadline = SelectionCapturePreparation.clickCopyDeadline(clickCount: 2, mouseDown: 10,
                mouseUp: 10.09, doubleClickInterval: interval)
            XCTAssertEqual(deadline, 10 + interval, accuracy: 0.00001)
            var pendingWord = SelectionCapturePreparation(context: 4, earliestCopyTime: deadline)
            XCTAssertFalse(pendingWord.beginAttempt(context: 4, now: deadline - 0.001))
            pendingWord.cancel(context: 4) // The third down supersedes the word.
            XCTAssertFalse(pendingWord.beginAttempt(context: 4, now: deadline))
        }
    }

    func testTripleClickAndShiftClickSkipAnotherDoubleClickInterval() {
        for clickCount in [1, 3] {
            XCTAssertEqual(SelectionCapturePreparation.clickCopyDeadline(clickCount: clickCount, mouseDown: 10,
                mouseUp: 10.09, doubleClickInterval: 0.9), 10.44, accuracy: 0.00001)
        }
        XCTAssertEqual(SelectionCapturePreparation.clickCopyDeadline(clickCount: 2, mouseDown: 10,
            mouseUp: 10.6, doubleClickInterval: 0.5), 10.95, accuracy: 0.00001)
        XCTAssertEqual(SelectionCapturePreparation.clickCopyDeadline(clickCount: 2, mouseDown: nil,
            mouseUp: 10, doubleClickInterval: 0.5), 10.5, accuracy: 0.00001)
    }

    func testMultiClickWaitsForOtherSelectionToolsWithoutSpendingItsCopyAttempt() throws {
        var state = SelectionCapturePreparation(context: 9, earliestCopyTime: 20.65)
        for earlyRead in [20.26, 20.36, 20.5] {
            XCTAssertFalse(state.beginAttempt(context: 9, now: earlyRead))
            XCTAssertEqual(try XCTUnwrap(state.delayBeforeAttempt(context: 9, now: earlyRead)),
                           20.65 - earlyRead, accuracy: 0.00001)
        }
        XCTAssertEqual(state.attemptCount, 0)
        XCTAssertTrue(state.beginAttempt(context: 9, now: 20.66))
        state.copyAttempted(context: 9)
        XCTAssertFalse(state.beginAttempt(context: 9, now: 20.8))
    }

    func testNewInputWhileWaitingForMultiClickCancelsDeferredCopy() throws {
        var state = SelectionCapturePreparation(context: 9, earliestCopyTime: 20.65)
        XCTAssertNil(state.delayBeforeAttempt(context: 10, now: 20.26))
        state.cancel(context: 9)
        XCTAssertNil(state.delayBeforeAttempt(context: 9, now: 20.27))
        XCTAssertFalse(state.beginAttempt(context: 9, now: 20.66))
    }

    func testNoRetryBeforeFirstExplicitPreparationAndNoParallelAttempt() {
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertNil(state.preparationFailed(context: 1, now: 0))
        XCTAssertTrue(state.beginAttempt(context: 1, now: 100))
        XCTAssertFalse(state.beginAttempt(context: 1, now: 100.1))
        XCTAssertEqual(state.attemptCount, 1)
    }

    func testUpToThreePreparationAttemptsRespectDelay() throws {
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 10))
        XCTAssertEqual(state.preparationFailed(context: 1, now: 10.05), 0.12)
        XCTAssertFalse(state.beginAttempt(context: 1, now: 10.1))
        XCTAssertEqual(try XCTUnwrap(state.delayBeforeAttempt(context: 1, now: 10.1)), 0.07, accuracy: 0.00001)
        XCTAssertEqual(state.phase, .waiting, "An early polling read must retain the scheduled retry")
        XCTAssertTrue(state.beginAttempt(context: 1, now: 10.2))
        XCTAssertEqual(state.preparationFailed(context: 1, now: 10.25), 0.12)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 10.4))
        XCTAssertNil(state.preparationFailed(context: 1, now: 10.45))
        XCTAssertEqual(state.attemptCount, 3)
        XCTAssertEqual(state.phase, .finished)
        XCTAssertFalse(state.beginAttempt(context: 1, now: 10.6))
        XCTAssertNil(state.delayBeforeAttempt(context: 1, now: 10.6))
    }

    func testWindowStartsAtFirstCopyOpportunityNotGestureCreation() {
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 500), "AX/compatibility may have settled before this point")
        XCTAssertNotNil(state.preparationFailed(context: 1, now: 500.2))
        XCTAssertFalse(state.beginAttempt(context: 1, now: 501.2), "The total preparation window is bounded")
        XCTAssertEqual(state.phase, .finished)
    }

    func testLongPreparationLeavesNoTimeForAnotherAttempt() {
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 0))
        XCTAssertNil(state.preparationFailed(context: 1, now: 1.1))
        XCTAssertEqual(state.phase, .finished)
    }

    func testAnyCopyAttemptEndsRetryEvenIfDispatchReturnsFailure() {
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 0))
        state.copyAttempted(context: 1)
        XCTAssertNil(state.preparationFailed(context: 1, now: 0.01))
        XCTAssertFalse(state.beginAttempt(context: 1, now: 0.2))
        XCTAssertEqual(state.attemptCount, 1)
    }

    func testUserCopyOrCancellationEndsRetry() {
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 0))
        XCTAssertNotNil(state.preparationFailed(context: 1, now: 0.01))
        state.cancel(context: 1)
        XCTAssertFalse(state.beginAttempt(context: 1, now: 0.2))
    }

    func testStaleContextCannotConsumeOrCancelNewGesture() {
        var state = SelectionCapturePreparation(context: 2)
        XCTAssertFalse(state.beginAttempt(context: 1, now: 0))
        state.copyAttempted(context: 1)
        state.cancel(context: 1)
        XCTAssertEqual(state.phase, .armed)
        XCTAssertTrue(state.beginAttempt(context: 2, now: 1))
        XCTAssertNil(state.preparationFailed(context: 1, now: 1.1))
        XCTAssertEqual(state.phase, .preparing)
    }

    func testInvalidConfigurationAndNonmonotonicTimeFailClosed() {
        for mutation in 0..<5 {
            var state = SelectionCapturePreparation(context: 1)
            switch mutation {
            case 0: state.maximumAttempts = 4
            case 1: state.preparationWindow = .infinity
            case 2: state.retryInterval = 0
            case 3: state.retryInterval = state.preparationWindow
            default: state.preparationWindow = 0
            }
            XCTAssertFalse(state.beginAttempt(context: 1, now: 0))
        }
        var state = SelectionCapturePreparation(context: 1)
        XCTAssertTrue(state.beginAttempt(context: 1, now: 10))
        XCTAssertNil(state.preparationFailed(context: 1, now: 9))
        XCTAssertEqual(state.phase, .finished)
        var nan = SelectionCapturePreparation(context: 1)
        XCTAssertFalse(nan.beginAttempt(context: 1, now: .nan))
    }
}
