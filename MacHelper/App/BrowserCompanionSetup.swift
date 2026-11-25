import AppKit
import MacHelper

extension SourceCompanionBrowser {
    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    var appBundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .firefox: return "org.mozilla.firefox"
        case .safari: return "com.apple.Safari"
        }
    }
}

/// Listen for first use and refresh on opening Settings. Ordinary application
/// switches do not trigger writes, downloads, or prompts.
@MainActor
final class BrowserCompanionDiscovery {
    var onChange: (() -> Void)?
    private let workspace = NSWorkspace.shared
    private let lookup: (String) -> URL?
    private var observers: [NSObjectProtocol] = []
    private(set) var applications: [SourceCompanionBrowser: URL] = [:]

    init(lookup: ((String) -> URL?)? = nil) {
        self.lookup = lookup ?? { identifier in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: identifier)
                ?? workspace.runningApplications.first { $0.bundleIdentifier == identifier }?.bundleURL
        }
        if lookup != nil { refresh(); return }
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
        ]
        observers = names.map { name in
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let browser = SourceCompanionBrowser.allCases.first(where: { $0.appBundleIdentifier == app.bundleIdentifier })
                else { return }
                let url = app.bundleURL
                Task { @MainActor in self?.refresh(launched: browser, at: url) }
            }
        }
        refresh()
    }

    deinit {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
    }

    func refresh(launched browser: SourceCompanionBrowser? = nil, at url: URL? = nil) {
        let next = Dictionary(uniqueKeysWithValues: SourceCompanionBrowser.allCases.compactMap { candidate in
            (lookup(candidate.appBundleIdentifier)
                ?? (candidate == browser ? url : nil)).map { (candidate, $0) }
        })
        guard next != applications else { return }
        applications = next
        onChange?()
    }
}

@MainActor
enum BrowserCompanionSetup {
    static func begin(_ item: SourceBrowserCompanion, for toolID: String, manager: SourceExtensionManager,
                      discovery: BrowserCompanionDiscovery) async throws {
        discovery.refresh()
        guard let app = discovery.applications[item.browser], manager.approvedBrowserCompanions(for: toolID).contains(item) else {
            throw BrowserSupportError.invalid(L("The browser or its companion approval changed."))
        }
        let installer = ManagedCompanionInstaller()
        if let address = item.storeURL, let url = URL(string: address) {
            try await register(item, with: installer, manager: manager)
            try check(item, for: toolID, manager: manager, discovery: discovery, app: app)
            if item.browser == .safari {
                try open(url)
            } else {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
            }
        } else if item.packageURL != nil {
            let data = try await installer.fetchDevelopmentPackage(item)
            try check(item, for: toolID, manager: manager, discovery: discovery, app: app)
            let folder = try await Task.detached(priority: .utility) {
                try installer.stageDevelopmentPackage(data, for: item, toolID: toolID)
            }.value
            try check(item, for: toolID, manager: manager, discovery: discovery, app: app)
            try await register(item, with: installer, manager: manager)
            try check(item, for: toolID, manager: manager, discovery: discovery, app: app)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            let alert = NSAlert()
            alert.messageText = L("Finish setup in %@", item.browser.displayName)
            alert.informativeText = item.browser == .firefox
                ? L("In Firefox, open about:debugging, choose This Firefox and Load Temporary Add-on, then select manifest.json in the prepared folder.")
                : L("Open your browser’s Extensions page, turn on Developer mode, and use Load unpacked to select the prepared folder.")
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        } else if let address = item.sourceURL, let url = URL(string: address) {
            try open(url)
        } else {
            throw BrowserSupportError.invalid(L("This browser companion has no published setup link."))
        }
    }

    private static func check(_ item: SourceBrowserCompanion, for toolID: String, manager: SourceExtensionManager,
                              discovery: BrowserCompanionDiscovery, app: URL) throws {
        try Task.checkCancellation()
        discovery.refresh()
        guard discovery.applications[item.browser] == app, manager.approvedBrowserCompanions(for: toolID).contains(item) else {
            throw BrowserSupportError.invalid(L("The browser or its companion approval changed."))
        }
    }

    private static func register(_ item: SourceBrowserCompanion, with installer: ManagedCompanionInstaller,
                                 manager: SourceExtensionManager) async throws {
        guard item.browser != .safari else { return }
        let identifiers = Set(manager.tools.flatMap { manager.approvedBrowserCompanions(for: $0.id) }
            .filter { $0.browser == item.browser }.map(\.identifier))
        let app = Bundle.main.bundleURL
        try await Task.detached(priority: .utility) {
            try installer.register(item.browser, identifiers: identifiers, from: app)
        }.value
    }

    private static func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw BrowserSupportError.invalid(L("MacHelper could not open the browser companion setup link."))
        }
    }
}
