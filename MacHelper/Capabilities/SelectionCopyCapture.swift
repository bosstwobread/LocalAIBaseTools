import AppKit
import ApplicationServices

/// A private tag distinguishes only our fixed Copy pair from real user input.
/// Other keys, including a physical Copy/Cut, still invalidate capture normally.
enum SelectionCopyEvents {
    static let tag: Int64 = 0x4d48435059434150
    static func isInternal(_ event: NSEvent) -> Bool {
        [.keyDown, .keyUp].contains(event.type) && event.keyCode == 8 &&
            event.modifierFlags.contains(.command) &&
            event.cgEvent?.getIntegerValueField(.eventSourceUserData) == tag
    }
    static func post(to pid: pid_t) -> Bool {
        guard pid > 1, CGPreflightPostEventAccess() else { return false }
        let events = [true, false].compactMap { down -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: down) else { return nil }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            return event
        }
        guard events.count == 2 else { return false }
        events.forEach { $0.postToPid(pid) }
        return true
    }
}

final class SelectionCopyUserIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func changed() { lock.lock(); generation &+= 1; lock.unlock() }
}

enum SelectionCopyMenuIdentity {
    private static let editMenuTitles: Set<String> = [
        "edit", "编辑", "編輯", "edición", "editar", "édition", "bearbeiten", "modifica",
        "編集", "편집", "правка", "редактирование", "تحرير", "संपादित करें",
    ]

    /// Starting at Edit avoids spending the traversal budget in other menus
    /// (e.g. File > Open Recent). Unrecognized titles keep their original order.
    static func editMenuIndex<Element>(in elements: [Element], title: (Element) -> String?) -> Int? {
        elements.firstIndex { element in
            guard let name = title(element) else { return false }
            return editMenuTitles.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func observeDispatch(_ status: AXError) -> Bool {
        // A timeout/generic failure may arrive after the app handled Copy.
        // Observe only a newly changed board so it can still be restored.
        [.success, .cannotComplete, .failure].contains(status)
    }
    static func standardShortcut(character: String?, modifiers: Int?) -> Bool {
        character?.lowercased() == "c" && modifiers == 0
    }
    static func reportsNoShortcut(status: AXError, character: String?) -> Bool {
        switch status {
        case .noValue, .attributeUnsupported: return true
        case .success: return character == ""
        default: return false
        }
    }
    static func matchesDirectCopy(title: String?, shortcutStatus: AXError, character: String?, modifiers: Int?) -> Bool {
        guard let title, exactTitle(title) else { return false }
        return standardShortcut(character: character, modifiers: modifiers) ||
            reportsNoShortcut(status: shortcutStatus, character: character)
    }
    static func exactTitle(_ title: String) -> Bool {
        let titles: Set<String> = ["copy", "复制", "拷贝", "複製", "拷貝", "copiar", "copier", "kopieren",
            "コピー", "복사", "نسخ", "कॉपी", "копировать", "copia"]
        return titles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Prefer the source application's standard Copy menu action. Some native
/// editors ignore posted shortcuts even though their Copy menu is accessible.
/// This traverses bounded menu structure only, never document descendants.
enum SelectionCopyAction {
    case menu(AXUIElement, pid_t)
    case shortcut(pid_t)

    static func resolve(application: AXUIElement, pid: pid_t, directEditCopyOnly: Bool = false,
                        continuing: () -> Bool) -> Self? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        func allowed() -> Bool { continuing() && ProcessInfo.processInfo.systemUptime < deadline }
        func attribute(_ name: String, _ element: AXUIElement) -> (AXError, CFTypeRef?) {
            guard allowed() else { return (.cannotComplete, nil) }
            AXUIElementSetMessagingTimeout(element, 0.06)
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return (status, status == .success ? result : nil)
        }
        func value(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
            attribute(name, element).1
        }
        guard allowed() else { return nil }
        guard let bar = value(kAXMenuBarAttribute, application), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            return !directEditCopyOnly && allowed() ? .shortcut(pid) : nil
        }
        var menuPID: pid_t = 0
        guard AXUIElementGetPid(bar as! AXUIElement, &menuPID) == .success, menuPID == pid else { return nil }
        var pending: [(element: AXUIElement, depth: Int, inEdit: Bool)] = [(bar as! AXUIElement, 0, false)]
        var visited: [AXUIElement] = []
        var titleMatch: AXUIElement?
        while let (element, depth, inEdit) = pending.popLast(), allowed(), visited.count < 180 {
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            let role = value(kAXRoleAttribute, element) as? String
            guard [kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole].contains(role ?? "") else { continue }
            if role == kAXMenuItemRole {
                let (shortcutStatus, shortcutValue) = attribute(kAXMenuItemCmdCharAttribute, element)
                let character = (shortcutValue as? String)?.lowercased()
                let modifiers = character == "c" ? value(kAXMenuItemCmdModifiersAttribute, element) as? Int : nil
                if directEditCopyOnly {
                    guard inEdit, depth == 3, SelectionCopyMenuIdentity.matchesDirectCopy(
                        title: value(kAXTitleAttribute, element) as? String, shortcutStatus: shortcutStatus,
                        character: character, modifiers: modifiers) else { continue }
                    guard (value(kAXEnabledAttribute, element) as? Bool) == true, allowed() else { return nil }
                    return .menu(element, pid)
                }
                if SelectionCopyMenuIdentity.standardShortcut(character: character, modifiers: modifiers) {
                    guard (value(kAXEnabledAttribute, element) as? Bool) == true, allowed() else { return nil }
                    return .menu(element, pid)
                }
                if (titleMatch == nil || (inEdit && depth == 3)),
                   let title = value(kAXTitleAttribute, element) as? String,
                   SelectionCopyMenuIdentity.exactTitle(title) {
                    // Some editors omit the shortcut on their standard Edit >
                    // Copy entry. A direct, enabled item with no reported
                    // shortcut can be used immediately, ahead of other menus.
                    if inEdit, depth == 3, SelectionCopyMenuIdentity.reportsNoShortcut(status: shortcutStatus, character: character) {
                        guard (value(kAXEnabledAttribute, element) as? Bool) == true, allowed() else { return nil }
                        return .menu(element, pid)
                    }
                    if titleMatch == nil { titleMatch = element }
                }
            }
            guard depth < 4, allowed() else { continue }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                min(64, 180 - visited.count), &children) == .success,
                let children = children as? [AnyObject],
                children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { continue }
            let elements = children.map { $0 as! AXUIElement }
            let editIndex = depth == 0 && role == kAXMenuBarRole ? SelectionCopyMenuIdentity.editMenuIndex(in: elements) {
                value(kAXTitleAttribute, $0) as? String
            } : nil
            if directEditCopyOnly, depth == 0 {
                guard let editIndex else { return nil }
                pending.append((elements[editIndex], depth + 1, true))
                continue
            }
            for index in elements.indices.reversed() where index != editIndex {
                pending.append((elements[index], depth + 1, inEdit))
            }
            if let editIndex { pending.append((elements[editIndex], depth + 1, true)) }
        }
        guard !directEditCopyOnly, allowed() else { return nil }
        if let titleMatch {
            guard (value(kAXEnabledAttribute, titleMatch) as? Bool) == true, allowed() else { return nil }
            return .menu(titleMatch, pid)
        }
        return .shortcut(pid)
    }

    func isAvailable() -> Bool {
        switch self {
        case .shortcut: return CGPreflightPostEventAccess()
        case .menu(let item, let expectedPID):
            AXUIElementSetMessagingTimeout(item, 0.06)
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(item, &actualPID) == .success, actualPID == expectedPID else { return false }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &value) == .success &&
                (value as? Bool) == true
        }
    }

