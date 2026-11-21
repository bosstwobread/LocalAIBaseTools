import ApplicationServices
import Foundation

/// Focus can cross an app-owned WebArea into a web-process editor. Preserve
/// the whole identity path; numeric ranges always belong to the node read.
struct SelectionFocusPath<Element> {
    let elements: [Element]
    var systemWide = false
    var anchor: Element { elements[0] }
    var leaf: Element { elements[elements.count - 1] }

    func matches(_ other: Self?, sameElement: (Element, Element) -> Bool) -> Bool {
        guard let other, systemWide == other.systemWide, elements.count == other.elements.count else { return false }
        return zip(elements, other.elements).allSatisfy { sameElement($0.0, $0.1) }
    }
}

/// A missing focus attribute during a nonactivating panel click is different
/// from observing an actual foreign, changed, malformed or protected control.
enum SelectionEditFocusStatus { case current, unavailable, changed }

extension SelectionFocusPath {
    func editStatus(allowSameEditor: Bool,
                    resolve: (Bool) -> SelectionFocusResolution<Element>,
                    sameElement: (Element, Element) -> Bool) -> SelectionEditFocusStatus {
        func classify(_ resolution: SelectionFocusResolution<Element>) -> SelectionEditFocusStatus {
            switch resolution {
            case .unavailable: return .unavailable
            case .blocked: return .changed
            case .path(let actual):
                if matches(actual, sameElement: sameElement) { return .current }
                // Each freshly resolved intermediate wrapper has already been
                // checked for protection, cycles and truncation. Only the
                // identical focused editor can survive a changed wrapper/root.
                return allowSameEditor && sameElement(leaf, actual.leaf) ? .current : .changed
            }
        }
        let primary = classify(resolve(systemWide))
        guard primary == .unavailable, allowSameEditor else { return primary }
        return classify(resolve(!systemWide))
    }
}

enum SelectionFocusLink<Element> {
    case leaf, element(Element), invalid
}

enum SelectionFocusResolution<Element> {
    case path(SelectionFocusPath<Element>)
    /// Only a genuinely unsupported/absent root focus attribute permits this.
    case unavailable
    /// Invalid, protected, stale, foreign, cyclic or truncated focus evidence.
    case blocked
}

/// Follow only the provider's focus relationship, never arbitrary children.
struct SelectionFocusReader<Element> {
    let focusedChild: (Element) -> SelectionFocusLink<Element>
    let isProtected: (Element) -> Bool
    let sameElement: (Element, Element) -> Bool
    let canRead: () -> Bool
    var maximumElements = 4

    func read(from anchor: Element) -> SelectionFocusPath<Element>? {
        guard case .path(let path) = resolve(from: anchor) else { return nil }
        return path
    }

    func resolveRoot(_ link: SelectionFocusLink<Element>,
                     validAnchor: (Element) -> Bool = { _ in true }) -> SelectionFocusResolution<Element> {
        guard canRead() else { return .blocked }
        switch link {
        case .leaf: return .unavailable
        case .invalid: return .blocked
        case .element(let anchor):
            guard validAnchor(anchor), canRead() else { return .blocked }
            return resolve(from: anchor)
        }
    }

    func resolve(from anchor: Element) -> SelectionFocusResolution<Element> {
        var path: [Element] = []
        var current = anchor
        for _ in 0..<max(0, min(4, maximumElements)) {
            guard canRead(), !path.contains(where: { sameElement($0, current) }), !isProtected(current), canRead() else { return .blocked }
            path.append(current)
            let next = focusedChild(current)
            guard canRead() else { return .blocked }
            switch next {
            case .leaf: return .path(SelectionFocusPath(elements: path))
            case .invalid: return .blocked
            case .element(let child):
                if sameElement(current, child) { return .path(SelectionFocusPath(elements: path)) }
                current = child
            }
        }
        return .blocked
    }
}

enum AccessibilityFocusResolver {
    static func read(application: AXUIElement, systemWide: Bool = false) -> SelectionFocusPath<AXUIElement>? {
        guard case .path(let path) = resolve(application: application, systemWide: systemWide) else { return nil }
        return path
    }

    static func resolve(application: AXUIElement, systemWide: Bool = false,
                        onTimeout: @escaping () -> Void = {}) -> SelectionFocusResolution<AXUIElement> {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        func withinBudget() -> Bool {
            if ProcessInfo.processInfo.systemUptime >= deadline { onTimeout(); return false }
            return true
        }
        let root = systemWide ? AXUIElementCreateSystemWide() : application
        let reader = SelectionFocusReader<AXUIElement>(focusedChild: { focusLink($0, onTimeout: onTimeout) },
            isProtected: { AccessibilitySelectedText.isProtected($0, onTimeout: onTimeout) },
            sameElement: { CFEqual($0, $1) }, canRead: withinBudget)
        let result = reader.resolveRoot(focusLink(root, onTimeout: onTimeout), validAnchor: { anchor in
            guard withinBudget() else { return false }
            guard systemWide else { return true }
            // The system focus is useful only when it belongs to this exact
            // application. Never turn it into a cross-application scan.
            var expected: pid_t = 0, actual: pid_t = 0
            guard AXUIElementGetPid(application, &expected) == .success, expected > 1,
                  withinBudget(), AXUIElementGetPid(anchor, &actual) == .success,
                  withinBudget(), actual == expected else { return false }
            return true
        })
        guard case .path(var path) = result else { return result }
        path.systemWide = systemWide
        return .path(path)
    }

    static func matches(_ captured: SelectionFocusPath<AXUIElement>, application: AXUIElement) -> Bool {
        captured.matches(read(application: application, systemWide: captured.systemWide), sameElement: { CFEqual($0, $1) })
    }

    private static func focusLink(_ element: AXUIElement, onTimeout: () -> Void) -> SelectionFocusLink<AXUIElement> {
        AXUIElementSetMessagingTimeout(element, 0.10)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .cannotComplete { onTimeout() }
        if status == .attributeUnsupported || status == .noValue { return .leaf }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .invalid }
        return .element(value as! AXUIElement)
    }

}
