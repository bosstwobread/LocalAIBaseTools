import AppKit
import XCTest
@testable import MacHelperCapabilities

final class SelectionClipboardTransactionTests: XCTestCase {
    private final class Clock {
        var value: TimeInterval = 0
        var onWait: (() -> Void)?
        func wait(_ interval: TimeInterval) { value += max(0.001, interval); onWait?() }
    }
    private final class Board: SelectionClipboardAccess {
        var count = 10
        var text: String? = "original"
        var items = [[SelectionClipboardRepresentation(type: "public.utf8-plain-text", data: Data("original".utf8)),
                      SelectionClipboardRepresentation(type: "example.rich", data: Data([0, 1, 2]))]]
        var snapshots = 0, reads = 0, restores = 0
        var unreadable = false, restoreAllowed = true
        var onSnapshot: (() -> Void)?
        var onRead: (() -> Void)?
        var restored: SelectionClipboardSnapshot?
        var changeCount: Int { count }
        func snapshot(limits: SelectionClipboardLimits) -> SelectionClipboardSnapshot? {
            snapshots += 1
            let value = SelectionClipboardSnapshot(capturedChangeCount: count, items: items)
            onSnapshot?()
            return unreadable ? nil : value
        }
        func copiedString() -> String? { reads += 1; let value = text; onRead?(); return value }
        func restore(_ snapshot: SelectionClipboardSnapshot, replacingChangeCount: Int) -> Bool {
            guard restoreAllowed, count == replacingChangeCount else { return false }
            restores += 1; restored = snapshot; items = snapshot.items; count += 1; return true
        }
        func write(_ text: String?) { self.text = text; count += 1 }
    }
    private func transaction(_ board: Board, _ clock: Clock) -> SelectionClipboardTransaction {
        .init(pasteboard: board, now: { clock.value }, wait: clock.wait,
              timeout: 0.12, pollInterval: 0.004, settleInterval: 0.02, quietInterval: 0)
    }

    func testMultiClickFallbackCanWaitForAnotherToolsRestoreWithoutTakingItsClipboard() throws {
        let competingClickDeadlines = [2, 3].map { count in
            SelectionCapturePreparation.clickCopyDeadline(clickCount: count, mouseDown: 0, mouseUp: 0,
                                                         doubleClickInterval: 0.5)
        }
        for deadline: TimeInterval? in [nil] + competingClickDeadlines {
            let board = Board(), clock = Clock()
            let originalItems = board.items
            let selectionItems = [[SelectionClipboardRepresentation(type: "public.utf8-plain-text",
                                                                     data: Data("selected word".utf8))]]
            // A second selection tool copied the word and will restore its
            // saved rich clipboard at 330 ms. Both tools serve this gesture.
            board.items = selectionItems
            board.write("selected word")
            var peerRestored = false
            clock.onWait = {
                if !peerRestored, clock.value >= 0.33 {
                    peerRestored = true
                    board.items = originalItems
                    board.write("original")
                }
            }

            clock.value = 0.26
            var preparation = SelectionCapturePreparation(context: 1, earliestCopyTime: deadline)
            if deadline != nil {
                XCTAssertFalse(preparation.beginAttempt(context: 1, now: clock.value))
                let delay = try XCTUnwrap(preparation.delayBeforeAttempt(context: 1, now: clock.value))
                clock.wait(delay)
                XCTAssertTrue(peerRestored)
                XCTAssertEqual(board.snapshots, 0)
            }
            XCTAssertTrue(preparation.beginAttempt(context: 1, now: clock.value))
            var capture = transaction(board, clock)
            capture.quietInterval = 0.06
            var copies = 0
            let result = capture.capture(willCopy: { preparation.copyAttempted(context: 1) }, copy: {
                copies += 1
                board.items = selectionItems
                board.write("selected word")
                return true
            }, canCapture: { true }, userCopyGeneration: { 0 })

            XCTAssertEqual(copies, 1)
            XCTAssertEqual(board.snapshots, 1)
            XCTAssertFalse(preparation.beginAttempt(context: 1, now: clock.value))
            XCTAssertTrue(peerRestored)
            XCTAssertEqual(board.items, originalItems)
            if deadline == nil {
                XCTAssertNil(result)
                XCTAssertEqual(board.restores, 0, "A later writer owns the clipboard")
            } else {
                XCTAssertEqual(result, "selected word")
                XCTAssertEqual(board.restores, 1)
                XCTAssertEqual(board.restored?.items, originalItems)
            }
        }
    }

