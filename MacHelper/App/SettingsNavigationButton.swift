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
