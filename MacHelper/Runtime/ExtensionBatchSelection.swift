import Foundation

/// The installed-list metadata needed to plan a batch without running tools.
public struct ExtensionBatchItem: Equatable, Sendable {
    public let id: String
    public let installed: Bool
    public let enabled: Bool

    public init(id: String, installed: Bool, enabled: Bool) {
        self.id = id; self.installed = installed; self.enabled = enabled
    }
}

public enum ExtensionBatchAction: Sendable {
    case reload, editSource, enable, disable
}

/// Batch selection belongs to extension identities, independently of whichever
/// detail page is open. Discovery and status updates never select new tools.
public struct ExtensionBatchSelection: Equatable, Sendable {
    public private(set) var selectedIDs: Set<String> = []

    public init() {}

    public mutating func reconcile(items: [ExtensionBatchItem]) {
        selectedIDs.formIntersection(installedIDs(items))
    }

    public mutating func setSelected(_ selected: Bool, id: String, items: [ExtensionBatchItem]) {
        reconcile(items: items)
        if selected, installedIDs(items).contains(id) { selectedIDs.insert(id) }
        else { selectedIDs.remove(id) }
    }

    public mutating func selectAll(_ selected: Bool, items: [ExtensionBatchItem]) {
        selectedIDs = selected ? installedIDs(items) : []
    }

    /// Preserve visible list order, omit duplicate identities, and avoid state
    /// changes for tools already enabled/disabled. Reload never enables a tool.
    public func targets(for action: ExtensionBatchAction, items: [ExtensionBatchItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.installed, selectedIDs.contains(item.id), seen.insert(item.id).inserted else { return nil }
            switch action {
            case .editSource: return item.id
            case .reload, .disable: return item.enabled ? item.id : nil
            case .enable: return item.enabled ? nil : item.id
            }
        }
    }

    private func installedIDs(_ items: [ExtensionBatchItem]) -> Set<String> {
        Set(items.filter(\.installed).map(\.id))
    }
}