    func testQuietPreparationWaitsForBackgroundChangesBeforeSnapshot() {
        let board = Board(), clock = Clock()
        var transaction = transaction(board, clock)
        transaction.quietInterval = 0.06
        var backgroundWrites = 0
        clock.onWait = {
            if board.snapshots == 0, clock.value < 0.035, backgroundWrites < 2 {
                board.write("background \(backgroundWrites)"); backgroundWrites += 1
            }
        }
        var copyTime: TimeInterval = -1
        XCTAssertEqual(transaction.capture(copy: {
            copyTime = clock.value; board.write("selected"); return true
        }, canCapture: { true }, userCopyGeneration: { 0 }), "selected")
        XCTAssertGreaterThanOrEqual(copyTime, 0.068)
        XCTAssertEqual(backgroundWrites, 2)
        XCTAssertEqual(board.restored?.capturedChangeCount, 12)
        XCTAssertEqual(board.snapshots, 1)
    }

    func testContinuouslyChangingClipboardStopsBeforeSnapshotOrCopy() {
        let board = Board(), clock = Clock()
        var transaction = transaction(board, clock)
        transaction.quietInterval = 0.06
        clock.onWait = { board.count += 1 }
        var copies = 0
        XCTAssertNil(transaction.capture(copy: { copies += 1; return true },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.snapshots, 0)
        XCTAssertLessThanOrEqual(clock.value, transaction.maximumQuietWait + 0.001)
    }

    func testUserCopyOrContextChangeDuringQuietPreparationCancelsWithoutReadingData() {
        for changeUserCopy in [false, true] {
            let board = Board(), clock = Clock()
            var transaction = transaction(board, clock)
            transaction.quietInterval = 0.06
            var current = true, generation: UInt64 = 0, attempts = 0
            clock.onWait = { if changeUserCopy { generation += 1 } else { current = false } }
            XCTAssertNil(transaction.capture(willCopy: { attempts += 1 }, copy: { true },
                canCapture: { current }, userCopyGeneration: { generation }))
            XCTAssertEqual(attempts, 0)
            XCTAssertEqual(board.snapshots, 0)
            XCTAssertEqual(board.reads, 0)
            XCTAssertEqual(board.restores, 0)
        }
    }

    func testInvalidQuietPreparationConfigurationNeverTouchesClipboard() {
        for mutation in 0..<5 {
            let board = Board(), clock = Clock()
            var transaction = transaction(board, clock)
            switch mutation {
            case 0: transaction.quietInterval = .nan
            case 1: transaction.quietInterval = -1
            case 2: transaction.maximumQuietWait = 0
            case 3: transaction.maximumQuietWait = .infinity
            default: transaction.quietInterval = transaction.maximumQuietWait + 1
            }
            XCTAssertNil(transaction.capture(copy: { XCTFail("No Copy"); return true },
                canCapture: { true }, userCopyGeneration: { 0 }))
            XCTAssertEqual(board.snapshots, 0)
            XCTAssertEqual(board.reads, 0)
        }
    }

    func testWillCopyMarksOnlyTheDispatchBoundaryAfterPreparation() {
        let board = Board(), clock = Clock()
        var order: [String] = []
        XCTAssertEqual(transaction(board, clock).capture(prepareCopy: {
            order.append("prepare"); return true
        }, willCopy: { order.append("attempted") }, copy: {
            order.append("copy"); board.write("selection"); return true
        }, canCapture: { true }, userCopyGeneration: { 0 }), "selection")
        XCTAssertEqual(order, ["prepare", "attempted", "copy"])
    }

    func testPreparationFailureNeverMarksCopyAttempted() {
        for missingSnapshot in [false, true] {
            let board = Board(), clock = Clock()
            board.unreadable = missingSnapshot
            var attempts = 0, copies = 0
            XCTAssertNil(transaction(board, clock).capture(prepareCopy: { false },
                willCopy: { attempts += 1 }, copy: { copies += 1; return true },
                canCapture: { true }, userCopyGeneration: { 0 }))
            XCTAssertEqual(attempts, 0)
            XCTAssertEqual(copies, 0)
        }
    }

    func testFailedDispatchIsStillMarkedAttemptedAndCannotBeRetriedAsPreparation() {
        let board = Board(), clock = Clock()
        var attempts = 0
        XCTAssertNil(transaction(board, clock).capture(willCopy: { attempts += 1 }, copy: { false },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(board.restores, 0)
    }

    func testOneCopyReadsNewSelectionAndRestoresAllOriginalFormats() throws {
        let board = Board(), clock = Clock()
        let originalItems = board.items
        var copies = 0
        let result = transaction(board, clock).capture(copy: {
            copies += 1; board.write("selected 中文 😊"); return true
        }, canCapture: { true }, userCopyGeneration: { 0 })
        XCTAssertEqual(result, "selected 中文 😊")
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(board.restores, 1)
        XCTAssertEqual(board.restored?.capturedChangeCount, 10)
        XCTAssertEqual(board.restored?.items, originalItems)
    }

    func testUnchangedClipboardNeverReturnsOriginalTextOrRestores() {
        let board = Board(), clock = Clock()
        var copies = 0
        let result = transaction(board, clock).capture(copy: { copies += 1; return true },
            canCapture: { true }, userCopyGeneration: { 0 })
        XCTAssertNil(result)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(board.restores, 0)
    }

    func testSelectedTextIdenticalToOriginalStillRequiresNewCount() {
        let board = Board(), clock = Clock()
        XCTAssertEqual(transaction(board, clock).capture(copy: { board.write("original"); return true },
            canCapture: { true }, userCopyGeneration: { 0 }), "original")
        XCTAssertEqual(board.restores, 1)
    }

    func testMissingSnapshotOrStaleSnapshotNeverCopies() {
        for stale in [false, true] {
            let board = Board(), clock = Clock()
            board.unreadable = !stale
            if stale { board.onSnapshot = { board.count += 1 } }
            var copies = 0
            XCTAssertNil(transaction(board, clock).capture(copy: { copies += 1; return true },
                canCapture: { true }, userCopyGeneration: { 0 }))
            XCTAssertEqual(copies, 0)
            XCTAssertEqual(board.restores, 0)
        }
    }

    func testInvalidCaptureContextNeverReadsSnapshotOrCopies() {
        let board = Board(), clock = Clock()
        var copies = 0
        XCTAssertNil(transaction(board, clock).capture(copy: { copies += 1; return true },
            canCapture: { false }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.snapshots, 0)
        XCTAssertEqual(copies, 0)
    }

    func testContextOrUserCopyChangedDuringSnapshotBlocksDispatch() {
        for mutateCopy in [false, true] {
            let board = Board(), clock = Clock()
            var current = true, generation: UInt64 = 0, copies = 0
            board.onSnapshot = { if mutateCopy { generation += 1 } else { current = false } }
            XCTAssertNil(transaction(board, clock).capture(copy: { copies += 1; return true },
                canCapture: { current }, userCopyGeneration: { generation }))
            XCTAssertEqual(copies, 0)
            XCTAssertEqual(board.restores, 0)
        }
    }

    func testFailedCopyDispatchNeverPublishesOrRestores() {
        let board = Board(), clock = Clock()
        XCTAssertNil(transaction(board, clock).capture(copy: { false },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(board.restores, 0)
    }

    func testClipboardWriteDuringCopyPreparationBlocksDispatchAndKeepsLaterOwner() {
        let board = Board(), clock = Clock()
        var copies = 0
        XCTAssertNil(transaction(board, clock).capture(prepareCopy: {
            board.write("later clipboard owner"); clock.value += 0.08; return true
        }, copy: { copies += 1; board.write("selection"); return true },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.restores, 0)
        XCTAssertEqual(board.text, "later clipboard owner")
    }

    func testPreparationFailureChangedContextOrUserCopyBlocksDispatch() {
        for mutation in 0..<3 {
            let board = Board(), clock = Clock()
            var current = true, generation: UInt64 = 0, copies = 0
            XCTAssertNil(transaction(board, clock).capture(prepareCopy: {
                if mutation == 0 { return false }
                if mutation == 1 { current = false } else { generation += 1 }
                return true
            }, copy: { copies += 1; return true }, canCapture: { current },
                userCopyGeneration: { generation }))
            XCTAssertEqual(copies, 0)
            XCTAssertEqual(board.reads, 0)
            XCTAssertEqual(board.restores, 0)
        }
    }

    func testDelayedCopyCanBeReadWithoutRetryingCopy() {
        let board = Board(), clock = Clock()
        var copies = 0
        clock.onWait = { if clock.value >= 0.04 && board.count == 10 { board.write("delayed selection") } }
        XCTAssertEqual(transaction(board, clock).capture(copy: { copies += 1; return true },
            canCapture: { true }, userCopyGeneration: { 0 }), "delayed selection")
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(board.restores, 1)
    }

    func testCopyClearThenCompleteValueWaitsForTextBeforeSettling() {
        let board = Board(), clock = Clock()
        clock.onWait = { if clock.value >= 0.016 && board.count == 11 { board.write("completed selection") } }
        XCTAssertEqual(transaction(board, clock).capture(copy: { board.write(nil); return true },
            canCapture: { true }, userCopyGeneration: { 0 }), "completed selection")
        XCTAssertEqual(board.restores, 1)
    }

    func testInvalidOrMissingCopiedTextNeverPublishesButRestoresObservedCopy() {
        for text: String? in [nil, "", " \n", "not\0text", String(repeating: "x", count: 96_001)] {
            let board = Board(), clock = Clock()
            XCTAssertNil(transaction(board, clock).capture(copy: { board.write(text); return true },
                canCapture: { true }, userCopyGeneration: { 0 }))
            XCTAssertEqual(board.restores, 1)
        }
    }

    func testEmptyOriginalClipboardIsRestoredAsEmptyItems() {
        let board = Board(), clock = Clock()
        board.items = []
        XCTAssertEqual(transaction(board, clock).capture(copy: { board.write("selection"); return true },
            canCapture: { true }, userCopyGeneration: { 0 }), "selection")
        XCTAssertEqual(board.restored?.items, [])
    }

    func testStaleContextAfterObservedCopyRestoresButNeverPublishesText() {
        let board = Board(), clock = Clock()
        var current = true
        clock.onWait = { current = false }
        XCTAssertNil(transaction(board, clock).capture(copy: { board.write("selection"); return true },
            canCapture: { current }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.restores, 1)
    }

    func testContextInvalidBeforeNewCopyObservationDoesNotClaimClipboardOwnership() {
        let board = Board(), clock = Clock()
        var current = true
        XCTAssertNil(transaction(board, clock).capture(copy: {
            board.write("selection"); current = false; return true
        }, canCapture: { current }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(board.restores, 0)
    }

    func testUserCopyAfterDispatchIsNeverOverwritten() {
        let board = Board(), clock = Clock()
        var generation: UInt64 = 0
        clock.onWait = { generation += 1; board.write("user copied later") }
        XCTAssertNil(transaction(board, clock).capture(copy: { board.write("selection"); return true },
            canCapture: { true }, userCopyGeneration: { generation }))
        XCTAssertEqual(board.text, "user copied later")
        XCTAssertEqual(board.restores, 0)
    }

    func testLaterWriteEvenWithIdenticalTextNeverGetsRestored() {
        let board = Board(), clock = Clock()
        clock.onWait = { if board.count == 11 { board.write("selection") } }
        XCTAssertNil(transaction(board, clock).capture(copy: { board.write("selection"); return true },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.restores, 0)
        XCTAssertEqual(board.count, 12)
    }

    func testChangeDuringTextReadCannotBeReturnedOrRestoredAsOwnedCopy() {
        let board = Board(), clock = Clock()
        board.onRead = { board.count += 1; clock.value += 0.005 }
        XCTAssertNil(transaction(board, clock).capture(copy: { board.write("selection"); return true },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.restores, 0)
    }

    func testFailedRestorationNeverPublishesText() {
        let board = Board(), clock = Clock()
        board.restoreAllowed = false
        XCTAssertNil(transaction(board, clock).capture(copy: { board.write("selection"); return true },
            canCapture: { true }, userCopyGeneration: { 0 }))
        XCTAssertEqual(board.restores, 0)
    }

    func testSnapshotSizeAndRepresentationLimitsBlockCopy() {
        for mutation in 0..<5 {
            let board = Board(), clock = Clock()
            var transaction = transaction(board, clock)
            switch mutation {
            case 0: transaction.limits.maximumTotalBytes = 2
            case 1: transaction.limits.maximumRepresentationBytes = 2
            case 2: transaction.limits.maximumRepresentationsPerItem = 1
            case 3: board.items.append(board.items[0]); transaction.limits.maximumItems = 1
            default: board.items[0].append(board.items[0][0])
            }
            var copies = 0
            XCTAssertNil(transaction.capture(copy: { copies += 1; return true },
                canCapture: { true }, userCopyGeneration: { 0 }))
            XCTAssertEqual(copies, 0)
        }
    }

    func testInvalidTimingAndLimitsNeverTouchClipboard() {
        for mutation in 0..<5 {
            let board = Board(), clock = Clock()
            var transaction = transaction(board, clock)
            switch mutation {
            case 0: transaction.timeout = 0
            case 1: transaction.pollInterval = 0
            case 2: transaction.settleInterval = transaction.timeout + 1
            case 3: transaction.limits.maximumTotalBytes = 0
            default: transaction.limits.maximumSnapshotSeconds = 0
            }
            XCTAssertNil(transaction.capture(copy: { XCTFail("No Copy"); return true },
                canCapture: { true }, userCopyGeneration: { 0 }))
            XCTAssertEqual(board.snapshots, 0)
        }
    }

    func testSystemAdapterPreservesOrderedItemsAndAllFormatsOnIsolatedPasteboard() throws {
        let board = NSPasteboard(name: .init("SelectionClipboardTransactionTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        XCTAssertTrue(first.setString("known synthetic marker", forType: .string))
        XCTAssertTrue(first.setData(Data([0, 1, 2, 255]), forType: .init("org.example.binary")))
        XCTAssertTrue(second.setString("second item", forType: .string))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([first, second]))
        let adapter = SystemSelectionClipboard(board: board)
        let snapshot = try XCTUnwrap(adapter.snapshot(limits: .init()))
        board.clearContents(); board.setString("known synthetic selection", forType: .string)
        XCTAssertTrue(adapter.restore(snapshot, replacingChangeCount: board.changeCount))
        let restored = try XCTUnwrap(adapter.snapshot(limits: .init()))
        XCTAssertEqual(restored.items, snapshot.items)
    }

    func testSystemAdapterRefusesStaleCountBeforeReplacingIsolatedPasteboard() throws {
        let board = NSPasteboard(name: .init("SelectionClipboardTransactionTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("marker", forType: .string)
        let adapter = SystemSelectionClipboard(board: board)
        let snapshot = try XCTUnwrap(adapter.snapshot(limits: .init()))
        let oldCount = board.changeCount
        board.clearContents(); board.setString("later owner", forType: .string)
        XCTAssertFalse(adapter.restore(snapshot, replacingChangeCount: oldCount))
        XCTAssertEqual(board.string(forType: .string), "later owner")
    }
}
