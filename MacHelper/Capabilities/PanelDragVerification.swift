import AppKit

/// Explicit test mode only. The host retains this controller instead of
/// creating its regular delegate/managers. Nothing reads preferences, selected
/// text, Accessibility, the clipboard or any AI provider. All output is synthetic.
@MainActor
public final class PanelDragVerification {
    public var onDismiss: (() -> Void)?
    private let panels = FloatingCapabilityPanels(toolTitle: "Panel drag verification", systemSymbolName: "hand.draw")
    private let eventPolicy = SelectionMonitor()
    private var localEvents: Any?
    private var globalEvents: Any?
    private var task: Task<Void, Never>?
    private var running = false
    private var moved = false
    private var updates = 0
    private var completed = false
    private var localPointerEvents = 0
    private var globalPointerEvents = 0
    private var text = ""
    private var anchor = CGRect.zero

    public init() {
        panels.onDismiss = { [weak self] in self?.dismiss() }
        panels.onResultMoved = { [weak self] in
            guard let self, self.running else { return }
            self.moved = true
            self.render()
        }
        eventPolicy.shouldIgnoreOutsideClick = { [weak self] point in self?.panels.contains(point) == true }
        eventPolicy.isInteractingWithOverlay = { [weak self] in self?.panels.isDraggingResultPanel == true }
        // Keep this synthetic fixture visible while the automation controller
        // is inspected. Production outside-click cancellation has its own tests.
        eventPolicy.onDismiss = nil
    }

    public func start() {
        stop()
        running = true; moved = false; updates = 0; completed = false
        localPointerEvents = 0; globalPointerEvents = 0
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        anchor = CGRect(x: frame.midX - 100, y: frame.midY - 100, width: 80, height: 20)
        text = "Synthetic drag check\n\nDrag the title or grip while this sample grows. The panel should stay where you put it through streaming and completion.\n\nNo AI requests, clipboard access or selected-text reads occur in this check."
        installEvents()
        panels.showLoading(near: anchor)
        render()
        task = Task { [weak self] in
            for index in 1...30 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.running, !Task.isCancelled else { return }
                self.updates = index
                self.text += "\nSample update \(index): synthetic text continues at the current panel position."
                self.render()
            }
            guard let self, self.running, !Task.isCancelled else { return }
            self.completed = true
            self.text += "\n\nComplete. The header remains draggable. Copy is available only after this synthetic final result."
            self.render()
        }
    }

    public func stop() {
        running = false
        task?.cancel(); task = nil
        if let localEvents { NSEvent.removeMonitor(localEvents); self.localEvents = nil }
        if let globalEvents { NSEvent.removeMonitor(globalEvents); self.globalEvents = nil }
        eventPolicy.stop()
        panels.hide()
    }

    private func installEvents() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseDragged,
                                          .leftMouseUp, .rightMouseUp, .keyDown, .keyUp]
        localEvents = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.dismiss(); return nil }
            self?.observePointer(event, local: true)
            self?.eventPolicy.handle(event, local: true)
            return event
        }
        globalEvents = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.dismiss(); return }
            self?.observePointer(event, local: false)
            self?.eventPolicy.handle(event, local: false)
        }
        // Deliberately never call eventPolicy.start(): its trusted flag stays
        // false, no polling timer/AX query exists, and scheduled reads do nothing.
    }

    private func observePointer(_ event: NSEvent, local: Bool) {
        guard [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp].contains(event.type) else { return }
        if local { localPointerEvents += 1 } else { globalPointerEvents += 1 }
        // Refresh after view event dispatch too, including after completion or a
        // failed drag, so the header's event counters remain observable.
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    private func render() {
        guard running else { return }
        let frame = panels.resultFrame
        let main = NSScreen.main
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let scale = main?.backingScaleFactor ?? 1
        // CUA's application screenshot may be cropped. These diagnostics give
        // the header's desktop coordinate rather than a crop-relative point.
        let headerFrame = panels.resultHeaderFrame
        let header = CGPoint(x: headerFrame.minX + min(76, headerFrame.width / 2), y: primaryTop - headerFrame.midY)
        func number(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
        let coordinates = "AppKit frame x/y/w/h: \(number(frame.minX)),\(number(frame.minY)),\(number(frame.width)),\(number(frame.height))"
            + " · mainTop: \(number(main?.frame.maxY ?? 0)) · primaryTop: \(number(primaryTop)) · scale: \(number(scale))"
            + " · header desktop top-left points: \(number(header.x)),\(number(header.y))"
            + " · header scaled pixels: \(number(header.x * scale)),\(number(header.y * scale))"
            + " · actual header AppKit x/y/w/h: \(number(headerFrame.minX)),\(number(headerFrame.minY)),\(number(headerFrame.width)),\(number(headerFrame.height))"
            + " · " + panels.dragDiagnostic
            + " · fixture pointer events local/global: \(localPointerEvents)/\(globalPointerEvents)"
        let evidence = "Synthetic · moved: \(moved ? "yes" : "no") · \(completed ? "complete" : "updates: " + String(updates)) · " + coordinates
        let result = CapabilityTranslationResult(text: text, model: evidence, title: "Panel drag verification")
        if completed { panels.showResult(result, near: anchor) }
        else { panels.showProgress(result, near: anchor) }
    }

    private func dismiss() { stop(); onDismiss?() }
}
