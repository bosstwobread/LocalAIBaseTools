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

public struct CapabilitySelectionAction {
    public let identifier: String
    /// Opaque owner activation generation. Rebuilding another tool must not
    /// invalidate this action; activating new owner source/settings must.
    public let generation: String
    public let title: String
    public let systemSymbolName: String
    public let allowsReplacement: Bool
    public let allowsPaste: Bool
    public let perform: @MainActor (CapabilitySelectionInput, @escaping @MainActor (CapabilityTranslationResult) -> Void) async throws -> CapabilityTranslationResult

    public init(identifier: String, generation: String = "", title: String, systemSymbolName: String? = nil, allowsReplacement: Bool = false, allowsPaste: Bool = false,
                perform: @escaping @MainActor (CapabilitySelectionInput, @escaping @MainActor (CapabilityTranslationResult) -> Void) async throws -> CapabilityTranslationResult) {
        self.identifier = identifier; self.generation = generation
        self.title = title; self.allowsReplacement = allowsReplacement; self.perform = perform
        self.systemSymbolName = systemSymbolName ?? (allowsReplacement ? "pencil.and.outline" : "character.bubble")
        self.allowsPaste = allowsPaste
    }
}

struct SelectionActionIdentity: Equatable {
    let identifier: String
    let generation: String
}

/// Pure action routing preserves manifest order and never substitutes another
/// command when a tool is disabled/reloaded while its panel is open.
struct SelectionActionRouting {
    private(set) var identifiers: [String] = []
    private var identities: [SelectionActionIdentity] = []
    private(set) var selectedIdentity: SelectionActionIdentity?
    var selected: String? { selectedIdentity?.identifier }
    mutating func clearSelection() { selectedIdentity = nil }
    mutating func replace(_ identifiers: [String]) {
        _ = reconcile(identifiers.map { .init(identifier: $0, generation: "") })
    }
    /// The selected command and owner generation are the authority, not the
    /// whole toolbar's membership/order. This also preserves completed previews.
    @discardableResult
    mutating func reconcile(_ identities: [SelectionActionIdentity]) -> Bool {
        self.identities = identities
        identifiers = identities.map(\.identifier)
        guard let selectedIdentity, identities.contains(selectedIdentity) else {
            self.selectedIdentity = nil; return false
        }
        return true
    }
    mutating func select(_ identifier: String) -> Bool {
        guard let identity = identities.first(where: { $0.identifier == identifier }) else { return false }
        selectedIdentity = identity; return true
    }
}

struct SelectionToolbarLayout {
    let visible: [String]
    let overflow: [String]
    init(identifiers: [String]) {
        let count = identifiers.count > 5 ? 4 : identifiers.count
        visible = Array(identifiers.prefix(count))
        overflow = Array(identifiers.dropFirst(count))
    }
}

/// Reusable selected-text actions, explicit edits, and streaming result panels.
/// The host owns lifecycle, settings, and permissions. Source tools supply the
/// asynchronous operation and can be reloaded without rebuilding this module.
@MainActor
public final class SelectionActionCapability {
    public var onPerformSelectionStreaming: (@MainActor (CapabilitySelectionInput, @escaping @MainActor (CapabilityTranslationResult) -> Void) async throws -> CapabilityTranslationResult)?
    public var onStatusChange: (() -> Void)?
    public private(set) var isRunning = false

    private let monitor = SelectionMonitor()
    private let panels: FloatingCapabilityPanels
    private var state = SelectionState()
    private var operationTask: Task<Void, Never>?
    private var operationGate = CapabilityOperationGate()
    private var actions: [CapabilitySelectionAction] = []
    private var routing = SelectionActionRouting()
    private var editTarget: AccessibilitySelectionEditTarget?
    private var completedSelectionGeneration: UInt64?

