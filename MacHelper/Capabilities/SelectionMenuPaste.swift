import AppKit
import ApplicationServices

/// A title is an additional signal for editors that reuse one window across
/// documents. An AX error is distinct from a window explicitly lacking a title.
enum SelectionMenuWindowTitle: Equatable {
    case missing
    case value(String)

    static func read(_ window: AXUIElement) -> Self? {
        AXUIElementSetMessagingTimeout(window, 0.08)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) {
        case .noValue, .attributeUnsupported: return .missing
        case .success: return (value as? String).map(Self.value)
        default: return nil
        }
    }
}

enum SelectionEditMenuCommand {
    case cut, paste

    private static let cutTitles: Set<String> = [
        "cut", "剪切", "剪下", "剪裁", "cortar", "recortar", "couper", "ausschneiden",
        "taglia", "カット", "잘라내기", "вырезать", "قص", "काटें", "कट",
    ]
    private static let pasteTitles: Set<String> = [
        "paste", "粘贴", "黏贴", "貼上", "粘貼", "黏貼", "pegar", "colar", "coller", "einfügen",
        "incolla", "ペースト", "貼り付け", "붙여넣기", "붙이기", "вставить", "لصق", "पेस्ट", "चिपकाएँ",
    ]

    init?(title: String?) {
        guard let title else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.cutTitles.contains(name) { self = .cut }
        else if Self.pasteTitles.contains(name) { self = .paste }
        else { return nil }
    }

    /// A direct Edit menu item needs the exact standard title. If it also
    /// advertises a shortcut, require the conventional unmodified Command key.
    func acceptsShortcut(status: AXError, character: String?, modifiers: Int?) -> Bool {
        if SelectionCopyMenuIdentity.reportsNoShortcut(status: status, character: character) { return true }
        return status == .success && character?.lowercased() == (self == .cut ? "x" : "v") && modifiers == 0
    }
}

/// WPS can expose only its clipboard commands while a word/paragraph is
/// selected. Edit > Cut being enabled is used as evidence of an editable
/// selection. Cut is never executed. Menus cannot establish a numeric range.
private struct SelectionEditMenu {
    let cut: AXUIElement
    let paste: AXUIElement
    let pid: pid_t

    static func read(from source: SelectionCopyTarget, continuing: () -> Bool) -> Self? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        func allowed() -> Bool { continuing() && ProcessInfo.processInfo.systemUptime < deadline }
        func owned(_ element: AXUIElement) -> Bool {
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success && pid == source.process.processIdentifier
        }
        func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
            guard allowed(), owned(element) else { return (.cannotComplete, nil) }
            AXUIElementSetMessagingTimeout(element, 0.06)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (status, status == .success ? value : nil)
        }
        func children(_ element: AXUIElement) -> [AXUIElement]? {
            guard allowed(), owned(element) else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.06)
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 65, &children) == .success,
                  let nodes = children as? [AnyObject], nodes.count <= 64,
                  nodes.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return nodes.map { $0 as! AXUIElement }
        }
        guard let bar = attribute(source.application, kAXMenuBarAttribute).1,
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let barItems = children(bar as! AXUIElement),
              let edit = SelectionCopyMenuIdentity.editMenuIndex(in: barItems, title: {
                  attribute($0, kAXTitleAttribute).1 as? String
              }), let menus = children(barItems[edit]), menus.count == 1, let menu = menus.first,
              attribute(menu, kAXRoleAttribute).1 as? String == kAXMenuRole,
              let items = children(menu) else { return nil }
        var commands: [SelectionEditMenuCommand: AXUIElement] = [:]
        for item in items {
            guard allowed() else { return nil }
            guard let command = SelectionEditMenuCommand(title: attribute(item, kAXTitleAttribute).1 as? String),
                  attribute(item, kAXRoleAttribute).1 as? String == kAXMenuItemRole else { continue }
            let (status, value) = attribute(item, kAXMenuItemCmdCharAttribute)
            let character = value as? String
            let modifiers = character?.isEmpty == false ? attribute(item, kAXMenuItemCmdModifiersAttribute).1 as? Int : nil
            guard command.acceptsShortcut(status: status, character: character, modifiers: modifiers),
                  commands[command] == nil else { return nil }
            commands[command] = item
        }
        guard allowed(), let cut = commands[.cut], let paste = commands[.paste] else { return nil }
        return .init(cut: cut, paste: paste, pid: source.process.processIdentifier)
    }

    func available(afterStagingText: Bool) -> Bool {
        func enabled(_ item: AXUIElement, as expected: SelectionEditMenuCommand) -> Bool? {
            var actual: pid_t = 0
            var role: CFTypeRef?
            var title: CFTypeRef?
            var value: CFTypeRef?
            AXUIElementSetMessagingTimeout(item, 0.06)
            guard AXUIElementGetPid(item, &actual) == .success, actual == pid,
                  AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXMenuItemRole,
                  AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title) == .success,
                  SelectionEditMenuCommand(title: title as? String) == expected,
                  AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value as? Bool
        }
        return SelectionMenuPasteTransaction.commandsAvailable(cutEnabled: enabled(cut, as: .cut), pasteEnabled: enabled(paste, as: .paste),
                                                               afterStagingText: afterStagingText)
    }

    func requestPaste() -> Bool {
        var actual: pid_t = 0
        guard AXUIElementGetPid(paste, &actual) == .success, actual == pid else { return false }
        // A timeout can arrive after the app received the press. In either case
        // report only the request and never retry an ambiguous write.
        return [.success, .cannotComplete, .failure].contains(AXUIElementPerformAction(paste, kAXPressAction as CFString))
    }
}

