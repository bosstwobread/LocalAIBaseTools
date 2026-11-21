import ApplicationServices
import Foundation

/// Numeric offsets from two AX elements can differ even when both expose the
/// same selected text. Bind the endpoints themselves, including their owners.
struct SelectionEditorMarkerReader<Element, Marker> {
    let owner: (Marker) -> Element?
    let parent: (Element) -> Element?
    let protected: (Element) -> Bool
    let sameElement: (Element, Element) -> Bool
    let sameMarker: (Marker, Marker) -> Bool
    let canRead: () -> Bool

    func matches(captured: (Marker, Marker), origin: (Marker, Marker)?, editor: (Marker, Marker)?,
                 focused: Element) -> Bool {
        guard canRead(), let origin, let editor, !sameMarker(captured.0, captured.1),
              sameMarker(captured.0, origin.0), sameMarker(captured.1, origin.1),
              sameMarker(captured.0, editor.0), sameMarker(captured.1, editor.1) else { return false }
        return belongsToEditor(editor.0, focused) && belongsToEditor(editor.1, focused) && canRead()
    }

    private func belongsToEditor(_ marker: Marker, _ focused: Element) -> Bool {
        guard canRead(), var node = owner(marker) else { return false }
        var visited: [Element] = []
        for _ in 0..<8 {
            guard canRead(), !visited.contains(where: { sameElement($0, node) }),
                  !protected(node), canRead() else { return false }
            if sameElement(node, focused) { return true }
            visited.append(node)
            guard let next = parent(node) else { return false }
            node = next
        }
        return false
    }
}

struct AccessibilityEditorMarkers {
    let captured: AXTextMarkerRange
    let origin: AXUIElement
    let originRange: NSRange?

    func matches(focused: AXUIElement, application: AXUIElement, continuing: @escaping () -> Bool) -> Bool {
        func endpoints(_ span: AXTextMarkerRange) -> (AXTextMarker, AXTextMarker) {
            (AXTextMarkerRangeCopyStartMarker(span), AXTextMarkerRangeCopyEndMarker(span))
        }
        guard continuing(), !AccessibilitySelectedText.isProtected(origin), continuing() else { return false }
        switch AccessibilitySelectedText.rangeEvidence(of: origin, continuing: continuing) {
        case .value(let range): guard range.length > 0, originRange == nil || originRange == range else { return false }
        case .missing: guard originRange == nil else { return false }
        case .invalid: return false
        }
        guard continuing(),
              let sourceMarkers = AccessibilitySelectedText.selectedMarkers(in: origin), continuing(),
              let editorMarkers = AccessibilitySelectedText.selectedMarkers(in: focused) else { return false }
        let reader = SelectionEditorMarkerReader<AXUIElement, AXTextMarker>(owner: { marker in
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(focused, "AXUIElementForTextMarker" as CFString,
                marker, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }, parent: {
            guard case .element(let parent) = AccessibilitySelectionOrigin.parent(of: $0, application: application) else { return nil }
            return parent
        }, protected: { AccessibilitySelectedText.isProtected($0) }, sameElement: { CFEqual($0, $1) },
            sameMarker: { CFEqual($0, $1) }, canRead: continuing)
        return reader.matches(captured: endpoints(captured), origin: endpoints(sourceMarkers),
                              editor: endpoints(editorMarkers), focused: focused)
    }
}
