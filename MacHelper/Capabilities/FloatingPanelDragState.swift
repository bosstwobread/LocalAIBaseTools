import Foundation

/// One result's manual placement survives streaming, completion, errors and a
/// retry. A new selection or dismissal resets both placement and mouse capture.
struct CapabilityPanelPlacement {
    private(set) var userFrame: CGRect?
    private var startFrame: CGRect?
    private var startPoint: CGPoint?
    var isDragging: Bool { startFrame != nil && startPoint != nil }

    mutating func beginDrag(frame: CGRect, pointer: CGPoint) -> Bool {
        guard Self.valid(frame), pointer.x.isFinite, pointer.y.isFinite else { return false }
        startFrame = frame
        startPoint = pointer
        return true
    }

    mutating func drag(to pointer: CGPoint, visibleFrames: [CGRect]) -> CGRect? {
        guard let startFrame, let startPoint, pointer.x.isFinite, pointer.y.isFinite else { return nil }
        let proposed = startFrame.offsetBy(dx: pointer.x - startPoint.x, dy: pointer.y - startPoint.y)
        guard let frame = Self.clamped(proposed, visibleFrames: visibleFrames, preferredPoint: pointer) else { return nil }
        userFrame = frame
        return frame
    }

    mutating func endDrag() { startFrame = nil; startPoint = nil }
    mutating func reset() { self = Self() }

    mutating func frame(size: CGSize, near anchor: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        if let userFrame {
            let frame = Self.clamped(userFrame, visibleFrames: visibleFrames)
            self.userFrame = frame
            return frame
        }
        guard let screen = FloatingGeometry.screen(for: anchor, visibleFrames: visibleFrames) else { return nil }
        return FloatingGeometry.frame(size: size, near: anchor, in: screen)
    }

    /// Prefer the display under the pointer while moving. If a display has
    /// disappeared, recover to an intersecting/nearest remaining visible area.
    static func clamped(_ frame: CGRect, visibleFrames: [CGRect], preferredPoint: CGPoint? = nil) -> CGRect? {
        guard valid(frame) else { return nil }
        let screens = visibleFrames.filter(valid)
        guard !screens.isEmpty else { return nil }
        let point = preferredPoint ?? CGPoint(x: frame.midX, y: frame.midY)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let screen: CGRect
        if let containing = screens.first(where: { $0.contains(point) }) { screen = containing }
        else if let intersecting = screens.max(by: { area($0.intersection(frame)) < area($1.intersection(frame)) }),
                area(intersecting.intersection(frame)) > 0 { screen = intersecting }
        else {
            screen = screens.min(by: { distance(point, to: $0) < distance(point, to: $1) })!
        }
        let inset = screen.insetBy(dx: min(6, screen.width / 4), dy: min(6, screen.height / 4))
        let width = min(frame.width, inset.width)
        let height = min(frame.height, inset.height)
        return CGRect(x: min(max(frame.minX, inset.minX), inset.maxX - width),
                      y: min(max(frame.minY, inset.minY), inset.maxY - height), width: width, height: height)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
