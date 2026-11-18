import AppKit
import ApplicationServices
import MacHelper

struct SelectionPasteKeyEvent: Equatable {
    let processIdentifier: Int32
    let virtualKey: UInt16
    let keyDown: Bool
    let command: Bool

    static func commandV(to pid: Int32) -> [Self] {
        [.init(processIdentifier: pid, virtualKey: 9, keyDown: true, command: true),
         .init(processIdentifier: pid, virtualKey: 9, keyDown: false, command: true)]
    }
    static func isFixedCommandV(_ events: [Self]) -> Bool {
        guard let pid = events.first?.processIdentifier, pid > 1 else { return false }
        return events == commandV(to: pid)
    }
}

enum SelectionPasteboardOwnership {
    static func matches(changeCount expected: Int, ownerStamp: String,
                        currentChangeCount: () -> Int, readOwnedStamp: () -> String?) -> Bool {
        guard currentChangeCount() == expected else { return false }
        let stamp = readOwnedStamp()
        return stamp == ownerStamp && currentChangeCount() == expected
    }
}

@MainActor
protocol SelectionPasteboardAccess: AnyObject {
    /// Replaces the clipboard with the completed result and a private nonce.
    /// No method exposes prior clipboard contents or any restore operation.
    func writeOwnedResult(_ text: String, ownerStamp: String) -> Int?
    func owns(changeCount: Int, ownerStamp: String) -> Bool
}

@MainActor
protocol SelectionPasteEventAccess: AnyObject {
    func preflight() -> Bool
    func post(_ events: [SelectionPasteKeyEvent]) -> Bool
}

enum SelectionPasteFailure: Error, Equatable, LocalizedError {
    case invalidResult, changedTarget, accessDenied, clipboardWriteFailed, clipboardChanged, eventUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidResult: return L("The extension returned an invalid or stale result.")
        case .changedTarget: return L("The selection changed. Paste was cancelled; the preview is still available to copy.")
        case .accessDenied: return L("Allow MacHelper to post keyboard events in Accessibility settings, then try again.")
        case .clipboardWriteFailed: return L("The result could not be placed on the clipboard. Use Copy instead.")
        case .clipboardChanged: return L("The clipboard changed before pasting. Nothing was pasted; use Copy.")
        case .eventUnavailable: return L("Paste could not be requested. The preview is still available to copy.")
        }
    }
}

/// One deliberate Apply attempt. Clipboard contents intentionally remain the
/// result: snapshot/restore could expose old secrets or race a delayed paste.
@MainActor
struct SelectionPasteTransaction {
    let pasteboard: SelectionPasteboardAccess
    let eventPoster: SelectionPasteEventAccess
    var makeOwnerStamp: () -> String = { UUID().uuidString }

    func perform(text: String, sourcePID: Int32, validateTarget: () -> Bool) throws {
        guard sourcePID > 1, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 96_000, !text.contains("\0") else { throw SelectionPasteFailure.invalidResult }
        guard validateTarget() else { throw SelectionPasteFailure.changedTarget }
        guard eventPoster.preflight() else { throw SelectionPasteFailure.accessDenied }
        let stamp = makeOwnerStamp()
        guard !stamp.isEmpty, let count = pasteboard.writeOwnedResult(text, ownerStamp: stamp) else {
            throw SelectionPasteFailure.clipboardWriteFailed
        }
        guard pasteboard.owns(changeCount: count, ownerStamp: stamp) else { throw SelectionPasteFailure.clipboardChanged }
        guard validateTarget() else { throw SelectionPasteFailure.changedTarget }
        guard eventPoster.preflight() else { throw SelectionPasteFailure.accessDenied }
        guard validateTarget() else { throw SelectionPasteFailure.changedTarget }
        // AX validation can take time; check our exact clipboard ownership
        // again immediately before the fixed event pair. No retry is allowed.
        guard pasteboard.owns(changeCount: count, ownerStamp: stamp) else { throw SelectionPasteFailure.clipboardChanged }
        guard eventPoster.post(SelectionPasteKeyEvent.commandV(to: sourcePID)) else {
            throw SelectionPasteFailure.eventUnavailable
        }
    }
}

@MainActor
final class SystemSelectionPasteboard: SelectionPasteboardAccess {
    private static let ownerType = NSPasteboard.PasteboardType("com.localaibasetools.selection-paste-owner")
    func writeOwnedResult(_ text: String, ownerStamp: String) -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string), item.setString(ownerStamp, forType: Self.ownerType) else { return nil }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects([item]) else { return nil }
        return board.changeCount
    }
    func owns(changeCount: Int, ownerStamp: String) -> Bool {
        let board = NSPasteboard.general
        // Only read our newly written private stamp after its change count
        // matches. Never read .string, pasteboardItems, previous data or URLs.
        return SelectionPasteboardOwnership.matches(changeCount: changeCount, ownerStamp: ownerStamp,
            currentChangeCount: { board.changeCount }, readOwnedStamp: { board.string(forType: Self.ownerType) })
    }
}

@MainActor
final class SystemSelectionPasteEventPoster: SelectionPasteEventAccess {
    func preflight() -> Bool { CGPreflightPostEventAccess() }
    func post(_ events: [SelectionPasteKeyEvent]) -> Bool {
        guard SelectionPasteKeyEvent.isFixedCommandV(events), let pid = events.first?.processIdentifier else { return false }
        // Construct both events before posting either. There is no arbitrary
        // key API, app activation, Enter/Send, key repeat or range forcing.
        let keyboardEvents = events.compactMap { descriptor -> CGEvent? in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: descriptor.virtualKey, keyDown: descriptor.keyDown)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            return event
        }
        guard keyboardEvents.count == 2 else { return false }
        for event in keyboardEvents { event.postToPid(pid) }
        return true
    }
}