@MainActor
struct SelectionMenuPasteTransaction {
    let pasteboard: SelectionPasteboardAccess

    nonisolated static func commandsAvailable(cutEnabled: Bool?, pasteEnabled: Bool?, afterStagingText: Bool) -> Bool {
        // Paste may be disabled because the prior clipboard is empty/unsupported.
        // It must be verifiably enabled before dispatching with the staged result.
        cutEnabled == true && pasteEnabled != nil && (!afterStagingText || pasteEnabled == true)
    }

    nonisolated static func preservingSelectionEdges(_ result: String, original: String) -> String? {
        guard !original.isEmpty, original.utf8.count <= 96_000,
              result.utf8.count <= 96_000, !result.contains("\0"),
              let first = original.firstIndex(where: { !$0.isWhitespace }),
              let last = original.lastIndex(where: { !$0.isWhitespace }),
              let resultStart = result.firstIndex(where: { !$0.isWhitespace }),
              let resultEnd = result.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        // Double-click often includes a trailing space and selecting a paragraph
        // may include its terminator. Preserve exactly the captured separators.
        let pending = String(original[..<first]) + result[resultStart...resultEnd] + original[original.index(after: last)...]
        return pending.utf8.count <= 96_000 ? String(pending) : nil
    }

    func perform(_ result: String, original: String, validate: (_ afterStagingText: Bool) -> Bool,
                 requestPaste: () -> Bool) throws -> SelectionReplacementOutcome {
        guard let text = Self.preservingSelectionEdges(result, original: original) else {
            throw SelectionPasteFailure.invalidResult
        }
        guard validate(false) else { throw SelectionPasteFailure.changedTarget }
        let stamp = UUID().uuidString
        guard let count = pasteboard.writeOwnedResult(text, ownerStamp: stamp) else { throw SelectionPasteFailure.clipboardWriteFailed }
        guard pasteboard.owns(changeCount: count, ownerStamp: stamp) else { throw SelectionPasteFailure.clipboardChanged }
        guard validate(true) else { throw SelectionPasteFailure.changedTarget }
        guard pasteboard.owns(changeCount: count, ownerStamp: stamp) else { throw SelectionPasteFailure.clipboardChanged }
        guard requestPaste() else { throw SelectionPasteFailure.eventUnavailable }
        return .pasteRequested
    }
}

/// This target is only for a separately labelled explicit Paste into the app's
/// current editable selection. Strict Apply uses AccessibilitySelectionEditTarget.
final class SelectionMenuPasteTarget: @unchecked Sendable {
    private let source: SelectionCopyTarget
    private let menu: SelectionEditMenu

    private init(source: SelectionCopyTarget, menu: SelectionEditMenu) {
        self.source = source
        self.menu = menu
    }

    static func capture(from source: SelectionCopyTarget, continuing: () -> Bool) -> SelectionMenuPasteTarget? {
        guard continuing(), let title = source.windowTitle,
              source.isCurrent(continuing: continuing), title == SelectionMenuWindowTitle.read(source.window),
              let menu = SelectionEditMenu.read(from: source, continuing: continuing),
              menu.available(afterStagingText: false), continuing() else { return nil }
        return .init(source: source, menu: menu)
    }

    @MainActor
    func paste(_ result: String, originalText: String, continuing: () -> Bool) throws -> SelectionReplacementOutcome {
        // AX checks can briefly occupy the main queue. These counters detect
        // clicks or typing even before our usual gesture monitors can run.
        let events: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        func counters() -> [UInt32] { events.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) } }
        let initial = counters()
        func current() -> Bool { continuing() && counters() == initial }
        func frontmost() -> Bool { source.process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) }
        return try SelectionMenuPasteTransaction(pasteboard: SystemSelectionPasteboard())
            .perform(result, original: originalText, validate: { staged in
                guard current(), frontmost(), source.isCurrent(continuing: current),
                      let title = source.windowTitle, title == SelectionMenuWindowTitle.read(source.window),
                      menu.available(afterStagingText: staged) else { return false }
                return current() && frontmost()
            }, requestPaste: {
                guard current(), frontmost() else { return false }
                return menu.requestPaste()
            })
    }
}
