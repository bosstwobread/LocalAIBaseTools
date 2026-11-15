import AppKit

/// Separates a readable preview from an authoritative, copyable final result.
struct CapabilityPresentationState {
    enum Phase: Equatable { case idle, working, complete, failed }
    private(set) var phase = Phase.idle
    private(set) var text = ""
    private(set) var model: String?
    private(set) var title: String?
    private(set) var error: String?
    private(set) var isIncomplete = false
    var copyText: String? { phase == .complete && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : nil }

    mutating func begin() { self = Self(); phase = .working }
    mutating func reset() { self = Self() }

    @discardableResult
    mutating func progress(_ result: CapabilityTranslationResult) -> Bool {
        guard phase == .working else { return false }
        text = result.text
        if let model = result.model { self.model = model }
        if let title = result.title { self.title = title }
        return true
    }

    mutating func complete(_ result: CapabilityTranslationResult) {
        let streamModel = phase == .working ? model : nil
        let streamTitle = phase == .working ? title : nil
        phase = .complete
        text = result.text
        model = result.model ?? streamModel
        title = result.title ?? streamTitle
        error = nil
        isIncomplete = false
    }

    mutating func fail(_ message: String) {
        isIncomplete = phase == .working && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isIncomplete { text = message; model = nil; title = nil }
        phase = .failed
        error = message
    }
}

/// AppKit edits use UTF-16 offsets. Canonically equivalent Swift strings can
/// have different UTF-16 lengths, so only a literal prefix is safe to append.
enum CapabilityTextUpdate: Equatable {
    case unchanged
    case append(String)
    case replace(String)

    static func between(old: String, new: String) -> Self {
        let oldLength = (old as NSString).length
        let newString = new as NSString
        if newString.length >= oldLength, new.utf16.starts(with: old.utf16) {
            return newString.length == oldLength ? .unchanged : .append(newString.substring(from: oldLength))
        }
        return .replace(new)
    }
}

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
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var presentation = CapabilityPresentationState()

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
        presentation.begin()
        title.stringValue = toolTitle + "…"
        updateText("Working…", resetScroll: true)
        footer.stringValue = "MacHelper · shared AI settings"
        footer.toolTip = nil
        copyButton.isEnabled = false
        copyButton.title = "Copy"
        output.isSelectable = false
        retryButton.isHidden = true
        presentResult(near: anchor, resetScroll: true)
    }

    func showProgress(_ response: CapabilityTranslationResult, near anchor: CGRect) {
        guard presentation.progress(response) else { return }
        title.stringValue = (presentation.title ?? toolTitle) + "…"
        if !presentation.text.isEmpty { updateText(presentation.text) }
        footer.stringValue = presentation.model.map { "Working… · " + $0 } ?? "Working…"
        footer.toolTip = presentation.model
        copyButton.isEnabled = false
        output.isSelectable = false
        retryButton.isHidden = true
        presentResult(near: anchor)
    }

    func showResult(_ response: CapabilityTranslationResult, near anchor: CGRect) {
        presentation.complete(response)
        title.stringValue = presentation.title ?? toolTitle
        updateText(response.text)
        footer.stringValue = presentation.model ?? "MacHelper · shared AI settings"
        footer.toolTip = presentation.model
        copyButton.isEnabled = presentation.copyText != nil
        output.isSelectable = true
        retryButton.isHidden = true
        presentResult(near: anchor)
    }

    func showError(_ message: String, near anchor: CGRect, canRetry: Bool = true) {
        presentation.fail(message)
        title.stringValue = presentation.isIncomplete ? "Incomplete · " + toolTitle : "Couldn’t complete " + toolTitle
        updateText(presentation.text)
        footer.stringValue = presentation.isIncomplete ? "Incomplete: " + message
            : canRetry ? "Check MacHelper settings and try again." : "Copy text, then choose the clipboard action."
        footer.toolTip = message
        copyButton.isEnabled = false
        output.isSelectable = false
        retryButton.isHidden = !canRetry
        presentResult(near: anchor)
    }

    func hide() {
        iconPanel.orderOut(nil)
        resultPanel.orderOut(nil)
        presentation.reset()
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

    private func presentResult(near anchor: CGRect, resetScroll: Bool = false) {
        iconPanel.orderOut(nil)
        if !resultPanel.isVisible {
            place(resultPanel, size: CGSize(width: 380, height: 268), near: anchor)
            resultPanel.orderFrontRegardless()
        }
        if resetScroll { output.scrollToBeginningOfDocument(nil) }
    }

    /// Append growing text without rebuilding the view or resetting a reader's
    /// scroll position. Follow the tail only while they are already at the end.
    private func updateText(_ text: String, resetScroll: Bool = false) {
        let update = CapabilityTextUpdate.between(old: output.string, new: text)
        guard update != .unchanged else { return }
        let origin = scroll.contentView.bounds.origin
        let followTail = output.frame.height - scroll.documentVisibleRect.maxY <= 24
        let new = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: output.font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: output.textColor ?? NSColor.labelColor
        ]
        switch update {
        case .append(let suffix):
            output.textStorage?.append(NSAttributedString(string: suffix, attributes: attributes))
        case .replace:
            output.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        case .unchanged: break
        }
        if resetScroll { output.scrollToBeginningOfDocument(nil) }
        else if followTail { output.scrollRangeToVisible(NSRange(location: new.length, length: 0)) }
        else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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
        guard let resultText = presentation.copyText else { return }
        // This is the only clipboard write and requires a deliberate Copy click.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copyButton.title = "Copy" }
    }
}
