import AppKit
import ApplicationServices

/// Output returned by a source tool. Prompt construction, target language,
/// provider/model selection, and all editable tool behavior belong to the caller.
public struct CapabilityTranslationResult: Equatable, Sendable {
    public let text: String
    public let model: String?
    public let title: String?

    public init(text: String, model: String? = nil, title: String? = nil) {
        self.text = text
        self.model = model
        self.title = title
    }
}

/// Escaping progress callbacks can outlive cancellation or even the final
/// response. One active ticket binds every update to both operation and selection.
struct CapabilityOperationGate {
    struct Ticket: Equatable {
        let operation: UInt64
        let selection: UInt64
    }
    private var generation: UInt64 = 0
    private var active: Ticket?

    mutating func begin(selectionGeneration: UInt64) -> Ticket {
        generation &+= 1
        let ticket = Ticket(operation: generation, selection: selectionGeneration)
        active = ticket
        return ticket
    }

    mutating func invalidate() { generation &+= 1; active = nil }
    mutating func finish(_ ticket: Ticket) { if active == ticket { active = nil } }

    func accepts(_ ticket: Ticket, selection: SelectionState, running: Bool, cancelled: Bool) -> Bool {
        running && !cancelled && active == ticket && selection.acceptsResult(for: ticket.selection)
    }
}

/// Reusable read-only selection, explicit-action, and result-panel capability.
/// The host owns lifecycle, settings, and permissions. Source tools supply the
/// asynchronous operation and can be reloaded without rebuilding this module.
@MainActor
public final class SelectionTranslationCapability {
    public var onPerform: (@MainActor (String) async throws -> CapabilityTranslationResult)?
    public var onPerformStreaming: (@MainActor (String, @escaping @MainActor (CapabilityTranslationResult) -> Void) async throws -> CapabilityTranslationResult)?
    public var onPresentOverlay: (() -> Void)?
    public var onStatusChange: (() -> Void)?
    public private(set) var isRunning = false
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public var isShowingOverlay: Bool { panels.isVisible }

    private let monitor = SelectionMonitor()
    private let panels: FloatingCapabilityPanels
    private var state = SelectionState()
    private var operationTask: Task<Void, Never>?
    private var manualSelection = false
    private var operationGate = CapabilityOperationGate()

    public init(title: String, systemSymbolName: String = "character.bubble") {
        panels = FloatingCapabilityPanels(toolTitle: title, systemSymbolName: systemSymbolName)
        panels.onPerform = { [weak self] in self?.performSelection() }
        panels.onDismiss = { [weak self] in self?.dismiss() }
        monitor.shouldIgnoreOutsideClick = { [weak self] in self?.panels.contains($0) == true }
        monitor.onRead = { [weak self] in self?.receive($0) }
        monitor.onDismiss = { [weak self] in self?.dismiss() }
        monitor.onFrontApplicationChange = { [weak self] in self?.clearSelection() }
        monitor.onSelectionGesture = { [weak self] selecting in
            guard let self, selecting else { return }
            self.manualSelection = false
            self.state.rearmAfterSelectionGesture()
        }
        monitor.onPermissionChange = { [weak self] _ in self?.onStatusChange?() }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start()
        onStatusChange?()
    }

    public func stop() {
        isRunning = false
        monitor.stop()
        clearSelection()
        onStatusChange?()
    }

    /// The source tool supplies demo text. No selection permission is needed.
    public func runDemo(text: String) {
        guard isRunning else { return }
        onPresentOverlay?()
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        useManualSelection(text, at: CGPoint(x: screen.midX - 120, y: screen.midY))
        if let selection = state.selection { panels.showIcon(near: selection.bounds) }
    }

    /// Reads the current pasteboard only on an explicit host/menu/button action.
    /// It never synthesizes Copy, changes a draft, or automatically writes data.
    public func translateClipboard() {
        guard isRunning else { return }
        onPresentOverlay?()
        let point = NSEvent.mouseLocation
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSelection()
            manualSelection = true
            panels.showError("Your clipboard does not contain text. Copy text yourself, then choose the clipboard action again.",
                             near: CGRect(x: point.x, y: point.y, width: 1, height: 20), canRetry: false)
            return
        }
        useManualSelection(text, at: point)
        performSelection()
    }

    public func dismiss() {
        operationGate.invalidate()
        operationTask?.cancel()
        operationTask = nil
        state.dismiss()
        manualSelection = false
        panels.hide()
    }

    private func receive(_ value: SelectionReadResult) {
        guard isRunning, !manualSelection else { return }
        let selection: TextSelection?
        switch value {
        case .selection(let found): selection = found
        case .empty, .unavailable: selection = nil
        }
        guard state.observe(selection) else { return }
        operationGate.invalidate()
        operationTask?.cancel()
        operationTask = nil
        if let selection, state.canTranslate { panels.showIcon(near: selection.bounds) }
        else { panels.hide() }
    }

    private func performSelection() {
        guard isRunning, state.canTranslate, let selection = state.selection else { return }
        operationTask?.cancel()
        let ticket = operationGate.begin(selectionGeneration: state.generation)
        panels.showLoading(near: selection.bounds)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: CapabilityTranslationResult
                if let streaming = self.onPerformStreaming {
                    result = try await streaming(selection.text) { [weak self] progress in
                        guard let self, self.operationGate.accepts(ticket, selection: self.state,
                                                                 running: self.isRunning, cancelled: Task.isCancelled) else { return }
                        // Source tools send cumulative previews. Keep rendering
                        // bounded even if a broken tool emits oversized output.
                        guard progress.text.utf8.count <= CapabilityFrame.maximumBytes else { return }
                        self.panels.showProgress(progress, near: selection.bounds)
                    }
                } else if let perform = self.onPerform {
                    result = try await perform(selection.text)
                } else {
                    throw CapabilityError.invalid("This tool has no action configured. Reload its source extension and try again.")
                }
                guard self.operationGate.accepts(ticket, selection: self.state,
                                                running: self.isRunning, cancelled: Task.isCancelled) else { return }
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CapabilityError.invalid("The tool returned an empty result.")
                }
                guard result.text.utf8.count <= CapabilityFrame.maximumBytes else {
                    throw CapabilityError.invalid("The tool returned too much text to display.")
                }
                self.operationGate.finish(ticket)
                self.panels.showResult(result, near: selection.bounds)
            } catch {
                guard self.operationGate.accepts(ticket, selection: self.state,
                                                running: self.isRunning, cancelled: Task.isCancelled) else { return }
                self.operationGate.finish(ticket)
                self.panels.showError(error.localizedDescription, near: selection.bounds)
            }
        }
    }

    private func clearSelection() {
        dismiss()
        state.observe(nil)
    }

    private func useManualSelection(_ text: String, at point: CGPoint) {
        clearSelection()
        manualSelection = true
        state.observe(TextSelection(text: text, sourcePID: ProcessInfo.processInfo.processIdentifier,
                                    rangeLocation: -1, rangeLength: text.utf16.count,
                                    bounds: CGRect(x: point.x, y: point.y, width: 1, height: 20)))
    }
}
