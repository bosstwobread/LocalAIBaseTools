import AppKit
import ApplicationServices

struct SelectionToolbarAdjustment: Sendable {
    let pointerY: CGFloat
    let occupiedY: ClosedRange<CGFloat>
}

/// Placement evidence is independent of the proof used to read or edit text.
/// All rectangles passed to anchor() use AppKit global screen coordinates.
struct SelectionToolbarAnchor {
    let screens: [CGRect]
    let pointer: CGPoint
    let fromPointerGesture: Bool

    func anchor(range: CGRect?, editor: CGRect?, window: CGRect?, dragStart: CGPoint? = nil)
        -> (bounds: CGRect, adjustment: SelectionToolbarAdjustment?) {
        let window = window.flatMap { Self.usable($0) ? $0 : nil }
        let pointerAnchor = Self.point(at: pointer)
        if fromPointerGesture {
            // An editor can return its hidden text area's box or a stale range
            // on another display. The gesture endpoint is a reliable fallback.
            if let range, Self.usable(range),
               let screen = screens.first(where: { $0.contains(pointer) }) {
                let clipped = range.intersection(window ?? range).intersection(screen)
                if Self.usable(clipped), clipped.insetBy(dx: -20, dy: -20).contains(pointer) {
                    return (clipped, .init(pointerY: pointer.y, occupiedY: clipped.minY...clipped.maxY))
                }
            }
            // When the provider has no usable range rectangle, the two
            // endpoints approximate the lines covered by a local vertical drag.
            if let dragStart, let window, abs(pointer.y - dragStart.y) >= 12,
               window.contains(dragStart), window.contains(pointer),
               let screen = screens.first(where: { $0.contains(pointer) && $0.contains(dragStart) }) {
                let bottom = max(screen.minY, min(dragStart.y, pointer.y) - 9)
                let top = min(screen.maxY, max(dragStart.y, pointer.y) + 9)
                return (pointerAnchor, .init(pointerY: pointer.y, occupiedY: bottom...top))
            }
            return (pointerAnchor, nil)
        }
        // A keyboard selection has no pointer endpoint. Keep the toolbar in
        // the visible part of the focused editor/window even if the mouse was
        // last used on another display.
        if let range, let visible = visiblePart(of: range, inside: window) { return (visible, nil) }
        if let editor, let visible = visiblePart(of: editor, inside: window) { return (point(in: visible), nil) }
        if let window, let visible = visiblePart(of: window, inside: nil) { return (point(in: visible), nil) }
        return (pointerAnchor, nil)
    }

    private func visiblePart(of rect: CGRect, inside window: CGRect?) -> CGRect? {
        guard Self.usable(rect) else { return nil }
        let clipped = rect.intersection(window ?? rect)
        return screens.map { $0.intersection(clipped) }.filter(Self.usable).max { a, b in
            a.width * a.height < b.width * b.height
        }
    }

    private func point(in rect: CGRect) -> CGRect {
        Self.point(at: rect.contains(pointer) ? pointer : CGPoint(x: rect.midX, y: rect.midY))
    }

    private static func point(at p: CGPoint) -> CGRect { CGRect(origin: p, size: CGSize(width: 1, height: 1)) }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
    }
}

extension SelectionToolbarAnchor {
    /// One bounded, noncontent query for an editor or window's screen frame.
    static func appKitFrame(of element: AXUIElement?, mainScreenTop: CGFloat) -> CGRect? {
        guard let element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.06)
        var raw: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == 2,
              CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[0] as! AXValue, .cgPoint, &position),
              AXValueGetValue(values[1] as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: position, size: size)
        guard usable(rect) else { return nil }
        return FloatingGeometry.appKitRect(fromAccessibility: rect, mainScreenTop: mainScreenTop)
    }
}
