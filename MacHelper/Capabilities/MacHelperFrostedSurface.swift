import AppKit

/// Lets the WindowServer soften the backdrop and adapt the material to the
/// current appearance and accessibility settings.
@MainActor
public final class MacHelperFrostedSurface: NSVisualEffectView {
    public init(material: NSVisualEffectView.Material = .popover, cornerRadius: CGFloat = 0) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = .behindWindow
        state = .active
        if cornerRadius > 0 {
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
