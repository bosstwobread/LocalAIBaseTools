import AppKit
import MacHelper
import MacHelperCapabilities

@MainActor
final class MacHelperStateTip {
    private let panel = StateTipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let row = NSStackView()
    private var dismissal: Task<Void, Never>?

    init() {
        panel.identifier = NSUserInterfaceItemIdentifier("machelper-state-tip")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let background = MacHelperFrostedSurface(cornerRadius: 12)

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        row.alignment = .centerY
        row.spacing = 9
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -11)
        ])
        panel.contentView = background
    }

    func show(isEnabled: Bool) {
        let text = isEnabled ? L("MacHelper enabled") : L("MacHelper disabled")
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])

        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        label.stringValue = text
        panel.setAccessibilityLabel(text)
        icon.image = NSImage(systemSymbolName: isEnabled ? "checkmark.circle.fill" : "pause.circle.fill",
                             accessibilityDescription: nil)
        icon.contentTintColor = isEnabled ? .systemGreen : .secondaryLabelColor
        if let content = panel.contentView { applyAppLanguageDirection(to: content) }

        let size = row.fittingSize
        let width = min(ceil(size.width) + 32, max(1, visible.width - 32))
        let height = ceil(size.height) + 22
        let frame = NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 24,
                           width: width, height: height).integral
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel.orderOut(nil)
    }
}

private final class StateTipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