    func perform() -> Bool {
        switch self {
        case .shortcut(let pid): return SelectionCopyEvents.post(to: pid)
        case .menu(let item, let expectedPID):
            var actualPID: pid_t = 0
            guard AXUIElementGetPid(item, &actualPID) == .success, actualPID == expectedPID else { return false }
            return SelectionCopyMenuIdentity.observeDispatch(AXUIElementPerformAction(item, kAXPressAction as CFString))
        }
    }
}

enum SelectionCopyValidity {
    case current, temporarilyUnavailable, invalid
}

/// Each check starts from the captured identities. While a check is unavailable
/// the UI hides the selection. Another check only reads AX; it never copies.
struct SelectionCopyRevalidation {
    private(set) var consecutiveTimeouts = 0

    mutating func shouldRetry(after validity: SelectionCopyValidity) -> Bool {
        if validity == .temporarilyUnavailable {
            consecutiveTimeouts += 1
            return consecutiveTimeouts <= 2
        }
        consecutiveTimeouts = 0
        return false
    }
}

enum SelectionReadOnlyCopy {
    /// A fixed pointer hit must reach the already verified window. A missing
    /// parent, a different window, and a truncated/cyclic path all fail closed.
    static func reachesWindow<Element>(from hit: Element, to window: Element,
                                       sameElement: (Element, Element) -> Bool,
                                       inspect: (Element, Bool) -> (parent: SelectionParent<Element>, placeholder: Bool)?) -> Bool {
        var current = hit
        var seen: [Element] = []
        var hasPlaceholder = false
        for index in 0..<16 {
            if index > 0, sameElement(current, window) { return hasPlaceholder }
            guard !seen.contains(where: { sameElement($0, current) }),
                  let node = inspect(current, index == 0),
                  case .element(let parent) = node.parent else { return false }
            seen.append(current)
            hasPlaceholder = hasPlaceholder || node.placeholder
            current = parent
        }
        return false
    }

