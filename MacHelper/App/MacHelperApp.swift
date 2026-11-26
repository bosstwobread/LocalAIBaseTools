import AppKit
import Darwin
import MacHelper
import MacHelperCapabilities

@main
enum MacHelperApplication {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") }) ||
            Bundle.main.bundleIdentifier == "com.localaibasetools.panel-drag-verification" {
            // Synthetic checks are deterministic and never write the user's language preference.
            setenv("MACHELPER_INTERFACE_LANGUAGE", "en", 1)
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--verify-extension-list") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await ExtensionListVerification.run()) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--verify-source-extensions") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await SourceExtensionVerification.run()) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--verify-native-extensions") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await NativeExtensionVerification.run()) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--verify-extensions") {
            app.setActivationPolicy(.prohibited)
            ExtensionVerification.run()
            return
        }
        // An isolated synthetic fixture exercises the real nonactivating panel
        // without loading tools, preferences, providers, or selected text.
        if CommandLine.arguments.contains("--verify-panel-drag") ||
            Bundle.main.bundleIdentifier == "com.localaibasetools.panel-drag-verification" {
            app.setActivationPolicy(.regular)
            let verification = PanelDragVerification()
            verification.onDismiss = { app.terminate(nil) }
            verification.start()
            withExtendedLifetime(verification) { app.run() }
            verification.stop()
            return
        }
        // A regular app keeps its icon in the Dock even when Settings is closed.
        // Verification processes above stay headless and never create Dock icons.
        app.setActivationPolicy(.regular)
        let delegate = MacHelperAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class MacHelperAppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledPreferenceKey = "MacHelperEnabled"
    private static let shortcutPreferenceKey = "MacHelperGlobalShortcut"
    private let login = LoginItemManager()
    private let globalHotKey = GlobalHotKey()
    private let stateTip = MacHelperStateTip()
    private var macHelperEnabled = UserDefaults.standard.object(forKey: MacHelperAppDelegate.enabledPreferenceKey) as? Bool ?? true
    private var preferredShortcut = GlobalShortcut.load(from: UserDefaults.standard.data(forKey: MacHelperAppDelegate.shortcutPreferenceKey))
    private var shortcutAvailable = false
    private var isRecordingShortcut = false
    private var window: NSWindow!
    private var navigationButtons: [Int: SettingsNavigationButton] = [:]
    private var selectedSection = 1
    private var container: NSView!
    private var statusItem: NSStatusItem?
    private var ai = AISettingsViewController()
    private var extensions: ExtensionsViewController!
    private var sourceManager: SourceExtensionManager!
    private var startupTask: Task<Void, Never>?
    private var general: GeneralSettingsViewController!
    private var currentController: NSViewController?
    private var rootController: NSViewController!
    private var pendingSettingsTab: Int?
    private var sourceManagerReady = false
    private var marketplaceRequests: [MarketplaceInstallRequest] = []
    private var marketplaceTask: Task<Void, Never>?
    private var pendingMarketplaceError: String?
    private var terminating = false
    private var browserSupportTask: Task<Void, Never>?
    private var browserSupportFailure: String?
    private var browserSupportMenuItems: [NSMenuItem] = []
    private var companionSetupMenuItems: [NSMenuItem] = []
    private let websiteService = MarketplaceLocalService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenus()
        let bin = Bundle.main.executableURL!.deletingLastPathComponent()
        let marketplaceCatalog = try? MarketplaceConfiguration.websiteURL().appendingPathComponent("catalog.json")
        sourceManager = SourceExtensionManager(workerExecutableURL: bin.appendingPathComponent("MacHelperScriptWorker"),
            helperExecutableURL: bin.appendingPathComponent("mac-helper-host"),
            marketplaceCatalogURL: marketplaceCatalog)
        extensions = ExtensionsViewController(manager: sourceManager)
        configureExtensionsCallbacks()
        sourceManager.setSelectionActionsEnabled(macHelperEnabled)
        shortcutAvailable = registerShortcut(preferredShortcut)
        configureGeneralSettings()
        bindWebsiteConnectionControls()
        createWindow()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.sourceManager.start()
            guard !Task.isCancelled, !self.terminating else { return }
            self.sourceManagerReady = true
            self.processMarketplaceRequests()
            try? await self.sourceManager.checkForUpdates(includeConfigured: false)
        }
        startBrowserSupportBootstrap()
        startWebsiteConnection()
        // The first Apple open event carries the login launch reason. Do not
        // open a window here: a login launch must remain in the background.
        if CommandLine.arguments.contains("--settings") { showSettings(tab: 1) }
        else if let pending = pendingSettingsTab { pendingSettingsTab = nil; showSettings(tab: pending) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !LoginItemManager.isLoginLaunch
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !LoginItemManager.isLoginLaunch else { return false }
        showSettings(tab: selectedSection)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening Settings leaves every extension's selection/result intact.
        // Status-item windows are visible even when there is no settings window.
        showSettings(tab: selectedSection)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !terminating else { return }
        let development = Bundle.main.object(forInfoDictionaryKey: MarketplaceConfiguration.developmentKey) as? Bool == true
        for url in urls.prefix(8) {
            if url.absoluteString == "machelper://open" {
                if sourceManager != nil, websiteService.state == .stopped { startWebsiteConnection() }
                pendingSettingsTab = sourceManager == nil ? 0 : nil
                if sourceManager != nil { showSettings(tab: 0) }
                continue
            }
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
        general?.cancelShortcutRecording()
        globalHotKey.unregister()
        stateTip.dismiss()
        browserSupportTask?.cancel()
        websiteService.stop()
        marketplaceTask?.cancel()
        marketplaceRequests.removeAll()
        startupTask?.cancel()
        guard sourceManager != nil else { return .terminateNow }
        Task { [weak self] in await self?.sourceManager.stopAll(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if general != nil, currentController === general { general.refreshStatus() }
        extensions?.refreshBrowserDetection()
    }

    func applicationDidResignActive(_ notification: Notification) {
        general?.cancelShortcutRecording()
    }

    private func createMenus() {
        browserSupportMenuItems.removeAll()
        companionSetupMenuItems.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: L("MacHelper"))
        appMenu.addItem(withTitle: L("MacHelper Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L("Marketplace…"), action: #selector(openMarketplace), keyEquivalent: "").target = self
        let appBrowserSupport = appMenu.addItem(withTitle: L("Install Browser Support…"), action: #selector(installBrowserSupport), keyEquivalent: "")
        appBrowserSupport.target = self
        browserSupportMenuItems.append(appBrowserSupport)
        addCompanionSetupMenuItem(to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit MacHelper"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit"))
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                       ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                       ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: L(title), action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "MacHelper")
        item.button?.toolTip = L("MacHelper · AI connection and extensions")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: L("Extensions…"), action: #selector(openExtensions), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: L("Marketplace…"), action: #selector(openMarketplace), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: L("AI Connection…"), action: #selector(openAI), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: L("General…"), action: #selector(openGeneral), keyEquivalent: "").target = self
        let statusBrowserSupport = statusMenu.addItem(withTitle: L("Install Browser Support…"), action: #selector(installBrowserSupport), keyEquivalent: "")
        statusBrowserSupport.target = self
        browserSupportMenuItems.append(statusBrowserSupport)
        addCompanionSetupMenuItem(to: statusMenu)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: L("Quit MacHelper"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = statusMenu
        statusItem = item
        updateCompanionSetupMenus(available: extensions?.nextBrowserSetupTool != nil)
    }

    private func configureExtensionsCallbacks() {
        extensions.onOpenMarketplace = { [weak self] in self?.openMarketplace() }
        extensions.onBrowserSetupAvailable = { [weak self] available in
            self?.updateCompanionSetupMenus(available: available)
        }
    }

    private func addCompanionSetupMenuItem(to menu: NSMenu) {
        let item = menu.addItem(withTitle: L("Set Up Browser Companions…"), action: #selector(openCompanionSetup), keyEquivalent: "")
        item.target = self
        companionSetupMenuItems.append(item)
    }

    private func updateCompanionSetupMenus(available: Bool) {
        for item in companionSetupMenuItems { item.isHidden = !available || !macHelperEnabled }
    }

    private func createWindow() {
        let previousFrame = window?.frame
        let firstWindow = previousFrame == nil
        currentController?.view.removeFromSuperview()
        currentController?.removeFromParent()
        currentController = nil
        navigationButtons.removeAll()
        let minimumSize = NSSize(width: 940, height: 650)
        if firstWindow {
            var initialSize = NSSize(width: 1060, height: 760)
            if let visible = NSScreen.main?.visibleFrame {
                initialSize.width = min(initialSize.width, max(minimumSize.width, visible.width - 64))
                initialSize.height = min(initialSize.height, max(minimumSize.height, visible.height - 64))
            }
            window = SettingsWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            window.title = "MacHelper"
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isReleasedWhenClosed = false
        }
        let settingsFrame = previousFrame ?? window.frame
        let root = Self.settingsSurface(material: .popover, darkTintOpacity: 0.55)
        // AppKit sizes the window from the incoming content view controller.
        root.frame = NSRect(origin: .zero, size: settingsFrame.size)
        rootController = NSViewController()
        rootController.view = root
        window.contentViewController = rootController

        let sidebar = Self.settingsSurface(material: .sidebar, darkTintOpacity: 0.47)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.setAccessibilityLabel(L("Settings navigation"))
        let title = NSTextField(labelWithString: L("MacHelper"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L("Settings"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(header)

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 5
        navigation.translatesAutoresizingMaskIntoConstraints = false
        for (index, name, symbol) in [(2, "General", "gearshape"), (0, "AI Connection", "sparkles"), (1, "Extensions", "puzzlepiece.extension")] {
            let button = SettingsNavigationButton(title: L(name), symbol: symbol, target: self, action: #selector(sectionChanged(_:)))
            button.tag = index
            navigationButtons[index] = button
            navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
        }
        sidebar.addSubview(navigation)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let footer = NSTextField(labelWithString: "LocalAIBaseTools · \(version)")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(footer)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // The glass spans the title bar, while controls start below it.
        let contentTop = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? root.topAnchor
        for view in [sidebar, divider, container!] {
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Full-size content participates in layout before the window is shown.
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: contentTop, constant: 24),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            navigation.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 28),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            container.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentTop),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        applyAppLanguageDirection(to: rootController.view)
        showTab(selectedSection)
        window.contentMinSize = minimumSize
        if window.frame != settingsFrame { window.setFrame(settingsFrame, display: false) }
        if firstWindow { window.center() }
    }

    private static func settingsSurface(material: NSVisualEffectView.Material, darkTintOpacity: CGFloat) -> NSView {
        let glass = MacHelperFrostedSurface(material: material)
        let tint = NSBox(frame: glass.bounds)
        tint.boxType = .custom
        tint.borderType = .noBorder
        tint.titlePosition = .noTitle
        tint.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(darkTintOpacity)
                : .clear
        }
        tint.autoresizingMask = [.width, .height]
        tint.setAccessibilityElement(false)
        glass.addSubview(tint)
        return glass
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
        selectedSection = index
        navigationButtons.forEach { $0.value.isSelected = $0.key == index }
        let controller: NSViewController
        switch index {
        case 0: controller = ai
        case 1: controller = extensions
        default: controller = general
        }
        if currentController === controller {
            if index == 1 { extensions.refreshDisplay() }
            if index == 2 { general.refreshStatus() }
            return
        }
        if currentController === general { general.cancelShortcutRecording() }
        window.makeFirstResponder(nil)
        currentController?.view.removeFromSuperview()
        currentController?.removeFromParent()
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
        applyAppLanguageDirection(to: view)
        if index == 1 { extensions.refreshDisplay() }
        if index == 2 { general.refreshStatus() }
    }

    private func changeInterfaceLanguage(_ code: String) -> Bool {
        guard code != AppLocalization.shared.language else { return true }
        // Rebuilding presentation must never discard an unfinished prompt or AI setting.
        guard !extensions.hasPendingOperations, !extensions.hasUnsavedPromptChanges,
              !ai.hasPendingChanges, marketplaceTask == nil else {
            let alert = NSAlert()
            alert.messageText = L("Finish your changes first")
            alert.informativeText = L("Save or revert unsaved prompts and AI settings, and wait for current operations before changing the interface language.")
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return false
        }
        general.cancelShortcutRecording()
        stateTip.dismiss()
        AppLocalization.shared.language = code
        extensions = ExtensionsViewController(manager: sourceManager)
        configureExtensionsCallbacks()
        ai = AISettingsViewController()
        bindWebsiteConnectionControls()
        configureGeneralSettings()
        createMenus()
        updateBrowserSupportMenus()
        createWindow()
        general.refreshStatus()
        return true
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
        alert.messageText = L("Install %@?", preview.manifest.displayName)
        let permissions = sourcePermissionReviewText(preview.manifest.permissions)
        let source = preview.request.catalogURL.host.map { $0 + preview.request.catalogURL.path } ?? preview.request.catalogURL.absoluteString
        alert.informativeText = L("%@\n\nVersion: %@\nCatalog: %@\n\nPermissions:\n%@\n\nInstall source only from publishers you trust. The complete editable source will be downloaded and enabled after you approve.", String(preview.manifest.summary.prefix(360)), preview.manifest.version, String(source.prefix(360)), permissions)
        alert.addButton(withTitle: L("Install & Enable"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMarketplaceError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("Marketplace")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showBrowserSupportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("Browser support could not be installed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func bindWebsiteConnectionControls() {
        ai.websiteConnectionEnabled = macHelperEnabled
        ai.websiteConnectionState = websiteService.state
        ai.onRestartWebsiteConnection = { [weak self] in
            guard let self, self.macHelperEnabled else { return }
            self.websiteService.stop()
            self.startWebsiteConnection()
        }
        websiteService.onStateChange = { [weak self] state in self?.ai.websiteConnectionState = state }
    }

    private func startWebsiteConnection() {
        guard macHelperEnabled, !terminating else { return }
        do { try websiteService.start() }
        catch { ai.websiteConnectionState = .failed(error.localizedDescription) }
    }

    private func configureGeneralSettings() {
        general = GeneralSettingsViewController(login: login)
        general.onLanguageChange = { [weak self] code in self?.changeInterfaceLanguage(code) ?? false }
        general.onMacHelperEnabledChange = { [weak self] enabled in self?.setMacHelperEnabled(enabled) }
        general.onBeginShortcutRecording = { [weak self] in self?.beginShortcutRecording() }
        general.onFinishShortcutRecording = { [weak self] shortcut in self?.finishShortcutRecording(shortcut) ?? false }
        general.onResetShortcut = { [weak self] in self?.saveShortcut(.defaultShortcut) ?? false }
        updateGeneralMacHelperState()
    }

    private func updateGeneralMacHelperState() {
        general.updateMacHelperState(isEnabled: macHelperEnabled, shortcut: preferredShortcut.displayName,
                                     shortcutAvailable: shortcutAvailable)
    }

    private func registerShortcut(_ shortcut: GlobalShortcut) -> Bool {
        globalHotKey.register(shortcut) { [weak self] in
            guard let self, !self.isRecordingShortcut else { return }
            self.setMacHelperEnabled(!self.macHelperEnabled)
        }
    }

    private func beginShortcutRecording() {
        guard !terminating, !isRecordingShortcut else { return }
        isRecordingShortcut = true
        globalHotKey.unregister()
    }

    private func finishShortcutRecording(_ shortcut: GlobalShortcut?) -> Bool {
        guard !terminating, isRecordingShortcut else { return false }
        isRecordingShortcut = false
        if let shortcut, saveShortcut(shortcut) { return true }
        shortcutAvailable = registerShortcut(preferredShortcut)
        updateGeneralMacHelperState()
        return shortcut == nil
    }

    private func saveShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard !terminating, !isRecordingShortcut, let preference = try? JSONEncoder().encode(shortcut),
              registerShortcut(shortcut) else { return false }
        preferredShortcut = shortcut
        shortcutAvailable = true
        UserDefaults.standard.set(preference, forKey: Self.shortcutPreferenceKey)
        updateGeneralMacHelperState()
        return true
    }

    private func setMacHelperEnabled(_ enabled: Bool) {
        guard enabled != macHelperEnabled, !terminating else { return }
        macHelperEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledPreferenceKey)
        sourceManager.setSelectionActionsEnabled(enabled)
        updateCompanionSetupMenus(available: extensions.nextBrowserSetupTool != nil)
        ai.websiteConnectionEnabled = enabled
        updateGeneralMacHelperState()
        if enabled { startWebsiteConnection() }
        else { websiteService.stop() }
        stateTip.show(isEnabled: enabled)
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
            item.title = browserSupportFailure == nil ? L("Install Browser Support…") : L("Browser Support Needs Attention…")
            item.toolTip = browserSupportFailure
        }
    }

    @objc private func sectionChanged(_ sender: NSButton) {
        if sender.tag == 1 { extensions.showOverview() }
        showTab(sender.tag)
    }
    @objc private func openSettings() { showSettings(tab: selectedSection) }
    @objc private func openExtensions() {
        extensions.showOverview()
        showSettings(tab: 1)
    }
    @objc private func openCompanionSetup() {
        guard let id = extensions.nextBrowserSetupTool else { return }
        showSettings(tab: 1)
        extensions.selectTool(id)
    }
    @objc private func openAI() { showSettings(tab: 0) }
    @objc private func openGeneral() { showSettings(tab: 2) }
    @objc private func openMarketplace() {
        do {
            let url = try MarketplaceConfiguration.websiteURL()
            guard NSWorkspace.shared.open(url) else {
                throw MarketplaceError.invalidLink(L("The marketplace could not be opened in your browser. Try again after checking your default browser."))
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
            alert.messageText = L("Browser support is ready")
            alert.informativeText = L("Chrome and Edge can now connect to MacHelper. Reload an already-open browser extension to use the updated helper.")
            alert.addButton(withTitle: L("OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } catch {
            browserSupportFailure = error.localizedDescription
            updateBrowserSupportMenus()
            showBrowserSupportError(error.localizedDescription)
        }
    }
}
