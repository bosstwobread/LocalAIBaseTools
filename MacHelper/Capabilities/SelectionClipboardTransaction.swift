import AppKit
import Foundation

/// Limits apply to retained in-memory data. Nothing is serialized or logged.
struct SelectionClipboardLimits {
    var maximumItems = 32
    var maximumRepresentationsPerItem = 64
    var maximumRepresentationBytes = 8 * 1024 * 1024
    var maximumTotalBytes = 16 * 1024 * 1024
    var maximumSnapshotSeconds: TimeInterval = 0.5

    var isValid: Bool {
        maximumItems > 0 && maximumRepresentationsPerItem > 0 &&
            maximumRepresentationBytes > 0 && maximumTotalBytes > 0 &&
            maximumSnapshotSeconds > 0 && maximumSnapshotSeconds <= 1
    }
}

struct SelectionClipboardRepresentation: Equatable {
    let type: String
    let data: Data
}

/// The order of items and their representations is retained. A missing/lazy
/// representation makes capture unavailable instead of taking a partial copy.
struct SelectionClipboardSnapshot: Equatable {
    let capturedChangeCount: Int
    let items: [[SelectionClipboardRepresentation]]

    func isValid(limits: SelectionClipboardLimits) -> Bool {
        guard limits.isValid, items.count <= limits.maximumItems else { return false }
        var total = 0
        for item in items {
            guard !item.isEmpty, item.count <= limits.maximumRepresentationsPerItem else { return false }
            var types: Set<String> = []
            for representation in item {
                guard !representation.type.isEmpty, types.insert(representation.type).inserted,
                      representation.data.count <= limits.maximumRepresentationBytes,
                      representation.data.count <= limits.maximumTotalBytes - total else { return false }
                total += representation.data.count
            }
        }
        return true
    }
}

/// This boundary is separate from Apply's pasteboard adapter. Apply continues
/// to leave its result on the clipboard; only automatic capture uses snapshots.
protocol SelectionClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot(limits: SelectionClipboardLimits) -> SelectionClipboardSnapshot?
    func copiedString() -> String?
    /// Recheck ownership immediately before replacing anything. Implementations
    /// must prepare all replacement items before clearing the pasteboard.
    func restore(_ snapshot: SelectionClipboardSnapshot, replacingChangeCount: Int) -> Bool
}

/// One bounded, caller-authorized Copy attempt, run on the selection read queue.
/// The caller owns gesture/source/protection checks and the fixed Copy action.
/// Polling this object again is not a retry mechanism.
struct SelectionClipboardTransaction {
    let pasteboard: SelectionClipboardAccess
    var limits = SelectionClipboardLimits()
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var timeout: TimeInterval = 0.45
    var pollInterval: TimeInterval = 0.004
    var settleInterval: TimeInterval = 0.03
    var quietInterval: TimeInterval = 0.06
    var maximumQuietWait: TimeInterval = 0.25

    func capture(prepareCopy: () -> Bool = { true }, willCopy: () -> Void = {},
                 copy: () -> Bool, canCapture: () -> Bool,
                 userCopyGeneration: () -> UInt64) -> String? {
        guard limits.isValid, timeout > 0, timeout <= 1.5,
              pollInterval > 0, pollInterval <= timeout,
              settleInterval >= 0, settleInterval <= timeout,
              quietInterval.isFinite, quietInterval >= 0,
              maximumQuietWait.isFinite, maximumQuietWait > 0, maximumQuietWait <= 1,
              quietInterval <= maximumQuietWait,
              canCapture() else { return nil }
        let userGeneration = userCopyGeneration()
        // Let a fast, already-running clipboard operation finish before taking
        // the original snapshot. This is read-only preparation, not a second
        // Copy attempt or permission to overwrite another writer later.
        guard waitForQuietClipboard(canCapture: canCapture, userCopyGeneration: userCopyGeneration,
                                    expectedUserGeneration: userGeneration) else { return nil }
        guard let original = pasteboard.snapshot(limits: limits), original.isValid(limits: limits),
              pasteboard.changeCount == original.capturedChangeCount,
              userCopyGeneration() == userGeneration, canCapture() else { return nil }
        // AX target validation can be slow. Do it before the final clipboard
        // and user-intent checks, leaving only the fixed, fast dispatch in Copy.
        guard prepareCopy(), pasteboard.changeCount == original.capturedChangeCount,
              userCopyGeneration() == userGeneration, canCapture() else { return nil }
        // The coordinator treats even an unsuccessful/uncertain dispatch as
        // terminal. This callback never runs for a preparation-only failure.
        willCopy()
        guard copy() else { return nil }

        let deadline = now() + timeout
        var observed: (count: Int, text: String?, since: TimeInterval)?
        var candidate: String?
        var remainsCurrent = true

        while now() <= deadline {
            guard userCopyGeneration() == userGeneration else { return nil }
            guard canCapture() else { remainsCurrent = false; break }
            let count = pasteboard.changeCount
            if count != original.capturedChangeCount {
                if let previous = observed, previous.count != count,
                   previous.text.map(SelectionSpanReader.validText) == true {
                    // A later writer after a complete copied value is not ours
                    // to undo, even when the text happens to be identical.
                    return nil
                }
                let text = pasteboard.copiedString()
                guard pasteboard.changeCount == count,
                      userCopyGeneration() == userGeneration else { continue }
                guard canCapture() else { remainsCurrent = false; break }
                if observed?.count != count || observed?.text != text {
                    observed = (count, text, now())
                }
                if let text, SelectionSpanReader.validText(text), let observed,
                   now() - observed.since >= settleInterval {
                    candidate = text
                    break
                }
            }
            wait(min(pollInterval, max(0, deadline - now())))
            if now() >= deadline { break }
        }

        // A stable value was observed only while the original capture context
        // was valid. Context cancellation never returns text, but a value we
        // already observed may still be restored if nobody else copied/wrote.
        guard let observed, userCopyGeneration() == userGeneration,
              pasteboard.changeCount == observed.count else { return nil }
        let sameText = pasteboard.copiedString() == observed.text
        guard sameText, pasteboard.changeCount == observed.count,
              userCopyGeneration() == userGeneration else { return nil }
        let currentBeforeRestore = remainsCurrent && canCapture()
        guard pasteboard.restore(original, replacingChangeCount: observed.count) else { return nil }
        guard currentBeforeRestore, canCapture(), userCopyGeneration() == userGeneration else { return nil }
        return candidate
    }

