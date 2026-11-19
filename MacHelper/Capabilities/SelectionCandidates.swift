import AppKit
import ApplicationServices

enum SelectionParent<Element> { case root, element(Element), invalid }

enum SelectionWindowAttribute: String {
    case focused = "AXFocusedWindow"
    case main = "AXMainWindow"
}

struct SelectionWindowAnchor {
    let attribute: SelectionWindowAttribute
    let element: AXUIElement
}

struct SelectionCandidate<Element> {
    let ancestry: [Element]
    let sourceIndex: Int
    let span: SelectedTextSpan
    let terminalParent: SelectionParent<Element>
}

/// Inspect only one candidate and its bounded parent chain. Empty children do
/// not hide a capable parent; protection, cycles, and stale reads fail closed.
struct SelectionCandidateReader<Element> {
    let parent: (Element) -> SelectionParent<Element>
    let isProtected: (Element) -> Bool
    let sameElement: (Element, Element) -> Bool
    let canRead: () -> Bool
    let selectedSpan: (Element) -> SelectedTextReadResult
    var maximumAncestors = 8

    func read(from anchor: Element) -> SelectionCandidate<Element>? {
        var ancestry: [Element] = []
        var current = anchor
        var terminal: SelectionParent<Element> = .root
        for _ in 0..<max(0, min(8, maximumAncestors)) {
            guard canRead(), !ancestry.contains(where: { sameElement($0, current) }),
                  !isProtected(current), canRead() else { return nil }
            ancestry.append(current)
            terminal = parent(current)
            switch terminal {
            case .invalid: return nil
            case .root: break
            case .element(let next):
                guard !ancestry.contains(where: { sameElement($0, next) }) else { return nil }
                current = next
            }
            if case .root = terminal { break }
        }
        for (index, element) in ancestry.enumerated() {
            guard canRead() else { return nil }
            if case .selected(let span) = selectedSpan(element) {
                guard canRead() else { return nil }
                return .init(ancestry: ancestry, sourceIndex: index, span: span, terminalParent: terminal)
            }
        }
        return nil
    }
}

/// Memory-only proof of where a read came from. A pointer hit is scoped to the
/// original application and must resolve to the identical element again. This
/// proof permits reading only; Apply independently requires the focused route.
struct AccessibilitySelectionOrigin: @unchecked Sendable, Equatable {
    let process: SelectionCompatibilityProcess
    let ancestry: [AXUIElement]
    let sourceIndex: Int
    let focus: SelectionFocusPath<AXUIElement>?
    let hitPoint: CGPoint?
    var windowAnchor: SelectionWindowAnchor? = nil
    var applicationAnchor = false
    var terminalParent: SelectionParent<AXUIElement> = .root
    var source: AXUIElement { ancestry[sourceIndex] }

    func matchesSource(_ candidate: AXUIElement) -> Bool {
        ancestry.indices.contains(sourceIndex) && CFEqual(source, candidate)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // A mouse and a keyboard read can prove the same source through
        // different paths. Changing proof routes is not a new selection.
        lhs.process == rhs.process && lhs.ancestry.indices.contains(lhs.sourceIndex) &&
            rhs.ancestry.indices.contains(rhs.sourceIndex) && CFEqual(lhs.source, rhs.source)
    }

    func isCurrent(continuing: () -> Bool = { true }) -> Bool {
        guard continuing(), AXIsProcessTrusted(),
              process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication),
              ancestry.indices.contains(sourceIndex), let anchor = ancestry.first else { return false }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        if let focus {
            guard focus.elements.contains(where: { CFEqual($0, anchor) }), continuing(),
                  AccessibilityFocusResolver.matches(focus, application: app) else { return false }
        } else if let hitPoint {
            guard continuing(), let current = Self.hit(in: app, at: hitPoint), CFEqual(anchor, current) else { return false }
        } else if let windowAnchor {
            guard continuing(), let current = Self.window(in: app, attribute: windowAnchor.attribute),
                  CFEqual(anchor, windowAnchor.element), CFEqual(current, windowAnchor.element) else { return false }
        } else if applicationAnchor {
            guard CFEqual(anchor, app) else { return false }
        } else { return false }
        for (index, element) in ancestry.enumerated() {
            guard continuing(), !Self.protected(element), continuing() else { return false }
            if index + 1 < ancestry.count {
                guard case .element(let parent) = Self.parent(of: element, application: app), CFEqual(parent, ancestry[index + 1]) else { return false }
            }
        }
        guard let last = ancestry.last, continuing() else { return false }
        switch (terminalParent, Self.parent(of: last, application: app)) {
        case (.root, .root): break
        case (.element(let expected), .element(let actual)) where CFEqual(expected, actual): break
        default: return false
        }
        return continuing() && process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
    }

    static func hit(in application: AXUIElement, at point: CGPoint) -> AXUIElement? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        AXUIElementSetMessagingTimeout(application, 0.12)
        var result: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &result) == .success else { return nil }
        return result
    }

    static func window(in application: AXUIElement, attribute: SelectionWindowAttribute) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(application, 0.10)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute.rawValue as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func parent(of element: AXUIElement, application: AXUIElement) -> SelectionParent<AXUIElement> {
        if CFEqual(element, application) { return .root }
        AXUIElementSetMessagingTimeout(element, 0.10)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return .root }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .invalid }
        return .element(value as! AXUIElement)
    }

    static func protected(_ element: AXUIElement) -> Bool {
        AccessibilitySelectedText.isProtected(element)
    }
}
