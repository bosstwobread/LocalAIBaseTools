import AppKit

private final class CapabilityPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingCapabilityPanels {
    var onPerform: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let iconPanel: NSPanel
    private let resultPanel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private let footer = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var resultText: String?

    private let toolTitle: String
    private let systemSymbolName: String

    init(toolTitle: String, systemSymbolName: String) {
        self.toolTitle = toolTitle
        self.systemSymbolName = systemSymbolName
        iconPanel = Self.panel(title: toolTitle, size: NSSize(width: 34, height: 34))
        resultPanel = Self.panel(title: toolTitle, size: NSSize(width: 380, height: 268))
        buildIcon()
        buildResult()
    }

    var isVisible: Bool { iconPanel.isVisible || resultPanel.isVisible }

    func contains(_ point: CGPoint) -> Bool {
        (iconPanel.isVisible && iconPanel.frame.contains(point)) ||
        (resultPanel.isVisible && resultPanel.frame.contains(point))
    }

    func showIcon(near anchor: CGRect) {
        resultPanel.orderOut(nil)
        place(iconPanel, size: CGSize(width: 34, height: 34), near: anchor)
        iconPanel.orderFrontRegardless()
    }

    func showLoading(near anchor: CGRect) {
        resultText = nil
        title.stringValue = toolTitle + "…"
        output.string = "Working…"
        footer.stringValue = "MacHelper · shared AI settings"
        copyButton.isEnabled = false
        retryButton.isHidden = true
        showResult(near: anchor)
    }

    func showResult(_ response: CapabilityTranslationResult, near anchor: CGRect) {
        resultText = response.text
        title.stringValue = response.title ?? toolTitle
        output.string = response.text
        footer.stringValue = response.model ?? "MacHelper · shared AI settings"
        footer.toolTip = response.model
        copyButton.isEnabled = true
        retryButton.isHidden = true
        showResult(near: anchor)
    }

    func showError(_ message: String, near anchor: CGRect, canRetry: Bool = true) {
        resultText = nil
        title.stringValue = "Couldn’t complete " + toolTitle
        output.string = message
        footer.stringValue = canRetry ? "Check MacHelper settings and try again." : "Copy text, then choose the clipboard action."
        footer.toolTip = nil
        copyButton.isEnabled = false
        retryButton.isHidden = !canRetry
        showResult(near: anchor)
    }

    func hide() {
        iconPanel.orderOut(nil)
        resultPanel.orderOut(nil)
        resultText = nil
        output.string = ""
    }

    private static func panel(title: String, size: NSSize) -> NSPanel {
        let panel = CapabilityPanel(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(title)
        return panel
    }

    private func buildIcon() {
        let background = Self.background()
        iconPanel.contentView = background
        let button = NSButton(image: NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: toolTitle) ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: toolTitle)!,
                              target: self, action: #selector(perform))
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = toolTitle + " · selected text"
        button.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            button.topAnchor.constraint(equalTo: background.topAnchor),
            button.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
    }

    private func buildResult() {
        let background = Self.background()
        resultPanel.contentView = background
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss result")!,
                             target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Dismiss (Esc)"
        let header = NSStackView(views: [title, close])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill
        close.widthAnchor.constraint(equalToConstant: 22).isActive = true

        output.isEditable = false
        output.isSelectable = true
        output.isRichText = false
        output.drawsBackground = false
        output.font = .systemFont(ofSize: 14)
        output.textColor = .labelColor
        output.textContainerInset = NSSize(width: 0, height: 4)
        output.isHorizontallyResizable = false
        output.isVerticallyResizable = true
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        output.setAccessibilityLabel("Result text")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = output

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.target = self
        copyButton.action = #selector(copyResult)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(perform)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        let bottom = NSStackView(views: [footer, retryButton, copyButton])
        bottom.orientation = .horizontal
        bottom.spacing = 7
        bottom.alignment = .centerY

        for view in [header, scroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 24),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            bottom.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private static func background() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        return view
    }

    private func showResult(near anchor: CGRect) {
        iconPanel.orderOut(nil)
        place(resultPanel, size: CGSize(width: 380, height: 268), near: anchor)
        output.scrollToBeginningOfDocument(nil)
        resultPanel.orderFrontRegardless()
    }

    private func place(_ panel: NSPanel, size: CGSize, near anchor: CGRect) {
        let frames = NSScreen.screens.map(\.visibleFrame)
        guard let screen = FloatingGeometry.screen(for: anchor, visibleFrames: frames) else { return }
        panel.setFrame(FloatingGeometry.frame(size: size, near: anchor, in: screen), display: true)
        output.frame.size.width = max(1, panel.frame.width - 26)
    }

    @objc private func perform() { onPerform?() }
    @objc private func dismiss() { onDismiss?() }

    @objc private func copyResult() {
        guard let resultText else { return }
        // This is the only clipboard write and requires a deliberate Copy click.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copyButton.title = "Copy" }
    }
}
