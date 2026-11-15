import Foundation

struct TextSelection: Equatable, Sendable {
    let text: String
    let sourcePID: Int32
    let rangeLocation: Int
    let rangeLength: Int
    /// AppKit global coordinates, in screen points.
    let bounds: CGRect
}

/// Selection changes invalidate every in-flight result, including repeated text
/// selected in a different app or at a different location.
struct SelectionState {
    private(set) var selection: TextSelection?
    private(set) var generation: UInt64 = 0
    private(set) var dismissed = false

    @discardableResult
    mutating func observe(_ value: TextSelection?) -> Bool {
        guard value != selection else { return false }
        generation &+= 1
        selection = value
        dismissed = false
        return true
    }

    mutating func dismiss() {
        generation &+= 1
        dismissed = true
    }

    /// Only real drag/double-click/keyboard selection gestures rearm an
    /// unchanged dismissed selection. Timer reads cannot bring it back.
    mutating func rearmAfterSelectionGesture() {
        guard dismissed else { return }
        generation &+= 1
        selection = nil
        dismissed = false
    }

    var canTranslate: Bool { selection != nil && !dismissed }

    func acceptsResult(for token: UInt64) -> Bool {
        canTranslate && token == generation
    }
}

enum FloatingGeometry {
    /// AX uses a top-left origin on the main screen; AppKit uses bottom-left.
    /// Other displays may have negative x/y, so never use the union's height.
    static func appKitRect(fromAccessibility rect: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screen(for anchor: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let containing = visibleFrames.first(where: { $0.contains(center) }) { return containing }
        return visibleFrames.max { lhs, rhs in
            intersectionArea(lhs, anchor) < intersectionArea(rhs, anchor)
        }
    }

    static func frame(size: CGSize, near anchor: CGRect, in visibleFrame: CGRect, gap: CGFloat = 7) -> CGRect {
        let inset = visibleFrame.insetBy(dx: 6, dy: 6)
        let width = min(size.width, max(1, inset.width))
        let height = min(size.height, max(1, inset.height))
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - height
        let aboveRoom = inset.maxY - anchor.maxY - gap
        let belowRoom = anchor.minY - inset.minY - gap
        let preferredY = aboveRoom >= height || aboveRoom >= belowRoom ? above : below
        return CGRect(
            x: clamp(anchor.minX, lower: inset.minX, upper: inset.maxX - width),
            y: clamp(preferredY, lower: inset.minY, upper: inset.maxY - height),
            width: width, height: height
        )
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
