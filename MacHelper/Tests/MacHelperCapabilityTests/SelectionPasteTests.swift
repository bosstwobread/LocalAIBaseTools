import XCTest
@testable import MacHelperCapabilities

@MainActor
final class SelectionPasteTests: XCTestCase {
    private final class Trace { var values: [String] = [] }
    private final class Board: SelectionPasteboardAccess {
        let trace: Trace
        var result: String?
        var stamp: String?
        var count = 10
        var writes = 0
        var checks = 0
        var failWrite = false
        var changeCountOnCheck: Int?
        var changeStampOnCheck: Int?
        var onWrite: (() -> Void)?
        init(_ trace: Trace) { self.trace = trace }
        func writeOwnedResult(_ text: String, ownerStamp: String) -> Int? {
            trace.values.append("write")
            writes += 1
            guard !failWrite else { return nil }
            result = text; stamp = ownerStamp; count += 1
            let owned = count
            onWrite?()
            return owned
        }
        func owns(changeCount: Int, ownerStamp: String) -> Bool {
            trace.values.append("owner")
            checks += 1
            if changeCountOnCheck == checks { count += 1 }
            if changeStampOnCheck == checks { stamp = "foreign-owner" }
            return count == changeCount && stamp == ownerStamp
        }
    }
    private final class Poster: SelectionPasteEventAccess {
        let trace: Trace
        var preflights = 0
        var denyPreflight: Int?
        var requests: [[SelectionPasteKeyEvent]] = []
        var canPost = true
        var onPreflight: ((Int) -> Void)?
        init(_ trace: Trace) { self.trace = trace }
        func preflight() -> Bool {
            trace.values.append("preflight"); preflights += 1
            onPreflight?(preflights)
            return denyPreflight != preflights
        }
        func post(_ events: [SelectionPasteKeyEvent]) -> Bool {
            trace.values.append("post"); requests.append(events); return canPost
        }
    }
    private func transaction(_ board: Board, _ poster: Poster) -> SelectionPasteTransaction {
        .init(pasteboard: board, eventPoster: poster, makeOwnerStamp: { "fresh-test-owner" })
    }

    func testExplicitPasteWritesOnlyResultThenValidatesOwnershipAndPostsFixedPair() async throws {
        let trace = Trace()
        let board = Board(trace), poster = Poster(trace)
        // The boundary deliberately has no read-old-clipboard/restore method.
        try transaction(board, poster).perform(text: "Polished 中文 😊", sourcePID: 42) {
            trace.values.append("target"); return true
        }
        XCTAssertEqual(board.result, "Polished 中文 😊")
        XCTAssertEqual(board.stamp, "fresh-test-owner")
        XCTAssertEqual(board.writes, 1)
        XCTAssertEqual(poster.requests, [SelectionPasteKeyEvent.commandV(to: 42)])
        XCTAssertEqual(trace.values, ["target", "preflight", "write", "owner", "target", "preflight", "target", "owner", "post"])
    }