    static func isPlaceholder(role: String?, isHit: Bool, selectedText: String?, valueIsReadOnly: Bool,
                              selectedTextIsReadOnly: Bool) -> Bool {
        (role == kAXStaticTextRole || (!isHit && role == kAXGroupRole)) &&
            selectedText == "" && valueIsReadOnly && selectedTextIsReadOnly
    }
}

/// Read-only provenance for an explicit gesture when AX cannot supply its text.
/// This is deliberately not an AccessibilitySelectionOrigin or an edit proof.
struct SelectionCopyTarget: @unchecked Sendable {
    let process: SelectionCompatibilityProcess
    let application: AXUIElement
    let window: AXUIElement
    let windowTitle: SelectionMenuWindowTitle?
    let focus: [SelectionFocusPath<AXUIElement>?]
    let hit: AXUIElement?
    let hitPoint: CGPoint?
    let requiresReadOnlyMenu: Bool

    static func capture(process: SelectionCompatibilityProcess, hitPoint: CGPoint?,
                        continuing: () -> Bool) -> Self? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        func allowed() -> Bool {
            continuing() && AXIsProcessTrusted() && ProcessInfo.processInfo.systemUptime < deadline &&
                process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
        }
        guard allowed() else { return nil }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        guard let window = AccessibilitySelectionOrigin.window(in: app, attribute: .focused), allowed(),
              validChain(window, application: app, continuing: allowed) else { return nil }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success,
              windowPID == process.processIdentifier, allowed() else { return nil }
        var focus: [SelectionFocusPath<AXUIElement>?] = []
        // Resolve both roots before accepting a fallback; a blocked focus must
        // never become permission to Copy through a broader window provider.
        for systemWide in [false, true] {
            guard allowed() else { return nil }
            switch AccessibilityFocusResolver.resolve(application: app, systemWide: systemWide) {
            case .blocked: return nil
            case .unavailable: focus.append(nil)
            case .path(let path):
                guard path.elements.allSatisfy({ validChain($0, application: app, continuing: allowed) }) else { return nil }
                focus.append(path)
            }
        }
        let hit = hitPoint.flatMap { AccessibilitySelectionOrigin.hit(in: app, at: $0) }
        var requiresReadOnlyMenu = false
        if let hit, !validChain(hit, application: app, continuing: allowed) {
            guard validReadOnlyHit(hit, window: window, application: app, pid: process.processIdentifier,
                                   continuing: allowed) else { return nil }
            requiresReadOnlyMenu = true
        }
        guard allowed() else { return nil }
        // Some editors reuse one window for several document tabs. A title read
        // failure affects only the later explicit Paste action, never capture.
        let windowTitle = SelectionMenuWindowTitle.read(window)
        return .init(process: process, application: app, window: window, windowTitle: windowTitle,
                     focus: focus, hit: hit, hitPoint: hitPoint, requiresReadOnlyMenu: requiresReadOnlyMenu)
    }

    func isCurrent(continuing: () -> Bool, allowNewlyExposedAnchors: Bool = false) -> Bool {
        validity(continuing: continuing, allowNewlyExposedAnchors: allowNewlyExposedAnchors) == .current
    }

    func validity(continuing: () -> Bool, allowNewlyExposedAnchors: Bool) -> SelectionCopyValidity {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var timedOut = false
        func onTimeout() { timedOut = true }
        func allowed() -> Bool {
            guard continuing() else { return false }
            if ProcessInfo.processInfo.systemUptime >= deadline { onTimeout(); return false }
            return true
        }
        func unavailable() -> SelectionCopyValidity {
            guard continuing(), AXIsProcessTrusted(),
                  process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) else { return .invalid }
            return timedOut ? .temporarilyUnavailable : .invalid
        }
        guard allowed(), AXIsProcessTrusted(),
              process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) else { return .invalid }
        guard let currentWindow = AccessibilitySelectionOrigin.window(in: application, attribute: .focused, onTimeout: onTimeout) else {
            return unavailable()
        }
        guard CFEqual(currentWindow, window) else { return .invalid }
        guard allowed(),
              Self.validChain(window, application: application, continuing: allowed, onTimeout: onTimeout) else { return unavailable() }
        for (index, captured) in focus.enumerated() {
            guard allowed() else { return unavailable() }
            let current = AccessibilityFocusResolver.resolve(application: application, systemWide: index == 1, onTimeout: onTimeout)
            if timedOut { return unavailable() }
            switch (captured, current) {
            case (nil, .unavailable): break
            case (nil, .path(let actual)) where allowNewlyExposedAnchors:
                guard actual.elements.allSatisfy({ Self.validChain($0, application: application, continuing: allowed,
                    onTimeout: onTimeout) }) else { return unavailable() }
            case (.some(let expected), .path(let actual)):
                guard expected.matches(actual, sameElement: { CFEqual($0, $1) }) else { return .invalid }
                guard actual.elements.allSatisfy({ Self.validChain($0, application: application, continuing: allowed,
                    onTimeout: onTimeout) }) else { return unavailable() }
            default: return .invalid
            }
        }
        if let hitPoint {
            let current = AccessibilitySelectionOrigin.hit(in: application, at: hitPoint, onTimeout: onTimeout)
            guard !timedOut else { return unavailable() }
            switch (hit, current) {
            case (nil, nil): break
            case (nil, .some(let current)) where allowNewlyExposedAnchors:
                guard Self.validChain(current, application: application, continuing: allowed, onTimeout: onTimeout) else { return unavailable() }
            case (.some(let previous), .some(let current)):
                guard CFEqual(previous, current) else { return .invalid }
                let valid = requiresReadOnlyMenu
                    ? Self.validReadOnlyHit(current, window: window, application: application,
                                            pid: process.processIdentifier, continuing: allowed, onTimeout: onTimeout)
                    : Self.validChain(current, application: application, continuing: allowed, onTimeout: onTimeout)
                guard valid else { return unavailable() }
            default: return .invalid
            }
        }
        guard allowed(), process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) else { return unavailable() }
        return .current
    }

    private static func validReadOnlyHit(_ hit: AXUIElement, window: AXUIElement, application: AXUIElement,
                                         pid: pid_t, continuing: () -> Bool, onTimeout: () -> Void = {}) -> Bool {
        func read(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            guard continuing() else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.08)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if status == .cannotComplete { onTimeout() }
            return status == .success ? value : nil
        }
        func readOnly(_ name: String, of element: AXUIElement) -> Bool {
            guard continuing() else { return false }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            if status == .cannotComplete { onTimeout() }
            return status == .success && !settable.boolValue
        }
        return SelectionReadOnlyCopy.reachesWindow(from: hit, to: window, sameElement: { CFEqual($0, $1) }) { node, isHit in
            var owner: pid_t = 0
            guard continuing(), !CFEqual(node, application),
                  AXUIElementGetPid(node, &owner) == .success, owner == pid,
                  !AccessibilitySelectedText.isProtected(node, onTimeout: onTimeout),
                  let role = read(kAXRoleAttribute, of: node) as? String, role != kAXWindowRole,
                  !isHit || role == kAXStaticTextRole, continuing() else { return nil }
            let range = AccessibilitySelectedText.rangeEvidence(of: node, continuing: continuing, onTimeout: onTimeout)
            var placeholder = false
            switch range {
            case .invalid: return nil
            case .missing: if isHit { return nil }
            case .value(let value):
                if value.length == 0 {
                    guard SelectionReadOnlyCopy.isPlaceholder(role: role, isHit: isHit,
                        selectedText: read(kAXSelectedTextAttribute, of: node) as? String,
                        valueIsReadOnly: readOnly(kAXValueAttribute, of: node),
                        selectedTextIsReadOnly: readOnly(kAXSelectedTextAttribute, of: node)) else { return nil }
                    placeholder = true
                } else if isHit { return nil }
            }
            guard continuing() else { return nil }
            return (AccessibilitySelectionOrigin.parent(of: node, application: application), placeholder)
        }
    }

    private static func validChain(_ anchor: AXUIElement, application: AXUIElement,
                                   continuing: () -> Bool, onTimeout: () -> Void = {}) -> Bool {
        var current = anchor
        var seen: [AXUIElement] = []
        for _ in 0..<8 {
            guard continuing(), !seen.contains(where: { CFEqual($0, current) }),
                  !AccessibilitySelectedText.isProtected(current, onTimeout: onTimeout), continuing() else { return false }
            seen.append(current)
            // Only advertised selection ranges are queried. Unsupported AX
            // providers are eligible; explicit carets/malformed ranges are not.
            var attributes: CFArray?
            AXUIElementSetMessagingTimeout(current, 0.08)
            let status = AXUIElementCopyAttributeNames(current, &attributes)
            if status == .cannotComplete { onTimeout() }
            guard status == .success, let names = attributes as? [String], continuing() else { return false }
            if names.contains(kAXSelectedTextRangeAttribute) || names.contains(kAXSelectedTextRangesAttribute) {
                switch AccessibilitySelectedText.rangeEvidence(of: current, continuing: continuing, onTimeout: onTimeout) {
                case .missing: break
                case .value(let range): if range.length <= 0 { return false }
                case .invalid: return false
                }
            }
            if CFEqual(current, application) { return true }
            switch AccessibilitySelectionOrigin.parent(of: current, application: application) {
            case .root: return true
            case .invalid: return false
            case .element(let parent): current = parent
            }
        }
        return false
    }
}
