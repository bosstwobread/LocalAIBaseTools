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
    private let registeredApplications: (String) -> [URL]
    private let runningApplications: (String) -> [URL]
    private let applicationDirectories: [URL]
    private var observers: [NSObjectProtocol] = []
    private(set) var applications: [SourceCompanionBrowser: URL] = [:]

    convenience init() {
        let directories = FileManager.default.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask])
        let systemAppDirectory = URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true)
        // Safari ships here on newer macOS versions. Launch Services can return its real bundle URL.
        self.init(applicationDirectories: directories + [systemAppDirectory, systemAppDirectory.resolvingSymlinksInPath()],
                  registeredApplications: { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) },
                  runningApplications: { identifier in
                      NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                          .filter { !$0.isTerminated }.compactMap(\.bundleURL)
                  })
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        observers = names.map { name in
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let browser = SourceCompanionBrowser.allCases.first(where: { $0.appBundleIdentifier == app.bundleIdentifier })
                else { return }
                let url = name == NSWorkspace.didTerminateApplicationNotification ? nil : app.bundleURL
                Task { @MainActor in self?.refresh(launched: browser, at: url) }
            }
        }
    }

    init(applicationDirectories: [URL], registeredApplications: @escaping (String) -> [URL],
         runningApplications: @escaping (String) -> [URL]) {
        self.applicationDirectories = applicationDirectories.map(\.standardizedFileURL)
        self.registeredApplications = registeredApplications
        self.runningApplications = runningApplications
        refresh()
    }

    deinit {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
    }

    func refresh(launched browser: SourceCompanionBrowser? = nil, at url: URL? = nil) {
        var next: [SourceCompanionBrowser: URL] = [:]
        for candidate in SourceCompanionBrowser.allCases {
            let identifier = candidate.appBundleIdentifier
            let installed = registeredApplications(identifier).first { url in
                isInApplicationDirectory(url) && isBrowserBundle(url, identifier: identifier)
            }
            let running = runningApplications(identifier).first { isBrowserBundle($0, identifier: identifier) }
            let justLaunched = candidate == browser ? url : nil
            next[candidate] = installed ?? running ?? justLaunched.flatMap { url in
                isBrowserBundle(url, identifier: identifier) ? url : nil
            }
        }
        guard next != applications else { return }
        applications = next
        onChange?()
    }

    private func isInApplicationDirectory(_ url: URL) -> Bool {
        // Launch Services also registers copies inside update caches, downloads, and mounted installers.
        let components = url.standardizedFileURL.pathComponents
        return applicationDirectories.contains { directory in
            let parent = directory.pathComponents
            guard components.count > parent.count, components.starts(with: parent) else { return false }
            return !components.dropFirst(parent.count).dropLast().contains {
                $0.hasPrefix(".") || $0.lowercased().hasSuffix(".app")
            }
        }
    }

    private func isBrowserBundle(_ url: URL, identifier: String) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "app" &&
            (try? url.checkResourceIsReachable()) == true && Bundle(url: url)?.bundleIdentifier == identifier
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
