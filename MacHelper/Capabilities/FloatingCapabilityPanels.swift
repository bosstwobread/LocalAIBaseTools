import AppKit
import MacHelper

/// Separates a readable preview from an authoritative, copyable final result.
struct CapabilityPresentationState {
    enum Phase: Equatable { case idle, working, complete, failed }
    private(set) var phase = Phase.idle
    private(set) var text = ""
    private(set) var model: String?
    private(set) var title: String?
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
        isIncomplete = false
    }

    mutating func fail(_ message: String) {
        isIncomplete = phase == .working && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isIncomplete { text = message; model = nil; title = nil }
        phase = .failed
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

/// Borderless toolbar cells use their complete frame as the click area.
/// Native bezel/menu alignment insets must not shrink or overlap these slots.
private final class CapabilityIconButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
}

private final class CapabilityMenuTracking: NSObject, NSMenuDelegate {
    var isTracking = false
    func menuWillOpen(_ menu: NSMenu) { isTracking = true }
    func menuDidClose(_ menu: NSMenu) { isTracking = false }
}

/// A small dedicated mouse-capture area leaves the close button, result text
/// selection, scroll view and footer controls with their normal AppKit behavior.
private final class CapabilityPanelDragHandle: NSView {
    var onBegin: ((CGPoint) -> Bool)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    private var tracking = false
    private var moved = false
    private(set) var downEvents = 0
    private(set) var dragEvents = 0
    private(set) var upEvents = 0
    private(set) var acceptedBegins = 0
    private(set) var lastEventPoint: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        downEvents += 1
        let point = screenPoint(event)
        lastEventPoint = point
        guard !tracking, onBegin?(point) == true else { return }
        acceptedBegins += 1
        tracking = true; moved = false
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        dragEvents += 1
        let point = screenPoint(event)
        lastEventPoint = point
        guard tracking else { return }
        moved = true
        onMove?(point)
    }

    override func mouseUp(with event: NSEvent) {
        upEvents += 1
        let point = screenPoint(event)
        lastEventPoint = point
        if tracking, moved { onMove?(point) }
        cancelDrag()
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        CapabilityDragPointer.screenPoint(for: event, window: window,
            primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    func cancelDrag() {
        guard tracking else { return }
        tracking = false; moved = false
        NSCursor.pop()
        onEnd?()
    }
}

/// Use the position attached to this event. A live cursor poll can already be
/// at a later queued event's endpoint, losing motion in fast/injected drags.
enum CapabilityDragPointer {
    static func screenPoint(for event: NSEvent, window: NSWindow?, primaryScreenTop: CGFloat) -> CGPoint {
        if let point = event.cgEvent?.location {
            return CGPoint(x: point.x, y: primaryScreenTop - point.y)
        }
        return window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}

@MainActor
final class FloatingCapabilityPanels {
    var onPerform: (() -> Void)?
    var onPerformAction: ((String) -> Void)?
    var onApply: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onResultMoved: (() -> Void)?
    private let iconPanel: NSPanel
    private let resultPanel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let actionStatus = NSTextField(wrappingLabelWithString: "")
    private var actionStatusHeight: NSLayoutConstraint?
    private let copyButton = NSButton(title: L("Copy"), target: nil, action: nil)
    private let retryButton = NSButton(title: L("Retry"), target: nil, action: nil)
    private let applyButton = NSButton(title: L("Apply"), target: nil, action: nil)
    private var actionButtons: [ObjectIdentifier: String] = [:]
    private var toolbarSize = CGSize(width: 34, height: 34)
    private var replacementAllowed = false
    private var replacementAvailable = false
    private var usesMenuPaste = false
    private let menuTracking = CapabilityMenuTracking()
    private var closeButton: NSButton?
    private var iconButton: NSButton?
    private var languageObserver: NSObjectProtocol?
    private let dragHandle = CapabilityPanelDragHandle()
    private var presentation = CapabilityPresentationState()
    private var placement = CapabilityPanelPlacement()

    private var toolTitle: String
    private let systemSymbolName: String

    init(toolTitle: String, systemSymbolName: String) {
        self.toolTitle = toolTitle
        self.systemSymbolName = systemSymbolName
        iconPanel = Self.panel(title: toolTitle, size: NSSize(width: 34, height: 34))
        resultPanel = Self.panel(title: toolTitle, size: NSSize(width: 380, height: 268))
        buildIcon()
        buildResult()
        refreshLanguage()
        languageObserver = NotificationCenter.default.addObserver(forName: .macHelperLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLanguage()
                self?.dismiss()
            }
        }
    }

    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }

    private func refreshLanguage() {
        copyButton.title = L("Copy")
        retryButton.title = L("Retry")
        applyButton.title = L("Apply")
        closeButton?.toolTip = L("Dismiss (Esc)")
        closeButton?.setAccessibilityLabel(L("Dismiss result"))
        iconButton?.toolTip = L("%@ · selected text", toolTitle)
        dragHandle.toolTip = L("Drag to move this panel")
        dragHandle.setAccessibilityLabel(L("Move result panel"))
        output.setAccessibilityLabel(L("Result text"))
        actionStatus.setAccessibilityLabel(L("Apply status"))
        output.baseWritingDirection = .natural
        func applyDirection(_ view: NSView) {
            if view is NSTextView { return }
            view.userInterfaceLayoutDirection = AppLocalization.shared.isRightToLeft ? .rightToLeft : .leftToRight
            for child in view.subviews { applyDirection(child) }
        }
        if let content = resultPanel.contentView { applyDirection(content) }
    }

    var isDraggingResultPanel: Bool { placement.isDragging }
    var isToolbarVisible: Bool { iconPanel.isVisible }
    var isInteractingWithOverlay: Bool { placement.isDragging || menuTracking.isTracking }
    /// Read-only diagnostic geometry for the explicit synthetic fixture.
    var resultFrame: CGRect { resultPanel.frame }
    var resultHeaderFrame: CGRect {
        resultPanel.convertToScreen(dragHandle.convert(dragHandle.bounds, to: nil))
    }
    var dragDiagnostic: String {
        let point = dragHandle.lastEventPoint.map { String(format: "%.1f,%.1f", Double($0.x), Double($0.y)) } ?? "none"
        let local = dragHandle.convert(NSPoint(x: dragHandle.bounds.midX, y: dragHandle.bounds.midY), to: nil)
        let hit = resultPanel.contentView?.hitTest(local).map { String(describing: type(of: $0)) } ?? "none"
        return "header events down/drag/up/begin: \(dragHandle.downEvents)/\(dragHandle.dragEvents)/\(dragHandle.upEvents)/\(dragHandle.acceptedBegins)"
            + " · last event AppKit: \(point) · center hit: \(hit)"
    }

    func contains(_ point: CGPoint) -> Bool {
        menuTracking.isTracking || (iconPanel.isVisible && iconPanel.frame.contains(point)) ||
        (resultPanel.isVisible && resultPanel.frame.contains(point))
    }

    func showIcon(near anchor: CGRect) {
        dragHandle.cancelDrag()
        placement.reset()
        resultPanel.orderOut(nil)
        place(iconPanel, size: toolbarSize, near: anchor)
        iconPanel.orderFrontRegardless()
    }

    func refreshToolbar(near anchor: CGRect) {
        guard iconPanel.isVisible else { return }
        place(iconPanel, size: toolbarSize, near: anchor)
    }

    func showLoading(near anchor: CGRect) {
        presentation.begin()
        title.stringValue = toolTitle + "…"
        updateText(L("Working…"), resetScroll: true)
        footer.stringValue = L("MacHelper · shared AI settings")
        footer.toolTip = nil
        setActionStatus(nil)
        copyButton.isEnabled = false
        applyButton.isHidden = true
        copyButton.title = L("Copy")
        output.isSelectable = false
        retryButton.isHidden = true
        presentResult(near: anchor, resetScroll: true)
    }

    func showProgress(_ response: CapabilityTranslationResult, near anchor: CGRect) {
        guard presentation.progress(response) else { return }
        title.stringValue = (presentation.title ?? toolTitle) + "…"
        if !presentation.text.isEmpty { updateText(presentation.text) }
        footer.stringValue = presentation.model.map { L("Working… · %@", $0) } ?? L("Working…")
        footer.toolTip = presentation.model
        setActionStatus(nil)
        copyButton.isEnabled = false
        applyButton.isHidden = true
        output.isSelectable = false
        retryButton.isHidden = true
        presentResult(near: anchor)
    }

    func showResult(_ response: CapabilityTranslationResult, near anchor: CGRect) {
        presentation.complete(response)
        title.stringValue = presentation.title ?? toolTitle
        updateText(response.text)
        footer.stringValue = presentation.model ?? L("MacHelper · shared AI settings")
        footer.toolTip = presentation.model
        copyButton.isEnabled = presentation.copyText != nil
        applyButton.isHidden = !replacementAllowed
        applyButton.isEnabled = replacementAvailable && presentation.copyText != nil
        if usesMenuPaste {
            setActionStatus(L("Apply pastes into the current selection in the original window. The result stays on the clipboard."))
        } else if replacementAllowed && !replacementAvailable {
            setActionStatus(L("Use Copy; safe replacement could not be verified for this selection."))
        } else { setActionStatus(nil) }
        output.isSelectable = true
        retryButton.isHidden = true
        presentResult(near: anchor)
    }

    func showError(_ message: String, near anchor: CGRect) {
        presentation.fail(message)
        title.stringValue = presentation.isIncomplete ? L("Incomplete · %@", toolTitle) : L("Couldn’t complete %@", toolTitle)
        updateText(presentation.text)
        footer.stringValue = presentation.model ?? L("MacHelper · shared AI settings")
        footer.toolTip = presentation.model
        setActionStatus(presentation.isIncomplete ? L("Incomplete: %@", message) : L("Check MacHelper settings and try again."))
        copyButton.isEnabled = false
        applyButton.isHidden = true
        output.isSelectable = false
        retryButton.isHidden = false
        presentResult(near: anchor)
    }

    func hide() {
        dragHandle.cancelDrag()
        placement.reset()
        iconPanel.orderOut(nil)
        resultPanel.orderOut(nil)
        presentation.reset()
        output.string = ""
        setActionStatus(nil)
    }

    func setToolTitle(_ value: String) { toolTitle = value }

    func configureReplacement(allowed: Bool, available: Bool, usesMenuPaste: Bool = false) {
        self.usesMenuPaste = usesMenuPaste
        replacementAllowed = allowed; replacementAvailable = available
        applyButton.isHidden = true
    }

    func replacementSucceeded(_ outcome: SelectionReplacementOutcome) {
        applyButton.isEnabled = false
        switch outcome {
        case .confirmed: setActionStatus(L("Selected text replaced."))
        case .unverified, .changedByEditor:
            setActionStatus(L("Edit requested. Check the original app before continuing."))
        case .pasteRequested:
            setActionStatus(L("Paste requested. The result is on the clipboard."))
        }
    }

    func replacementFailed(_ message: String) {
        applyButton.isEnabled = false
        setActionStatus(message)
        // The authoritative result remains selectable/copyable after failure.
    }

    private func setActionStatus(_ message: String?) {
        let value = message ?? ""
        actionStatus.stringValue = value
        applyButton.setAccessibilityHelp(message)
        actionStatus.isHidden = value.isEmpty
        let width = max(1, resultPanel.frame.width - 36)
        let height = (value as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 11)]).height
        actionStatusHeight?.constant = value.isEmpty ? 0 : max(16, ceil(height) + 4)
    }

    func setActions(_ actions: [(identifier: String, title: String, systemSymbolName: String)]) {
        guard !actions.isEmpty else { return }
        let background = Self.background()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.userInterfaceLayoutDirection = AppLocalization.shared.isRightToLeft ? .rightToLeft : .leftToRight
        actionButtons.removeAll()
        iconButton = nil
        // Keep the overlay bounded even with many extensions. Native menus
        // scroll their overflow while preserving every manifest command.
        let layout = SelectionToolbarLayout(identifiers: actions.map(\.identifier))
        for action in actions.prefix(layout.visible.count) {
            let image = Self.actionImage(action.systemSymbolName, label: action.title)
            let button = CapabilityIconButton(image: image, target: self, action: #selector(performToolbarAction(_:)))
            button.title = ""
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = L("%@ · selected text", action.title)
            button.setAccessibilityIdentifier(action.identifier)
            button.setAccessibilityLabel(action.title)
            actionButtons[ObjectIdentifier(button)] = action.identifier
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 34), button.heightAnchor.constraint(equalToConstant: 34)])
        }
        if !layout.overflow.isEmpty {
            let menu = NSMenu(title: L("More…"))
            for action in actions.dropFirst(layout.visible.count) {
                let item = NSMenuItem(title: action.title, action: #selector(performOverflowAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = action.identifier
                item.setAccessibilityIdentifier(action.identifier)
                menu.addItem(item)
            }
            menu.delegate = menuTracking
            let more = CapabilityIconButton(image: Self.actionImage("ellipsis", label: L("More…")), target: self, action: #selector(showMoreActions(_:)))
            more.title = ""
            more.imagePosition = .imageOnly
            more.isBordered = false
            more.contentTintColor = .controlAccentColor
            more.menu = menu
            more.toolTip = L("More…")
            more.setAccessibilityLabel(L("More…"))
            more.setAccessibilityIdentifier("selection-toolbar-more")
            stack.addArrangedSubview(more)
            NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 34), more.heightAnchor.constraint(equalToConstant: 34)])
        }
        let count = CGFloat(stack.arrangedSubviews.count)
        toolbarSize = CGSize(width: count * 34 + max(0, count - 1) * 4 + 12, height: 46)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6)
        ])
        iconPanel.contentView = background
        iconPanel.setContentSize(toolbarSize)
        background.userInterfaceLayoutDirection = AppLocalization.shared.isRightToLeft ? .rightToLeft : .leftToRight
    }

    private static func actionImage(_ name: String, label: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: label)!
        return image.withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? image
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
        iconButton = button
        button.contentTintColor = .controlAccentColor
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = L("%@ · selected text", toolTitle)
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
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Dismiss result"))!,
                             target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        closeButton = close
        close.toolTip = L("Dismiss (Esc)")
        let grip = NSImageView()
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        grip.contentTintColor = .tertiaryLabelColor
        let dragContents = NSStackView(views: [grip, title])
        dragContents.alignment = .centerY
        dragContents.spacing = 7
        dragContents.distribution = .fill
        dragContents.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.addSubview(dragContents)
        dragHandle.toolTip = L("Drag to move this panel")
        dragHandle.setAccessibilityLabel(L("Move result panel"))
        NSLayoutConstraint.activate([
            grip.widthAnchor.constraint(equalToConstant: 12),
            dragContents.leadingAnchor.constraint(equalTo: dragHandle.leadingAnchor),
            dragContents.trailingAnchor.constraint(equalTo: dragHandle.trailingAnchor),
            dragContents.topAnchor.constraint(equalTo: dragHandle.topAnchor),
            dragContents.bottomAnchor.constraint(equalTo: dragHandle.bottomAnchor)
        ])
        dragHandle.onBegin = { [weak self] pointer in
            guard let self, self.resultPanel.isVisible else { return false }
            return self.placement.beginDrag(frame: self.resultPanel.frame, pointer: pointer)
        }
        dragHandle.onMove = { [weak self] pointer in
            guard let self,
                  let frame = self.placement.drag(to: pointer, visibleFrames: NSScreen.screens.map(\.visibleFrame)) else { return }
            let changed = frame != self.resultPanel.frame
            self.setResultFrame(frame)
            if changed { self.onResultMoved?() }
        }
        dragHandle.onEnd = { [weak self] in self?.placement.endDrag() }
        let header = NSStackView(views: [dragHandle, close])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill
        close.widthAnchor.constraint(equalToConstant: 22).isActive = true
        dragHandle.heightAnchor.constraint(equalTo: header.heightAnchor).isActive = true
        dragHandle.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
        output.setAccessibilityLabel(L("Result text"))
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
        actionStatus.font = .systemFont(ofSize: 11)
        actionStatus.textColor = .secondaryLabelColor
        actionStatus.alignment = .natural
        actionStatus.lineBreakMode = .byWordWrapping
        actionStatus.maximumNumberOfLines = 0
        actionStatus.isSelectable = true
        actionStatus.isHidden = true
        actionStatus.setAccessibilityLabel(L("Apply status"))
        applyButton.target = self
        applyButton.action = #selector(applyResult)
        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .small
        applyButton.isHidden = true
        let bottom = NSStackView(views: [footer, retryButton, copyButton, applyButton])
        bottom.orientation = .horizontal
        bottom.spacing = 7
        bottom.alignment = .centerY

        for view in [header, scroll, actionStatus, bottom] {
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
            scroll.bottomAnchor.constraint(equalTo: actionStatus.topAnchor, constant: -6),
            actionStatus.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            actionStatus.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            actionStatus.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -6),
            bottom.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            bottom.heightAnchor.constraint(equalToConstant: 24)
        ])
        let statusHeight = actionStatus.heightAnchor.constraint(equalToConstant: 0)
        statusHeight.isActive = true
        actionStatusHeight = statusHeight
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
        if let frame = placement.frame(size: CGSize(width: 380, height: 268), near: anchor,
                                       visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            setResultFrame(frame)
        }
        if !resultPanel.isVisible {
            resultPanel.orderFrontRegardless()
        }
        if resetScroll { output.scrollToBeginningOfDocument(nil) }
    }

    private func setResultFrame(_ frame: CGRect) {
        if resultPanel.frame != frame { resultPanel.setFrame(frame, display: true) }
        output.frame.size.width = max(1, frame.width - 26)
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
    @objc private func performToolbarAction(_ sender: NSButton) {
        guard let identifier = actionButtons[ObjectIdentifier(sender)] else { return }
        onPerformAction?(identifier)
    }
    @objc private func performOverflowAction(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        onPerformAction?(identifier)
    }
    @objc private func showMoreActions(_ sender: NSButton) {
        sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    @objc private func applyResult() {
        guard replacementAllowed, replacementAvailable, applyButton.isEnabled,
              let result = presentation.copyText else { return }
        applyButton.isEnabled = false
        onApply?(result)
    }
    @objc private func dismiss() { onDismiss?() }

    @objc private func copyResult() {
        guard let resultText = presentation.copyText else { return }
        // Copy writes only the completed result after a deliberate click.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        copyButton.title = L("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copyButton.title = L("Copy") }
    }
}