    func testChangedTargetOrActivationAfterClipboardWriteBlocksPasteWithoutRestore() async {
        for mutation in 0..<7 {
            let trace = Trace()
            let board = Board(trace), poster = Poster(trace)
            var pid: Int32? = 42, sameFocus = true, range = NSRange(location: 7, length: 5)
            var selected = "draft", protected = false, enabled = true, ownerMatches = true
            let evidence = SelectionReplacementEvidence(processIdentifier: 42, range: range, text: selected)
            board.onWrite = {
                switch mutation {
                case 0: pid = 99
                case 1: sameFocus = false
                case 2: range.location += 1
                case 3: selected = "other"
                case 4: protected = true
                case 5: enabled = false
                default: ownerMatches = false
                }
            }
            XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) {
                trace.values.append("target")
                return ownerMatches && evidence.accepts(processIdentifier: pid, sameFocusedElement: sameFocus,
                    currentRange: range, currentText: selected, protected: protected, settable: true, enabled: enabled)
            }) { XCTAssertEqual($0 as? SelectionPasteFailure, .changedTarget) }
            XCTAssertEqual(board.result, "result", "No prior clipboard snapshot is restored after a cancelled dispatch")
            XCTAssertEqual(board.writes, 1)
            XCTAssertTrue(poster.requests.isEmpty)
        }
    }

    func testLostClipboardChangeCountOrPrivateStampBlocksBothDispatchWindows() async {
        for (check, changeStamp) in [(1, false), (2, false), (1, true), (2, true)] {
            let trace = Trace()
            let board = Board(trace), poster = Poster(trace)
            if changeStamp { board.changeStampOnCheck = check } else { board.changeCountOnCheck = check }
            XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) { true }) {
                XCTAssertEqual($0 as? SelectionPasteFailure, .clipboardChanged)
            }
            XCTAssertEqual(board.writes, 1)
            XCTAssertTrue(poster.requests.isEmpty)
            XCTAssertFalse(trace.values.contains("post"))
        }
    }

    func testTargetChangeDuringFinalPermissionPreflightStillBlocksDispatch() async {
        let trace = Trace()
        let board = Board(trace), poster = Poster(trace)
        var current = true
        poster.onPreflight = { if $0 == 2 { current = false } }
        XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) { current }) {
            XCTAssertEqual($0 as? SelectionPasteFailure, .changedTarget)
        }
        XCTAssertEqual(board.writes, 1)
        XCTAssertTrue(poster.requests.isEmpty)
        XCTAssertFalse(trace.values.contains("post"))
    }

    func testDeniedPostAccessNeverRequestsPermissionAndNeverDispatches() async {
        for deniedCheck in [1, 2] {
            let trace = Trace()
            let board = Board(trace), poster = Poster(trace)
            poster.denyPreflight = deniedCheck
            XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) { true }) {
                XCTAssertEqual($0 as? SelectionPasteFailure, .accessDenied)
            }
            XCTAssertEqual(board.writes, deniedCheck == 1 ? 0 : 1)
            XCTAssertTrue(poster.requests.isEmpty)
            XCTAssertFalse(trace.values.contains("post"))
        }
    }

    func testInvalidResultChangedInitialTargetAndFailedWriteNeverDispatch() async {
        for text in ["", " \n", "NUL\0text", String(repeating: "x", count: 96_001)] {
            let trace = Trace()
            let board = Board(trace), poster = Poster(trace)
            XCTAssertThrowsError(try transaction(board, poster).perform(text: text, sourcePID: 42) { true }) {
                XCTAssertEqual($0 as? SelectionPasteFailure, .invalidResult)
            }
            XCTAssertEqual(board.writes, 0); XCTAssertEqual(poster.preflights, 0)
            XCTAssertTrue(poster.requests.isEmpty); XCTAssertTrue(trace.values.isEmpty)
        }
        let trace = Trace()
        let board = Board(trace), poster = Poster(trace)
        XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) { false }) {
            XCTAssertEqual($0 as? SelectionPasteFailure, .changedTarget)
        }
        XCTAssertEqual(board.writes, 0)
        board.failWrite = true
        XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) { true }) {
            XCTAssertEqual($0 as? SelectionPasteFailure, .clipboardWriteFailed)
        }
        XCTAssertTrue(poster.requests.isEmpty); XCTAssertFalse(trace.values.contains("post"))
    }

    func testEventFailureIsNotRetriedAndFixedPlanRejectsEnterArbitraryKeysAndWrongPID() async {
        let trace = Trace()
        let board = Board(trace), poster = Poster(trace)
        poster.canPost = false
        XCTAssertThrowsError(try transaction(board, poster).perform(text: "result", sourcePID: 42) { true }) {
            XCTAssertEqual($0 as? SelectionPasteFailure, .eventUnavailable)
        }
        XCTAssertEqual(poster.requests.count, 1); XCTAssertEqual(board.writes, 1)
        let valid = SelectionPasteKeyEvent.commandV(to: 42)
        XCTAssertEqual(valid.count, 2)
        XCTAssertEqual(valid.map(\.virtualKey), [9, 9]); XCTAssertEqual(valid.map(\.keyDown), [true, false])
        XCTAssertEqual(valid.map(\.processIdentifier), [42, 42]); XCTAssertTrue(valid.allSatisfy(\.command))
        XCTAssertTrue(SelectionPasteKeyEvent.isFixedCommandV(valid))
        let invalid: [[SelectionPasteKeyEvent]] = [[], [valid[0]], valid + [valid[0]],
            [.init(processIdentifier: 42, virtualKey: 36, keyDown: true, command: true), valid[1]],
            [.init(processIdentifier: 42, virtualKey: 9, keyDown: true, command: false), valid[1]],
            [valid[0], .init(processIdentifier: 99, virtualKey: 9, keyDown: false, command: true)],
            SelectionPasteKeyEvent.commandV(to: 1)]
        for events in invalid { XCTAssertFalse(SelectionPasteKeyEvent.isFixedCommandV(events)) }
        XCTAssertEqual(trace.values.last, "post")
    }

    func testPasteEditableEvidenceExcludesReadOnlyProtectedDisabledAndDocumentNodes() async {
        for role in ["AXTextField", "AXTextArea"] {
            XCTAssertTrue(SelectionPasteEditability.accepts(role: role, enabled: true, protected: false, valueSettable: true))
        }
        for (role, enabled, protected, writable) in [
            ("AXWebArea", true, false, true), ("AXStaticText", true, false, true),
            ("AXTextArea", false, false, true), ("AXTextArea", true, true, true), ("AXTextArea", true, false, false)
        ] {
            XCTAssertFalse(SelectionPasteEditability.accepts(role: role, enabled: enabled, protected: protected, valueSettable: writable))
        }
    }

    func testOwnershipBracketsPrivateStampReadAndRejectsPreservedStampWithChangedCount() async {
        var count = 11
        var reads = 0
        XCTAssertTrue(SelectionPasteboardOwnership.matches(changeCount: 11, ownerStamp: "ours",
            currentChangeCount: { count }, readOwnedStamp: { reads += 1; return "ours" }))
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(SelectionPasteboardOwnership.matches(changeCount: 11, ownerStamp: "ours",
            currentChangeCount: { count }, readOwnedStamp: { reads += 1; count += 1; return "ours" }),
            "A clipboard manager preserving our stamp still loses ownership when the count changes during the read")
        let before = reads
        XCTAssertFalse(SelectionPasteboardOwnership.matches(changeCount: 11, ownerStamp: "ours",
            currentChangeCount: { count }, readOwnedStamp: { reads += 1; return "ours" }))
        XCTAssertEqual(reads, before, "A foreign generation must not be read even for its private stamp")
    }
}
