import AppKit
import Darwin
import MacHelper

@main
enum MacHelperApplication {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--verify-source-extensions") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await SourceExtensionVerification.run()) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--verify-extensions") {
            app.setActivationPolicy(.prohibited)
            ExtensionVerification.run()
            return
        }
        let delegate = MacHelperAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class MacHelperAppDelegate: NSObject, NSApplicationDelegate {
    private let login = LoginItemManager()
    private var window: NSWindow!
    private var tabs: NSSegmentedControl!
    private var container: NSView!
    private var statusItem: NSStatusItem?
    private let ai = AISettingsViewController()
    private var extensions: SourceExtensionsViewController!
    private var nativeExtensions: ExtensionsViewController!
    private var sourceManager: SourceExtensionManager!
    private var startupTask: Task<Void, Never>?
    private var general: GeneralSettingsViewController!
    private var currentController: NSViewController?
    private var rootController: NSViewController!
    private var registry: ExtensionRegistry!
    private var pendingSettingsTab: Int?
    private var sourceManagerReady = false
    private var marketplaceRequests: [MarketplaceInstallRequest] = []
    private var marketplaceTask: Task<Void, Never>?
    private var pendingMarketplaceError: String?
    private var terminating = false
    private var browserSupportTask: Task<Void, Never>?
    private var browserSupportFailure: String?
    private var browserSupportMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenus()
        registry = ExtensionRegistry(
            bundledDirectory: Bundle.main.builtInPlugInsURL,
            helperExecutableURL: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mac-helper-host")
                ?? ExtensionRegistry.defaultHelperExecutableURL,
            openAISettings: { [weak self] in self?.showSettings(tab: 0) },
            hideSettings: { [weak self] in self?.window?.orderOut(nil) })
        registry.refresh()
        registry.startEnabled()
        let bin = Bundle.main.executableURL!.deletingLastPathComponent()
        sourceManager = SourceExtensionManager(workerExecutableURL: bin.appendingPathComponent("MacHelperScriptWorker"),
            helperExecutableURL: bin.appendingPathComponent("mac-helper-host"),
            bundledCatalogURL: Bundle.main.resourceURL!.appendingPathComponent("SourceCatalog/extensions.json"),
            bundledSeedDirectory: Bundle.main.resourceURL!.appendingPathComponent("SourceSeeds/Translation"))
        sourceManager.onOpenAISettings = { [weak self] in self?.showSettings(tab: 0) }
        sourceManager.onHideSettings = { [weak self] in self?.window?.orderOut(nil) }
        extensions = SourceExtensionsViewController(manager: sourceManager)
        nativeExtensions = ExtensionsViewController(registry: registry)
        extensions.onShowNativeExtensions = { [weak self] in self?.showNativeExtensions() }
        extensions.onOpenMarketplace = { [weak self] in self?.openMarketplace() }
        general = GeneralSettingsViewController(login: login)
        createWindow()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.sourceManager.start()
            guard !Task.isCancelled, !self.terminating else { return }
            self.sourceManagerReady = true
            self.processMarketplaceRequests()
        }
        startBrowserSupportBootstrap()
        // The first Apple open event carries the login launch reason. Do not
        // open a window here: a login launch must remain in the menu bar.
        if CommandLine.arguments.contains("--settings") { showSettings(tab: 1) }
        else if let pending = pendingSettingsTab { pendingSettingsTab = nil; showSettings(tab: pending) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !LoginItemManager.isLoginLaunch
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !LoginItemManager.isLoginLaunch else { return false }
        showSettings(tab: 1)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening Settings leaves every extension's selection/result intact.
        // Status-item windows are visible even when there is no settings window.
        showSettings(tab: 1)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !terminating else { return }
        let development = Bundle.main.object(forInfoDictionaryKey: MarketplaceConfiguration.developmentKey) as? Bool == true
        for url in urls.prefix(8) {
            do {
                let request = try MarketplaceInstallRequest(url: url, allowLocalDevelopment: development)
                guard marketplaceRequests.count < 8 else { break }
                if !marketplaceRequests.contains(request) { marketplaceRequests.append(request) }
            } catch { pendingMarketplaceError = error.localizedDescription }
        }
        processMarketplaceRequests()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        browserSupportTask?.cancel()
        marketplaceTask?.cancel()
        marketplaceRequests.removeAll()
        startupTask?.cancel()
        registry?.stopAll()
        guard sourceManager != nil else { return .terminateNow }
        Task { [weak self] in await self?.sourceManager.stopAll(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if general != nil, currentController === general { general.refreshStatus() }
    }

    private func createMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MacHelper")
        appMenu.addItem(withTitle: "MacHelper Settings…", action: #selector(openExtensions), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Marketplace…", action: #selector(openMarketplace), keyEquivalent: "").target = self
        let appBrowserSupport = appMenu.addItem(withTitle: "Install Browser Support…", action: #selector(installBrowserSupport), keyEquivalent: "")
        appBrowserSupport.target = self
        browserSupportMenuItems.append(appBrowserSupport)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacHelper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                       ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                       ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "MacHelper")
        item.button?.toolTip = "MacHelper · AI connection and extensions"
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Extensions…", action: #selector(openExtensions), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Marketplace…", action: #selector(openMarketplace), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "AI Connection…", action: #selector(openAI), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "General…", action: #selector(openGeneral), keyEquivalent: "").target = self
        let statusBrowserSupport = statusMenu.addItem(withTitle: "Install Browser Support…", action: #selector(installBrowserSupport), keyEquivalent: "")
        statusBrowserSupport.target = self
        browserSupportMenuItems.append(statusBrowserSupport)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit MacHelper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = statusMenu
        statusItem = item
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 710),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MacHelper"
        window.isReleasedWhenClosed = false
        rootController = NSViewController()
        rootController.view = NSView()
        window.contentViewController = rootController
        let title = NSTextField(labelWithString: "MacHelper")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "One AI connection. Your Mac tools.")
        subtitle.textColor = .secondaryLabelColor
        tabs = NSSegmentedControl(labels: ["AI Connection", "Extensions", "General"], trackingMode: .selectOne,
                                  target: self, action: #selector(tabChanged))
        tabs.selectedSegment = 1
        tabs.setAccessibilityLabel("Settings section")
        container = NSView()
        let root = window.contentView!
        for view in [title, subtitle, tabs!, container!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            tabs.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        showTab(1)
        window.center()
    }

    private func showSettings(tab: Int) {
        guard window != nil else { pendingSettingsTab = tab; return }
        do { try login.configureDefaultIfNeeded(isLoginLaunch: LoginItemManager.isLoginLaunch) }
        catch { general.registrationError = error.localizedDescription }
        showTab(tab)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showTab(_ index: Int) {
        tabs.selectedSegment = index
        currentController?.view.removeFromSuperview()
        currentController?.removeFromParent()
        let controller: NSViewController = index == 0 ? ai : index == 1 ? extensions : general
        currentController = controller
        rootController.addChild(controller)
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        if index == 1 { extensions.refreshDisplay() }
        if index == 2 { general.refreshStatus() }
    }

    private func showNativeExtensions() {
        currentController?.view.removeFromSuperview()
        currentController?.removeFromParent()
        currentController = nativeExtensions
        rootController.addChild(nativeExtensions)
        let view = nativeExtensions.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        nativeExtensions.refreshDisplay()
    }

    private func processMarketplaceRequests() {
        guard sourceManagerReady, !terminating, marketplaceTask == nil else { return }
        guard pendingMarketplaceError != nil || !marketplaceRequests.isEmpty else { return }
        marketplaceTask = Task { [weak self] in
            guard let self else { return }
            defer { self.marketplaceTask = nil }
            while !Task.isCancelled, !self.terminating {
                if let error = self.pendingMarketplaceError {
                    self.pendingMarketplaceError = nil
                    self.showMarketplaceError(error)
                    continue
                }
                guard !self.marketplaceRequests.isEmpty else { break }
                let request = self.marketplaceRequests.removeFirst()
                do {
                    self.showSettings(tab: 1)
                    let preview = try await self.sourceManager.previewMarketplaceInstall(request)
                    try Task.checkCancellation()
                    if self.sourceManager.sourceURL(for: request.extensionID) != nil {
                        // Website links never replace or re-enable an existing
                        // editable copy, even if its upstream version changed.
                        self.showSettings(tab: 1)
                        self.extensions.selectTool(request.extensionID)
                        continue
                    }
                    guard self.reviewMarketplaceInstall(preview) else { continue }
                    _ = try await self.sourceManager.installReviewedMarketplaceTool(preview)
                    try Task.checkCancellation()
                    self.showSettings(tab: 1)
                    self.extensions.selectTool(request.extensionID)
                } catch {
                    if !Task.isCancelled, !self.terminating { self.showMarketplaceError(error.localizedDescription) }
                }
            }
        }
    }

    private func reviewMarketplaceInstall(_ preview: MarketplaceInstallPreview) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install \(preview.manifest.displayName)?"
        let permissionNames = ["selection.read": "Read selected text across apps", "clipboard.read": "Read clipboard text when you request it",
                               "ai.transform": "Send tool requests through your configured AI connection", "ui.panel": "Show tool result panels"]
        let permissions = preview.manifest.permissions.map { "• " + (permissionNames[$0] ?? $0) }.joined(separator: "\n")
        let source = preview.request.catalogURL.host.map { $0 + preview.request.catalogURL.path } ?? preview.request.catalogURL.absoluteString
        alert.informativeText = "\(String(preview.manifest.summary.prefix(360)))\n\nVersion: \(preview.manifest.version)\nCatalog: \(String(source.prefix(360)))\n\nPermissions:\n\(permissions.isEmpty ? "None" : permissions)\n\nInstall source only from publishers you trust. The complete editable source will be downloaded and enabled after you approve."
        alert.addButton(withTitle: "Install & Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMarketplaceError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Marketplace"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showBrowserSupportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Browser support could not be installed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startBrowserSupportBootstrap() {
        let appURL = Bundle.main.bundleURL
        guard BrowserSupportInstaller.isInstalledApplication(appURL), browserSupportTask == nil else { return }
        browserSupportTask = Task { [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do { _ = try BrowserSupportInstaller().install(from: appURL); return nil }
                catch { return error.localizedDescription }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.browserSupportFailure = failure
            self.browserSupportTask = nil
            self.updateBrowserSupportMenus()
        }
    }

    private func updateBrowserSupportMenus() {
        for item in browserSupportMenuItems {
            item.title = browserSupportFailure == nil ? "Install Browser Support…" : "Browser Support Needs Attention…"
            item.toolTip = browserSupportFailure
        }
    }

    @objc private func tabChanged() { showTab(tabs.selectedSegment) }
    @objc private func openExtensions() { showSettings(tab: 1) }
    @objc private func openAI() { showSettings(tab: 0) }
    @objc private func openGeneral() { showSettings(tab: 2) }
    @objc private func openMarketplace() {
        do {
            let url = try MarketplaceConfiguration.websiteURL()
            guard NSWorkspace.shared.open(url) else {
                throw MarketplaceError.invalidLink("The marketplace could not be opened in your browser. Try again after checking your default browser.")
            }
        } catch { showMarketplaceError(error.localizedDescription) }
    }
    @objc private func installBrowserSupport() {
        guard browserSupportTask == nil else { return }
        do {
            _ = try BrowserSupportInstaller().install(from: Bundle.main.bundleURL)
            browserSupportFailure = nil
            updateBrowserSupportMenus()
            let alert = NSAlert()
            alert.messageText = "Browser support is ready"
            alert.informativeText = "Chrome and Edge can now connect to MacHelper. Reload an already-open browser extension to use the updated helper."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } catch {
            browserSupportFailure = error.localizedDescription
            updateBrowserSupportMenus()
            showBrowserSupportError(error.localizedDescription)
        }
    }
}
