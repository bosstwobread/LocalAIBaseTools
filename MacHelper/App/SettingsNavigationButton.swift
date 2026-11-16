import AppKit
import MacHelper

/// Apply semantic layout after creating dynamic settings/cards too. Source text
/// editors retain their original writing direction and exact text bytes.
@MainActor
func applyAppLanguageDirection(to view: NSView) {
    if view is NSTextView { return }
    view.userInterfaceLayoutDirection = AppLocalization.shared.isRightToLeft ? .rightToLeft : .leftToRight
    if let field = view as? NSTextField, !field.isEditable { field.alignment = .natural }
    for child in view.subviews { applyAppLanguageDirection(to: child) }
}

/// Shared navigation, separate from settings defined by individual extensions.
private final class SettingsNavigationButtonCell: NSButtonCell {
    private let iconWidth: CGFloat = 20
    private let iconSpacing: CGFloat = 4

    private var rightToLeft: Bool { controlView?.userInterfaceLayoutDirection == .rightToLeft }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let original = super.titleRect(forBounds: rect)
        let reserved = iconWidth + iconSpacing
        return NSRect(x: rightToLeft ? rect.minX : rect.minX + reserved, y: original.minY,
                      width: max(0, rect.width - reserved), height: original.height)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(1, iconWidth / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let slotX = rightToLeft ? rect.maxX - iconWidth : rect.minX
        return NSRect(x: slotX + (iconWidth - size.width) / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

@MainActor
final class SettingsNavigationButton: NSButton {
    var isSelected = false {
        didSet {
            font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
            setAccessibilityValue(isSelected ? L("Selected") : "")
            needsDisplay = true
        }
    }

    init(title: String, symbol: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        cell = SettingsNavigationButtonCell(textCell: title)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        alignment = AppLocalization.shared.isRightToLeft ? .right : .left
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 13)
        contentTintColor = .labelColor
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
