import Foundation
import MacHelper

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
    public var onPerformSelectionStreaming: (@MainActor (CapabilitySelectionInput, @escaping @MainActor (CapabilityTranslationResult) -> Void) async throws -> CapabilityTranslationResult)?
    public var onStatusChange: (() -> Void)?
    public private(set) var isRunning = false

    private let monitor = SelectionMonitor()
    private let panels: FloatingCapabilityPanels
    private var state = SelectionState()
    private var operationTask: Task<Void, Never>?
    private var operationGate = CapabilityOperationGate()

    public init(title: String, systemSymbolName: String = "character.bubble") {
        panels = FloatingCapabilityPanels(toolTitle: title, systemSymbolName: systemSymbolName)
        panels.onPerform = { [weak self] in self?.performSelection() }
        panels.onDismiss = { [weak self] in self?.dismiss() }
        monitor.shouldIgnoreOutsideClick = { [weak self] in self?.panels.contains($0) == true }
        monitor.isInteractingWithOverlay = { [weak self] in self?.panels.isDraggingResultPanel == true }
        monitor.onRead = { [weak self] in self?.receive($0) }
        monitor.onDismiss = { [weak self] in self?.dismiss() }
        monitor.onFrontApplicationChange = { [weak self] in self?.clearSelection() }
        monitor.onSelectionGesture = { [weak self] selecting in
            guard let self, selecting else { return }
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

    public func dismiss() {
        operationGate.invalidate()
        operationTask?.cancel()
        operationTask = nil
        state.dismiss()
        panels.hide()
    }

    private func receive(_ value: SelectionReadResult) {
        guard isRunning else { return }
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
                let input = await self.monitor.input(for: selection)
                guard self.operationGate.accepts(ticket, selection: self.state,
                                                running: self.isRunning, cancelled: Task.isCancelled) else { return }
                let progress: @MainActor (CapabilityTranslationResult) -> Void = { [weak self] progress in
                    guard let self, self.operationGate.accepts(ticket, selection: self.state,
                                                             running: self.isRunning, cancelled: Task.isCancelled),
                          progress.text.utf8.count <= CapabilityFrame.maximumBytes else { return }
                    self.panels.showProgress(progress, near: selection.bounds)
                }
                let result: CapabilityTranslationResult
                if let streaming = self.onPerformSelectionStreaming {
                    result = try await streaming(input, progress)
                } else {
                    throw CapabilityError.invalid(L("This tool has no action configured. Reload its source extension and try again."))
                }
                guard self.operationGate.accepts(ticket, selection: self.state,
                                                running: self.isRunning, cancelled: Task.isCancelled) else { return }
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CapabilityError.invalid(L("The tool returned an empty result."))
                }
                guard result.text.utf8.count <= CapabilityFrame.maximumBytes else {
                    throw CapabilityError.invalid(L("The tool returned too much text to display."))
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

}