    private func waitForQuietClipboard(canCapture: () -> Bool, userCopyGeneration: () -> UInt64,
                                       expectedUserGeneration: UInt64) -> Bool {
        guard quietInterval > 0 else { return canCapture() && userCopyGeneration() == expectedUserGeneration }
        let started = now()
        guard started.isFinite else { return false }
        let deadline = started + maximumQuietWait
        var stableSince = started
        var count = pasteboard.changeCount
        var previousTime = started
        while true {
            let time = now()
            guard time.isFinite, time >= previousTime, canCapture(),
                  userCopyGeneration() == expectedUserGeneration else { return false }
            previousTime = time
            let currentCount = pasteboard.changeCount
            if currentCount != count { count = currentCount; stableSince = time }
            if time - stableSince >= quietInterval { return true }
            guard time < deadline else { return false }
            wait(min(pollInterval, deadline - time, stableSince + quietInterval - time))
        }
    }
}

/// NSPasteboard has no atomic compare-and-swap. All count checks therefore
/// reduce the race window but cannot promise restoration under every concurrent
/// writer or for a source app that completes Copy after the bounded deadline.
final class SystemSelectionClipboard: SelectionClipboardAccess {
    private let board: NSPasteboard
    init(board: NSPasteboard = .general) { self.board = board }
    var changeCount: Int { board.changeCount }

    func snapshot(limits: SelectionClipboardLimits) -> SelectionClipboardSnapshot? {
        guard limits.isValid else { return nil }
        let count = board.changeCount
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maximumSnapshotSeconds
        guard let sourceItems = board.pasteboardItems else {
            guard board.types?.isEmpty != false, board.changeCount == count else { return nil }
            return .init(capturedChangeCount: count, items: [])
        }
        guard sourceItems.count <= limits.maximumItems else { return nil }
        var items: [[SelectionClipboardRepresentation]] = []
        var total = 0
        for item in sourceItems {
            let types = item.types
            guard !types.isEmpty, types.count <= limits.maximumRepresentationsPerItem else { return nil }
            var representations: [SelectionClipboardRepresentation] = []
            for type in types {
                guard ProcessInfo.processInfo.systemUptime <= deadline, board.changeCount == count,
                      let data = item.data(forType: type), data.count <= limits.maximumRepresentationBytes,
                      data.count <= limits.maximumTotalBytes - total else { return nil }
                representations.append(.init(type: type.rawValue, data: Data(data)))
                total += data.count
            }
            guard item.types == types else { return nil }
            items.append(representations)
        }
        let result = SelectionClipboardSnapshot(capturedChangeCount: count, items: items)
        guard ProcessInfo.processInfo.systemUptime <= deadline, board.changeCount == count,
              result.isValid(limits: limits) else { return nil }
        return result
    }

    func copiedString() -> String? { board.string(forType: .string) }

    func restore(_ snapshot: SelectionClipboardSnapshot, replacingChangeCount: Int) -> Bool {
        var items: [NSPasteboardItem] = []
        for representations in snapshot.items {
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(representation.data, forType: .init(representation.type)) else { return false }
            }
            items.append(item)
        }
        guard board.changeCount == replacingChangeCount else { return false }
        board.clearContents()
        return items.isEmpty || board.writeObjects(items)
    }
}