    public init(title: String, systemSymbolName: String = "character.bubble") {
        panels = FloatingCapabilityPanels(toolTitle: title, systemSymbolName: systemSymbolName)
        panels.onPerform = { [weak self] in self?.performSelection() }
        panels.onPerformAction = { [weak self] identifier in
            guard let self, self.routing.select(identifier) else { return }
            self.performSelection()
        }
        panels.onApply = { [weak self] text in self?.applyResult(text) }
        panels.onDismiss = { [weak self] in self?.dismiss() }
        monitor.shouldIgnoreOutsideClick = { [weak self] in self?.panels.contains($0) == true }
        monitor.isInteractingWithOverlay = { [weak self] in self?.panels.isInteractingWithOverlay == true }
        monitor.onRead = { [weak self] in self?.receive($0) }
        monitor.onDismiss = { [weak self] in self?.dismiss() }
        monitor.onFrontApplicationChange = { [weak self] in self?.clearSelection() }
        monitor.onSelectionGesture = { [weak self] selecting in
            guard let self, selecting else { return }
            if self.state.retainsAppliedPreview { self.dismiss() }
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

    public func setActions(_ actions: [CapabilitySelectionAction], invalidateCurrent: Bool = false) {
        let hadSelectedAction = routing.selectedIdentity != nil
        let preservesOwner = routing.reconcile(actions.map { .init(identifier: $0.identifier, generation: $0.generation) })
        if invalidateCurrent || (hadSelectedAction && !preservesOwner) { dismiss() }
        self.actions = actions
        panels.setActions(actions.map { (identifier: $0.identifier, title: $0.title, systemSymbolName: $0.systemSymbolName) })
        // If only the toolbar is visible, refresh its size/placement for added
        // or removed actions. A streamed/completed result keeps its placement.
        if let selection = state.selection, state.canTranslate { panels.refreshToolbar(near: selection.bounds) }
    }

    public func dismiss() {
        operationGate.invalidate()
        operationTask?.cancel()
        operationTask = nil
        editTarget = nil
        completedSelectionGeneration = nil
        routing.clearSelection()
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
        editTarget = nil
        completedSelectionGeneration = nil
        if state.retainsAppliedPreview { return }
        routing.clearSelection()
        if let selection, state.canTranslate {
            panels.showIcon(near: selection.bounds)
        }
        else { panels.hide() }
    }

    private func performSelection() {
        guard isRunning, state.canTranslate, let selection = state.selection else { return }
        let action: CapabilitySelectionAction?
        if actions.isEmpty { action = nil }
        else {
            guard let identifier = routing.selected,
                  let selected = actions.first(where: { $0.identifier == identifier }) else { return }
            action = selected
            panels.setToolTitle(selected.title)
        }
        operationTask?.cancel()
        let ticket = operationGate.begin(selectionGeneration: state.generation)
        editTarget = action?.allowsReplacement == true ? AccessibilitySelectionEditTarget.capture(selection, allowsPaste: action?.allowsPaste == true) : nil
        completedSelectionGeneration = nil
        panels.configureReplacement(allowed: action?.allowsReplacement == true, available: editTarget != nil)
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
                if let action {
                    result = try await action.perform(input, progress)
                } else if let streaming = self.onPerformSelectionStreaming {
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
                self.completedSelectionGeneration = selection == self.state.selection ? self.state.generation : nil
                self.panels.showResult(result, near: selection.bounds)
            } catch {
                guard self.operationGate.accepts(ticket, selection: self.state,
                                                running: self.isRunning, cancelled: Task.isCancelled) else { return }
                self.operationGate.finish(ticket)
                self.panels.showError(error.localizedDescription, near: selection.bounds)
            }
        }
    }

    private func applyResult(_ text: String) {
        state.retainPreviewAfterApply()
        guard isRunning, let generation = completedSelectionGeneration,
              state.acceptsResult(for: generation), let target = editTarget else {
            panels.replacementFailed(L("The original selection changed. Select the text again, or use Copy."))
            return
        }
        do {
            let outcome = try target.replace(with: text) { [weak self, weak target] in
                guard let self, let target else { return false }
                return self.isRunning && self.state.acceptsResult(for: generation) && self.completedSelectionGeneration == generation && self.editTarget === target
            }
            editTarget = nil; completedSelectionGeneration = nil
            panels.replacementSucceeded(outcome)
        } catch {
            editTarget = nil; completedSelectionGeneration = nil
            panels.replacementFailed(error.localizedDescription)
        }
    }

    private func clearSelection() {
        dismiss()
        state.observe(nil)
    }

}

/// Existing native consumers retain the former type name.
public typealias SelectionTranslationCapability = SelectionActionCapability
