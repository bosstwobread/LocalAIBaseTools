import ApplicationServices
import Foundation

/// Focus can cross an app-owned WebArea into a web-process editor. Preserve
/// the whole identity path; numeric ranges always belong to the node read.
struct SelectionFocusPath<Element> {
    let elements: [Element]
    var anchor: Element { elements[0] }
    var leaf: Element { elements[elements.count - 1] }

    func matches(_ other: Self?, sameElement: (Element, Element) -> Bool) -> Bool {
        guard let other, elements.count == other.elements.count else { return false }
        return zip(elements, other.elements).allSatisfy { sameElement($0.0, $0.1) }
    }
}

enum SelectionFocusLink<Element> {
    case leaf, element(Element), invalid
}

/// Follow only the provider's focus relationship, never arbitrary children.
struct SelectionFocusReader<Element> {
    let focusedChild: (Element) -> SelectionFocusLink<Element>
    let isProtected: (Element) -> Bool
    let sameElement: (Element, Element) -> Bool
    let canRead: () -> Bool
    var maximumElements = 4

    func read(from anchor: Element) -> SelectionFocusPath<Element>? {
        var path: [Element] = []
        var current = anchor
        for _ in 0..<max(0, min(4, maximumElements)) {
            guard canRead(), !path.contains(where: { sameElement($0, current) }), !isProtected(current), canRead() else { return nil }
            path.append(current)
            let next = focusedChild(current)
            guard canRead() else { return nil }
            switch next {
            case .leaf: return SelectionFocusPath(elements: path)
            case .invalid: return nil
            case .element(let child):
                if sameElement(current, child) { return SelectionFocusPath(elements: path) }
                current = child
            }
        }
        return nil
    }
}

enum AccessibilityFocusResolver {
    static func read(application: AXUIElement) -> SelectionFocusPath<AXUIElement>? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        func withinBudget() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        guard case .element(let anchor) = focusLink(application) else { return nil }
        return SelectionFocusReader<AXUIElement>(focusedChild: focusLink,
            isProtected: { element in
                AXUIElementSetMessagingTimeout(element, 0.10)
                return (attribute(kAXSubroleAttribute, of: element) as? String) == kAXSecureTextFieldSubrole ||
                    (attribute("AXProtectedContent", of: element) as? Bool) == true
            }, sameElement: { CFEqual($0, $1) }, canRead: withinBudget).read(from: anchor)
    }

    static func matches(_ captured: SelectionFocusPath<AXUIElement>, application: AXUIElement) -> Bool {
        captured.matches(read(application: application), sameElement: { CFEqual($0, $1) })
    }

    private static func focusLink(_ element: AXUIElement) -> SelectionFocusLink<AXUIElement> {
        AXUIElementSetMessagingTimeout(element, 0.10)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return .leaf }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .invalid }
        return .element(value as! AXUIElement)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
