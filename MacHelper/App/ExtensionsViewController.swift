import AppKit
import MacHelper

/// Overview navigation is independent of the schema form. Status/reload updates
/// never recreate a field the user is editing or silently select a catalog tool.
@MainActor
final class ExtensionsViewController: NSViewController, NSTextFieldDelegate {
    typealias SourceFolderOpener = @MainActor ([URL], @escaping @MainActor (Error?) -> Void) -> Void
    typealias SourceUpdateReviewer = @MainActor (SourceExtensionUpdatePreview) -> Bool
    var onOpenMarketplace: (() -> Void)?

    private let manager: SourceExtensionManager
    private let sourceFolderOpener: SourceFolderOpener?
    private let sourceUpdateReviewer: SourceUpdateReviewer?
    private let overview = NSView()
    private let detail = NSView()
    private let overviewScroll = NSScrollView()
    private let overviewDocument = SourceSettingsDocumentView()
    private let overviewStack = NSStackView()
    private let installedList = NSStackView()
    private let availableSection = NSStackView()
    private let availableList = NSStackView()
    private let installedCount = NSTextField(labelWithString: "")
    private let availableCount = NSTextField(labelWithString: "")
    private let checkForUpdatesButton = NSButton(title: L("Check for Updates"), target: nil, action: nil)
    private let selectAllButton = NSButton(checkboxWithTitle: L("Select All"), target: nil, action: nil)
    private let selectionCount = NSTextField(labelWithString: L("%ld selected", 0))
    private let batchReloadButton = NSButton(title: L("Reload"), target: nil, action: nil)
    private let batchEditButton = NSButton(title: L("Edit Source"), target: nil, action: nil)
    private let batchEnableButton = NSButton(title: L("Enable"), target: nil, action: nil)
    private let batchDisableButton = NSButton(title: L("Disable"), target: nil, action: nil)
    private let overviewMessage = NSTextField(wrappingLabelWithString: "")
    private let detailIcon = SourceToolIconView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let updateVersionLabel = NSTextField(wrappingLabelWithString: "")
    private let updateMessage = NSTextField(wrappingLabelWithString: "")
    private let backButton = NSButton(title: L("All Extensions"), target: nil, action: nil)
    private let toggle = NSButton(checkboxWithTitle: L("Enabled"), target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sourceState = NSTextField(wrappingLabelWithString: "")
    private let sourceHelp = NSTextField(wrappingLabelWithString: "")
    private let permissionStatus = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: L("Install Source…"), target: nil, action: nil)
    private let marketplaceButton = NSButton(title: L("Marketplace…"), target: nil, action: nil)
    private let catalogButton = NSButton(title: L("Add Catalog…"), target: nil, action: nil)
    private let guideButton = NSButton(title: L("AI Extension Guide…"), target: nil, action: nil)
    private let editButton = NSButton(title: L("Edit Source"), target: nil, action: nil)
    private let reloadButton = NSButton(title: L("Reload"), target: nil, action: nil)
    private let updateButton = NSButton(title: L("Update…"), target: nil, action: nil)
    private let showBackupButton = NSButton(title: L("Show Backup in Finder"), target: nil, action: nil)
    private let accessibilityButton = NSButton(title: L("Accessibility Settings…"), target: nil, action: nil)
    private let permissionRow = NSStackView()
    private let aiRow = NSStackView()
    private let settingsScroll = NSScrollView()
    private let settingsDocument = SourceSettingsDocumentView()
    private let detailStack = NSStackView()
    private let form = NSStackView()
    private var permissionTimer: Timer?
    private var selectedID: String?
    private var overviewSignature = ""
    private var cards: [String: SourceToolCard] = [:]
    private var overviewSelection = ExtensionBatchSelection()
    private var selectionCheckboxes: [String: NSButton] = [:]
    private var updateButtons: [String: NSButton] = [:]
    private var completedUpdates: [String: (message: String, backup: URL)] = [:]
    private var batchSummary: String?
    private var formToolID: String?
    private var formSignature = ""
    private var controls: [String: NSControl] = [:]
    private var bindings: [ObjectIdentifier: FormBinding] = [:]
    private var pendingValues: [SettingKey: Any] = [:]
    private var promptDrafts: [SettingKey: PromptDraft] = [:]
    private var promptEditors: [String: SourcePromptEditorView] = [:]
    private var pendingFormRebuild = false
    private var operationErrors: [String: OperationFailure] = [:]
    private var globalError: String?
    private var operations: [QueuedOperation] = []
    private var operationTask: Task<Void, Never>?
    private var workingTitle: String?
    private var workingToolID: String?
    private var requestedSelectionID: String?

    init(manager: SourceExtensionManager, sourceFolderOpener: SourceFolderOpener? = nil,
         sourceUpdateReviewer: SourceUpdateReviewer? = nil) {
        self.manager = manager
        self.sourceFolderOpener = sourceFolderOpener
        self.sourceUpdateReviewer = sourceUpdateReviewer
        super.init(nibName: nil, bundle: nil)
        manager.onChange = { [weak self] in self?.refreshDisplay() }
        manager.onApproveNativeExecution = { [weak self] manifest in
            guard self != nil else { return false }
            let alert = NSAlert()
            alert.messageText = L("Enable native extension “%@”?", manifest.displayName)
            alert.informativeText = L("This extension runs compiled Swift code in a separate process with your Mac user account’s access. Enable only source you trust. Changes rebuild and restart this extension while MacHelper stays open.")
            alert.addButton(withTitle: L("Enable Native Extension"))
            alert.addButton(withTitle: L("Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        manager.onApproveSelectionReplacement = { [weak self] manifest in
            guard self != nil else { return false }
            let alert = NSAlert()
            alert.messageText = L("Allow “%@” to replace selected text?", manifest.displayName)
            alert.informativeText = L("Review the result, then click Apply to replace the verified original selection.")
            alert.addButton(withTitle: L("Allow Apply"))
            alert.addButton(withTitle: L("Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        manager.onApproveSelectionPaste = { [weak self] manifest in
            guard self != nil else { return false }
            let alert = NSAlert()
            alert.messageText = L("Allow “%@” to paste results?", manifest.displayName)
            alert.informativeText = L("When you click Apply, MacHelper can paste into the current selection in the original window, even if the editor does not report its position. Pasting leaves the result on the clipboard.")
            alert.addButton(withTitle: L("Allow Paste"))
            alert.addButton(withTitle: L("Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        manager.onApproveCompanion = { [weak self] manifest, grant in
            guard self != nil else { return false }
            let alert = NSAlert()
            alert.messageText = L("Allow a browser companion for “%@”?", manifest.displayName)
            // Keep these exact identifiers legible in right-to-left interface languages.
            let chromeID = "\u{2066}\(grant.chromeExtensionID)\u{2069}"
            let commands = grant.commands.sorted().map { "• \u{2066}\($0)\u{2069}" }.joined(separator: "\n")
            var disclosure = L("Chrome extension %@ can request only these commands.\n\n%@\n\nDisable the extension in MacHelper or pause MacHelper to stop companion requests.", chromeID, commands)
            if grant.allowsAI {
                disclosure += "\n\n" + L("These commands can send data automatically through your saved AI Connection. If you choose ChatGPT, it processes that data online.")
            }
            alert.informativeText = disclosure
            alert.addButton(withTitle: L("Allow Browser Companion"))
            alert.addButton(withTitle: L("Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        for child in [overview, detail] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        installButton.target = self; installButton.action = #selector(installSource)
        installButton.toolTip = L("Install a JavaScript or native Swift extension source folder.")
        marketplaceButton.target = self; marketplaceButton.action = #selector(openMarketplace)
        catalogButton.target = self; catalogButton.action = #selector(addCatalog)
        guideButton.target = self; guideButton.action = #selector(openExtensionGuide)
        guideButton.toolTip = L("Give this guide to your AI assistant to create an extension or customize an existing one.")
        selectAllButton.target = self; selectAllButton.action = #selector(selectAllInstalled)
        selectAllButton.allowsMixedState = true
        selectAllButton.setAccessibilityLabel(L("Select all installed extensions"))
        batchReloadButton.target = self; batchReloadButton.action = #selector(reloadSelected)
        batchReloadButton.toolTip = L("Reload selected enabled extensions. Disabled tools stay disabled.")
        batchEditButton.target = self; batchEditButton.action = #selector(editSelectedSources)
        batchEditButton.toolTip = L("Open every selected extension source folder.")
        batchEnableButton.target = self; batchEnableButton.action = #selector(enableSelected)
        batchDisableButton.target = self; batchDisableButton.action = #selector(disableSelected)
        batchEnableButton.toolTip = L("Enable selected disabled extensions.")
        batchDisableButton.toolTip = L("Disable selected enabled extensions.")
        for (control, id) in [(selectAllButton, "batch-select-all"), (batchReloadButton, "batch-reload"),
                              (batchEditButton, "batch-edit-source"), (batchEnableButton, "batch-enable"),
                              (batchDisableButton, "batch-disable")] {
            control.identifier = NSUserInterfaceItemIdentifier(id)
        }
        selectionCount.identifier = NSUserInterfaceItemIdentifier("batch-selection-count")
        overviewMessage.identifier = NSUserInterfaceItemIdentifier("extension-overview-message")
        editButton.target = self; editButton.action = #selector(editSource)
        editButton.toolTip = L("Open this tool’s installed source folder in VS Code, or Finder if VS Code is unavailable.")
        reloadButton.target = self; reloadButton.action = #selector(reloadSource)
        checkForUpdatesButton.target = self; checkForUpdatesButton.action = #selector(checkForUpdates)
        checkForUpdatesButton.identifier = NSUserInterfaceItemIdentifier("check-for-extension-updates")
        updateButton.target = self; updateButton.action = #selector(updateSelectedTool)
        updateButton.identifier = NSUserInterfaceItemIdentifier("update-current-extension")
        showBackupButton.target = self; showBackupButton.action = #selector(showUpdateBackup)
        accessibilityButton.target = self; accessibilityButton.action = #selector(openAccessibility)
        toggle.target = self; toggle.action = #selector(toggleEnabled)
        backButton.target = self; backButton.action = #selector(backToOverview)
        backButton.image = NSImage(systemSymbolName: AppLocalization.shared.isRightToLeft ? "chevron.right" : "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .inline
        backButton.setAccessibilityLabel(L("Back to all extensions"))
        marketplaceButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        marketplaceButton.imagePosition = .imageLeading
        marketplaceButton.bezelColor = .controlAccentColor
        marketplaceButton.contentTintColor = .white
        buildOverview()
        buildDetail()
        refreshDisplay()
    }

    private func buildOverview() {
        configureScroll(overviewScroll, document: overviewDocument, stack: overviewStack, in: overview)
        let title = Self.label(L("Extensions"), size: 24, weight: .semibold)
        let subtitle = Self.label(L("Manage the tools installed on this Mac."), size: 13, color: .secondaryLabelColor)
        let heading = Self.column([title, subtitle], spacing: 7)
        let header = NSStackView(views: [heading, Self.flexibleSpace(), marketplaceButton])
        header.alignment = .centerY
        header.spacing = 18
        addFullWidth(header, to: overviewStack)
        let toolbar = NSStackView(views: [installButton, catalogButton, guideButton])
        toolbar.spacing = 8
        overviewStack.addArrangedSubview(toolbar)
        let authoringNote = Self.label(L("Create or customize JavaScript and native Swift tools with the same controls. Use the AI guide, import a source folder with Install Source, or open an installed tool with Edit Source."), size: 12, color: .secondaryLabelColor)
        authoringNote.maximumNumberOfLines = 0
        addFullWidth(authoringNote, to: overviewStack)
        overviewMessage.font = .systemFont(ofSize: 12)
        addFullWidth(overviewMessage, to: overviewStack)
        addFullWidth(Self.separator(), to: overviewStack)
        addFullWidth(sectionHeading(L("Installed"), count: installedCount, button: checkForUpdatesButton), to: overviewStack)
        selectionCount.font = .systemFont(ofSize: 11)
        selectionCount.textColor = .secondaryLabelColor
        let selectionActions = NSStackView(views: [selectAllButton, selectionCount, Self.flexibleSpace()])
        selectionActions.spacing = 8
        let lifecycleActions = NSStackView(views: [batchReloadButton, batchEditButton, batchEnableButton, batchDisableButton])
        lifecycleActions.spacing = 8
        let batchActions = Self.column([selectionActions, lifecycleActions], spacing: 10)
        addFullWidth(batchActions, to: overviewStack)
        configureList(installedList)
        addFullWidth(installedList, to: overviewStack)
        let availableHeading = sectionHeading(L("Available from catalogs"), count: availableCount)
        overviewStack.setCustomSpacing(25, after: installedList)
        configureList(availableSection)
        addFullWidth(availableHeading, to: availableSection)
        let note = Self.label(L("Open a tool to learn more, then enable it to install its source."), size: 12, color: .secondaryLabelColor)
        note.maximumNumberOfLines = 2
        addFullWidth(note, to: availableSection)
        configureList(availableList)
        addFullWidth(availableList, to: availableSection)
        addFullWidth(availableSection, to: overviewStack)
    }

    private func buildDetail() {
        detail.addSubview(backButton)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 28),
            backButton.topAnchor.constraint(equalTo: detail.topAnchor, constant: 16)
        ])
        configureScroll(settingsScroll, document: settingsDocument, stack: detailStack, in: detail,
                        top: backButton.bottomAnchor, topInset: 12)
        detailTitle.font = .systemFont(ofSize: 24, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let identity = Self.column([detailTitle, versionLabel], spacing: 5)
        detailIcon.isHidden = true
        let header = NSStackView(views: [detailIcon, identity, Self.flexibleSpace(), toggle])
        header.alignment = .centerY
        header.spacing = 18
        header.setCustomSpacing(12, after: detailIcon)
        addFullWidth(header, to: detailStack)
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 3
        addFullWidth(summary, to: detailStack)
        let actions = NSStackView(views: [editButton, reloadButton, updateButton])
        actions.spacing = 8
        detailStack.addArrangedSubview(actions)
        updateVersionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        updateVersionLabel.textColor = .controlAccentColor
        addFullWidth(updateVersionLabel, to: detailStack)
        sourceHelp.font = .systemFont(ofSize: 12)
        sourceHelp.textColor = .secondaryLabelColor
        sourceHelp.maximumNumberOfLines = 0
        addFullWidth(sourceHelp, to: detailStack)
        for label in [status, sourceState] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 3
        }
        let state = Self.column([status, sourceState], spacing: 5)
        addFullWidth(state, to: detailStack)
        updateMessage.font = .systemFont(ofSize: 12)
        updateMessage.textColor = .secondaryLabelColor
        addFullWidth(updateMessage, to: detailStack)
        detailStack.addArrangedSubview(showBackupButton)
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        addFullWidth(errorLabel, to: detailStack)
        addFullWidth(Self.separator(), to: detailStack)
        detailStack.addArrangedSubview(Self.label(L("Settings"), size: 15, weight: .semibold))
        configureList(form)
        form.spacing = 18
        addFullWidth(form, to: detailStack)
        detailStack.setCustomSpacing(24, after: form)
        addFullWidth(Self.separator(), to: detailStack)
        let aiNote = Self.label(L("Provider and model are shared across your tools."), size: 12, color: .secondaryLabelColor)
        aiNote.maximumNumberOfLines = 2
        aiRow.addArrangedSubview(aiNote)
        aiRow.spacing = 10; aiRow.alignment = .centerY
        addFullWidth(aiRow, to: detailStack)
        permissionStatus.font = .systemFont(ofSize: 12)
        permissionStatus.maximumNumberOfLines = 2
        permissionRow.addArrangedSubview(accessibilityButton); permissionRow.addArrangedSubview(permissionStatus)
        permissionRow.spacing = 10; permissionRow.alignment = .centerY
        addFullWidth(permissionRow, to: detailStack)
    }

    private func configureScroll(_ scroll: NSScrollView, document: NSView, stack: NSStackView,
                                 in parent: NSView, top: NSLayoutYAxisAnchor? = nil, topInset: CGFloat = 0) {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        configureList(stack)
        stack.spacing = 14
        parent.addSubview(scroll)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top ?? parent.topAnchor, constant: topInset),
            scroll.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: top == nil ? 24 : 8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
    }

    private func configureList(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func addFullWidth(_ child: NSView, to stack: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func sectionHeading(_ title: String, count: NSTextField, button: NSButton? = nil) -> NSStackView {
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        let row = NSStackView(views: [Self.label(title, size: 15, weight: .semibold), Self.flexibleSpace(), count])
        row.alignment = .centerY
        row.spacing = 12
        if let button { row.addArrangedSubview(button) }
        return row
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDisplay()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        permissionTimer?.invalidate(); permissionTimer = nil
    }

    private var busy: Bool { operationTask != nil }
    var hasPendingOperations: Bool { busy || !operations.isEmpty }
    var hasUnsavedPromptChanges: Bool { promptDrafts.values.contains { $0.isDirty } || !pendingValues.isEmpty }

    func selectTool(_ id: String) {
        requestedSelectionID = id
        loadViewIfNeeded()
        view.window?.makeFirstResponder(nil)
        refreshDisplay()
    }

    func showOverview() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(nil)
        requestedSelectionID = nil
        selectedID = nil
        refreshDisplay()
    }

    func refreshDisplay() {
        guard isViewLoaded else { return }
        let tools = manager.tools
        for tool in tools {
            if let failure = operationErrors[tool.id], tool.isEnabled, tool.isRunning,
               tool.error == nil, tool.reloadCount > failure.reloadCount {
                operationErrors.removeValue(forKey: tool.id)
            }
        }
        if let requestedSelectionID, tools.contains(where: { $0.id == requestedSelectionID }) {
            let changed = selectedID != requestedSelectionID
            selectedID = requestedSelectionID
            self.requestedSelectionID = nil
            if changed { settingsDocument.scroll(.zero) }
            if manager.sourceURL(for: requestedSelectionID) != nil {
                enqueue(title: L("Loading settings…"), toolID: requestedSelectionID, operation: { [manager] in
                    try await manager.prepareSettings(for: requestedSelectionID)
                })
            }
        }
        if let selectedID, !tools.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        overview.isHidden = selectedID != nil
        detail.isHidden = selectedID == nil
        if selectedID == nil { refreshOverview(tools) }
        let item = tools.first { $0.id == selectedID }
        detailIcon.show(item?.artwork)
        detailIcon.isHidden = item?.artwork == nil
        detailTitle.stringValue = item?.displayName ?? L("Extension")
        versionLabel.stringValue = item.map { ($0.version.isEmpty ? $0.id : L("Version %@", $0.version)) + ($0.runtime == "native" ? " · " + L("Native Swift") : $0.runtime == "javascript" ? " · JavaScript" : "") } ?? ""
        updateVersionLabel.stringValue = item?.availableVersion.map { L("Version %@ available", $0) } ?? ""
        updateVersionLabel.isHidden = updateVersionLabel.stringValue.isEmpty
        updateButton.isHidden = updateVersionLabel.isHidden
        let completed = selectedID.flatMap { completedUpdates[$0] }
        updateMessage.stringValue = completed?.message ?? ""
        updateMessage.isHidden = completed == nil
        showBackupButton.isHidden = completed == nil
        summary.stringValue = item?.summary ?? ""
        sourceHelp.isHidden = item?.sourceURL == nil
        sourceHelp.stringValue = item?.runtime == "native"
            ? L("Edit Source opens the installed folder. Saving native Swift source rebuilds and replaces only this tool’s worker. MacHelper stays open; a failed build keeps the last working version. Xcode Command Line Tools are required.")
            : L("Edit Source opens this tool’s installed folder. Saving code, prompts, or settings reloads its worker automatically while enabled. If disabled, your changes take effect when you enable it.")
        toggle.title = item?.sourceURL == nil ? L("Install & Enable") : L("Enabled")
        toggle.state = item?.isEnabled == true ? .on : .off
        status.stringValue = (workingToolID == nil || workingToolID == selectedID ? workingTitle : nil)
            ?? item.map { L($0.status) } ?? ""
        if let item {
            sourceState.stringValue = item.sourceURL == nil ? L("Complete editable source will be downloaded when you enable this tool.")
                : (item.isLocallyModified ? L("Source edited locally") : L("Local source ready")) + "  ·  " + (item.reloadCount == 1 ? L("%ld reload", item.reloadCount) : L("%ld reloads", item.reloadCount))
            sourceState.toolTip = item.sourceURL?.path
        }
        let message = selectedID.flatMap { operationErrors[$0]?.message } ?? globalError ?? item?.error
        errorLabel.stringValue = message.map { L("Extension error: %@", L($0)) } ?? ""
        errorLabel.isHidden = message == nil
        status.textColor = message == nil ? .secondaryLabelColor : .systemRed
        if selectedID != nil { refreshForm(for: selectedID) }
        let permissions = selectedID.map { manager.permissions(for: $0) } ?? []
        permissionRow.isHidden = !permissions.contains("selection.read")
        aiRow.isHidden = !permissions.contains("ai.transform")
        refreshPermission()
        updateEnabledControls()
        applyAppLanguageDirection(to: view)
    }

    private func refreshOverview(_ tools: [SourceToolInfo]) {
        let installed = tools.filter { $0.sourceURL != nil }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let available = tools.filter { $0.sourceURL == nil }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        availableSection.isHidden = available.isEmpty
        installedCount.stringValue = installed.count == 1 ? L("%ld tool", installed.count) : L("%ld tools", installed.count)
        availableCount.stringValue = available.count == 1 ? L("%ld tool", available.count) : L("%ld tools", available.count)
        overviewSelection.reconcile(items: batchItems)
        overviewMessage.stringValue = globalError.map { L("Extension error: %@", L($0)) } ?? workingTitle ?? batchSummary ?? ""
        overviewMessage.textColor = globalError == nil ? .secondaryLabelColor : .systemRed
        overviewMessage.isHidden = overviewMessage.stringValue.isEmpty
        let signature = tools.map { tool in
            [tool.id, tool.displayName, tool.summary, tool.version, tool.runtime, tool.availableVersion ?? "", String(tool.sourceURL != nil),
             String(tool.isEnabled), String(tool.isRunning), String(tool.isLocallyModified),
             tool.artwork?.digest ?? "", tool.error ?? "", tool.status,
             operationErrors[tool.id]?.message ?? ""].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        guard signature != overviewSignature || cards.isEmpty else { refreshBatchControls(); return }
        overviewSignature = signature
        let focusID = (view.window?.firstResponder as? SourceToolCard)?.toolID
        let checkboxFocusID = selectionCheckboxes.first { $0.value === view.window?.firstResponder }?.key
        let updateFocusID = updateButtons.first { $0.value === view.window?.firstResponder }?.key
        cards.removeAll()
        selectionCheckboxes.removeAll()
        updateButtons.removeAll()
        for (list, items, emptyTitle, emptyText) in [
            (installedList, installed, "No tools installed yet", "Browse the marketplace or install a source folder to add your first tool."),
            (availableList, available, "No additional catalog tools", "Add another catalog or browse the marketplace to discover more tools.")
        ] {
            list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
            if items.isEmpty {
                addFullWidth(SourceToolEmptyView(title: L(emptyTitle), message: L(emptyText)), to: list)
            } else {
                for tool in items {
                    let card = SourceToolCard(tool: tool, error: operationErrors[tool.id]?.message,
                                              target: self, action: #selector(openTool(_:)))
                    cards[tool.id] = card
                    if tool.sourceURL != nil {
                        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectInstalled(_:)))
                        checkbox.setAccessibilityLabel(L("Select %@", tool.displayName))
                        checkbox.toolTip = L("Select this extension for list actions.")
                        checkbox.identifier = NSUserInterfaceItemIdentifier("select-extension-" + tool.id)
                        checkbox.widthAnchor.constraint(equalToConstant: 18).isActive = true
                        selectionCheckboxes[tool.id] = checkbox
                        // The card and its update action are separate keyboard and accessibility controls.
                        let cardContainer = NSView()
                        card.translatesAutoresizingMaskIntoConstraints = false
                        cardContainer.addSubview(card)
                        let row = NSStackView(views: [checkbox, cardContainer])
                        row.spacing = 10; row.alignment = .centerY
                        if let version = tool.availableVersion {
                            let button = NSButton(title: "", target: self, action: #selector(updateListedTool(_:)))
                            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
                                .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
                            button.imagePosition = .imageOnly
                            button.isBordered = false
                            button.contentTintColor = .controlAccentColor
                            button.identifier = NSUserInterfaceItemIdentifier("update-extension-" + tool.id)
                            button.setAccessibilityLabel(L("Update %@…", tool.displayName))
                            let availability = L("Version %@ available", version)
                            button.setAccessibilityHelp(availability)
                            button.toolTip = availability
                            button.translatesAutoresizingMaskIntoConstraints = false
                            cardContainer.addSubview(button)
                            NSLayoutConstraint.activate([
                                button.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 8),
                                button.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -10),
                                button.widthAnchor.constraint(equalToConstant: 26),
                                button.heightAnchor.constraint(equalToConstant: 26)
                            ])
                            updateButtons[tool.id] = button
                        }
                        NSLayoutConstraint.activate([
                            card.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
                            card.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
                            card.topAnchor.constraint(equalTo: cardContainer.topAnchor),
                            card.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
                            cardContainer.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -28)
                        ])
                        addFullWidth(row, to: list)
                    } else { addFullWidth(card, to: list) }
                }
            }
        }
        if let focusID, let card = cards[focusID] { view.window?.makeFirstResponder(card) }
        if let checkboxFocusID, let checkbox = selectionCheckboxes[checkboxFocusID] { view.window?.makeFirstResponder(checkbox) }
        if let updateFocusID, let control = updateButtons[updateFocusID] ?? cards[updateFocusID] {
            view.window?.makeFirstResponder(control)
        }
        refreshBatchControls()
    }

    private var batchItems: [ExtensionBatchItem] {
        manager.tools.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }.map {
            ExtensionBatchItem(id: $0.id, installed: $0.sourceURL != nil, enabled: $0.isEnabled)
        }
    }

    private func refreshBatchControls() {
        let items = batchItems
        overviewSelection.reconcile(items: items)
        let count = overviewSelection.selectedIDs.count
        let installed = items.filter(\.installed).count
        selectionCount.stringValue = L("%ld selected", count)
        selectAllButton.state = count == 0 ? .off : count == installed ? .on : .mixed
        selectAllButton.isEnabled = !busy && installed > 0
        for (id, checkbox) in selectionCheckboxes {
            let selected = overviewSelection.selectedIDs.contains(id)
            checkbox.state = selected ? .on : .off
            checkbox.isEnabled = !busy
            cards[id]?.setBatchSelected(selected)
        }
        batchReloadButton.isEnabled = !busy && !overviewSelection.targets(for: .reload, items: items).isEmpty
        batchEditButton.isEnabled = !busy && !overviewSelection.targets(for: .editSource, items: items).isEmpty
        batchEnableButton.isEnabled = !busy && !overviewSelection.targets(for: .enable, items: items).isEmpty
        batchDisableButton.isEnabled = !busy && !overviewSelection.targets(for: .disable, items: items).isEmpty
        checkForUpdatesButton.isEnabled = !busy && installed > 0
        updateButtons.values.forEach { $0.isEnabled = !busy }
    }

    private func refreshPermission() {
        let granted = manager.accessibilityGranted
        permissionStatus.stringValue = granted ? L("Accessibility enabled") : L("Allow selection access in other apps.")
        permissionStatus.textColor = granted ? .secondaryLabelColor : .systemOrange
    }

    private func refreshForm(for id: String?) {
        let schema = id.flatMap { manager.settingsSchema(for: $0) }
        let emptyState = id.map { id in
            manager.sourceURL(for: id) == nil ? "available" : busy ? "loading" : operationErrors[id] == nil ? "ready" : "failed"
        } ?? "unselected"
        let signature = schema?.fields.map { field in
            [field.key, id.map { manager.localizedText(field.label, for: $0) } ?? field.label,
             field.type, field.path ?? "", String(describing: field.defaultValue),
             field.options.map { option in option.value + ":" + (id.map { manager.localizedText(option.label, for: $0) } ?? option.label) }
                .joined(separator: "|")].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}") ?? "none:" + emptyState
        if id != formToolID || signature != formSignature {
            if isEditingFormText, id == formToolID { pendingFormRebuild = true; return }
            rebuildForm(for: id, schema: schema, signature: signature)
        }
        guard let id, let schema else { return }
        let values = manager.settings(for: id)
        for field in schema.fields {
            if field.type == "prompt" {
                refreshPrompt(field, toolID: id)
                continue
            }
            guard let control = controls[field.key] else { continue }
            let value = pendingValues[SettingKey(toolID: id, key: field.key)] ?? values[field.key] ?? field.defaultValue
            if let text = control as? NSTextField {
                if text.currentEditor() == nil { text.stringValue = Self.string(value) }
            } else if let popup = control as? NSPopUpButton {
                if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == Self.string(value) }) {
                    popup.select(item)
                }
            } else if let checkbox = control as? NSButton {
                checkbox.state = (value as? Bool) == true ? .on : .off
            }
        }
    }

    private func rebuildForm(for id: String?, schema: ScriptSettingsSchema?, signature: String) {
        form.arrangedSubviews.forEach { form.removeArrangedSubview($0); $0.removeFromSuperview() }
        controls.removeAll(); bindings.removeAll(); promptEditors.removeAll()
        formToolID = id; formSignature = signature; pendingFormRebuild = false
        guard let id, let schema else {
            let message: String
            if let id {
                if manager.sourceURL(for: id) == nil { message = L("Install and enable this tool to download its source and settings.") }
                else if busy { message = L("Loading this tool’s settings…") }
                else if operationErrors[id] != nil { message = L("The tool’s settings could not be loaded. Review the error above or repair its source.") }
                else { message = L("This tool has no additional settings.") }
            }
            else { message = L("Choose a tool to view its settings.") }
            let note = NSTextField(wrappingLabelWithString: L(message))
            note.textColor = .secondaryLabelColor
            form.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
            return
        }
        if schema.fields.isEmpty {
            let note = NSTextField(labelWithString: L("This tool has no additional settings."))
            note.textColor = .secondaryLabelColor
            form.addArrangedSubview(note)
        }
        for field in schema.fields {
            if field.type == "prompt", let path = field.path {
                let key = SettingKey(toolID: id, key: field.key)
                let editor = SourcePromptEditorView(label: manager.localizedText(field.label, for: id), path: path)
                editor.onChange = { [weak self] text in
                    guard let self, var draft = self.promptDrafts[key] else { return }
                    draft.text = text; self.promptDrafts[key] = draft
                    self.refreshPrompt(field, toolID: id)
                }
                editor.onSave = { [weak self] in self?.savePrompt(key) }
                editor.onRevert = { [weak self] in self?.revertPrompt(key) }
                editor.onEndEditing = { [weak self] in
                    guard let self, self.pendingFormRebuild else { return }
                    self.refreshDisplay()
                }
                form.addArrangedSubview(editor)
                editor.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
                promptEditors[field.key] = editor
                continue
            }
            let control: NSControl
            if field.type == "boolean" {
                let checkbox = NSButton(checkboxWithTitle: manager.localizedText(field.label, for: id), target: self, action: #selector(settingChanged(_:)))
                control = checkbox
                form.addArrangedSubview(checkbox)
            } else {
                let label = NSTextField(labelWithString: manager.localizedText(field.label, for: id))
                label.font = .systemFont(ofSize: 12, weight: .medium)
                if field.type == "select" {
                    let popup = NSPopUpButton()
                    for option in field.options {
                        popup.addItem(withTitle: manager.localizedText(option.label, for: id))
                        popup.lastItem?.representedObject = option.value
                    }
                    popup.target = self; popup.action = #selector(settingChanged(_:))
                    control = popup
                } else {
                    let text = NSTextField()
                    text.delegate = self
                    control = text
                }
                let row = NSStackView(views: [label, control])
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = 5
                form.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
                control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
            control.setAccessibilityLabel(manager.localizedText(field.label, for: id))
            controls[field.key] = control
            bindings[ObjectIdentifier(control)] = FormBinding(toolID: id, key: field.key)
        }
        settingsDocument.scroll(.zero)
    }

    private var isEditingFormText: Bool {
        controls.values.contains { ($0 as? NSTextField)?.currentEditor() != nil } ||
            promptEditors.values.contains { $0.isEditing }
    }

    private func updateEnabledControls() {
        let item = manager.tools.first { $0.id == selectedID }
        toggle.isEnabled = !busy && item != nil
        installButton.isEnabled = !busy
        catalogButton.isEnabled = !busy
        editButton.isEnabled = !busy && selectedID.flatMap { manager.sourceURL(for: $0) } != nil
        reloadButton.isEnabled = editButton.isEnabled && item?.isEnabled == true
        updateButton.isEnabled = !busy && item?.availableVersion != nil
        showBackupButton.isEnabled = !busy
        refreshBatchControls()
        Array(controls.values).forEach { $0.isEnabled = !busy }
        if let id = formToolID, let schema = manager.settingsSchema(for: id) {
            for field in schema.fields where field.type == "prompt" { refreshPrompt(field, toolID: id) }
        }
    }

    private func enqueue(title: String, toolID: String? = nil, operation: @escaping @MainActor () async throws -> Void,
                         success: (@MainActor () -> Void)? = nil) {
        batchSummary = nil
        operations.append(QueuedOperation(title: title, toolID: toolID, operation: operation, success: success))
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            while !self.operations.isEmpty {
                let next = self.operations.removeFirst()
                let startingReloadCount = next.toolID.flatMap { id in
                    self.manager.tools.first(where: { $0.id == id })?.reloadCount
                } ?? 0
                self.workingTitle = next.title
                self.workingToolID = next.toolID
                self.globalError = nil
                if let id = next.toolID { self.operationErrors.removeValue(forKey: id) }
                self.refreshDisplay()
                do {
                    try await next.operation()
                    next.success?()
                } catch is CancellationError {
                    // A cancelled approval leaves installed source and grants intact.
                } catch {
                    if let id = next.toolID {
                        self.operationErrors[id] = OperationFailure(message: error.localizedDescription, reloadCount: startingReloadCount)
                    }
                    else { self.globalError = error.localizedDescription }
                }
            }
            self.workingTitle = nil
            self.workingToolID = nil
            self.operationTask = nil
            self.refreshDisplay()
        }
        updateEnabledControls()
    }

    @objc private func backToOverview() { showOverview() }

    @objc private func openTool(_ sender: SourceToolCard) { selectTool(sender.toolID) }

    @objc private func openMarketplace() { onOpenMarketplace?() }

    @objc private func selectInstalled(_ sender: NSButton) {
        guard !busy, let id = selectionCheckboxes.first(where: { $0.value === sender })?.key else { return }
        overviewSelection.setSelected(sender.state == .on, id: id, items: batchItems)
        batchSummary = nil
        refreshDisplay()
    }

    @objc private func selectAllInstalled() {
        guard !busy else { return }
        let items = batchItems
        let allSelected = !overviewSelection.selectedIDs.isEmpty && overviewSelection.selectedIDs.count == items.filter(\.installed).count
        overviewSelection.selectAll(!allSelected, items: items)
        batchSummary = nil
        refreshDisplay()
    }

    @objc private func reloadSelected() { applySelected(.reload) }
    @objc private func enableSelected() { applySelected(.enable) }
    @objc private func disableSelected() { applySelected(.disable) }
    @objc private func editSelectedSources() {
        guard !busy else { return }
        openSources(for: overviewSelection.targets(for: .editSource, items: batchItems))
    }

    private func lifecycleAction(_ action: ExtensionBatchAction, for id: String) async throws {
        switch action {
        case .reload: try await manager.reload(id)
        case .enable: try await manager.setEnabled(true, for: id)
        case .disable: try await manager.setEnabled(false, for: id)
        case .editSource: break
        }
    }

    private func applySelected(_ action: ExtensionBatchAction) {
        guard !busy else { return }
        let ids = overviewSelection.targets(for: action, items: batchItems)
        guard !ids.isEmpty else { return }
        let skipped = overviewSelection.selectedIDs.count - ids.count
        let batchTitle: String
        let progressFormat: String
        switch action {
        case .reload: batchTitle = L("Reloading selected extensions…"); progressFormat = "Reloading %@ (%ld/%ld)…"
        case .enable: batchTitle = L("Enabling selected extensions…"); progressFormat = "Enabling %@ (%ld/%ld)…"
        case .disable: batchTitle = L("Disabling selected extensions…"); progressFormat = "Disabling %@ (%ld/%ld)…"
        case .editSource: return
        }
        enqueue(title: batchTitle, operation: { [weak self] in
            guard let self else { return }
            var succeeded = 0, failed = 0, cancelled = 0
            for (index, id) in ids.enumerated() {
                let item = self.manager.tools.first { $0.id == id }
                let reloadCount = item?.reloadCount ?? 0
                self.workingTitle = L(progressFormat, item?.displayName ?? id, index + 1, ids.count)
                self.workingToolID = id
                self.operationErrors.removeValue(forKey: id)
                self.refreshDisplay()
                do {
                    try await self.lifecycleAction(action, for: id)
                    succeeded += 1
                } catch is CancellationError { cancelled += 1 }
                catch {
                    failed += 1
                    self.operationErrors[id] = OperationFailure(message: error.localizedDescription, reloadCount: reloadCount)
                }
            }
            var summary: String
            switch action {
            case .reload: summary = succeeded == 1 ? L("Reloaded %ld extension.", succeeded) : L("Reloaded %ld extensions.", succeeded)
            case .enable: summary = succeeded == 1 ? L("Enabled %ld extension.", succeeded) : L("Enabled %ld extensions.", succeeded)
            case .disable: summary = succeeded == 1 ? L("Disabled %ld extension.", succeeded) : L("Disabled %ld extensions.", succeeded)
            case .editSource: return
            }
            if skipped > 0 {
                switch action {
                case .reload: summary += " " + (skipped == 1 ? L("Skipped %ld disabled extension.", skipped) : L("Skipped %ld disabled extensions.", skipped))
                case .enable: summary += " " + L("%ld already enabled.", skipped)
                case .disable: summary += " " + L("%ld already disabled.", skipped)
                case .editSource: break
                }
            }
            if failed > 0 { summary += " " + L("%ld failed; open the marked tool for details.", failed) }
            if cancelled > 0 { summary += " " + L("%ld cancelled.", cancelled) }
            self.batchSummary = summary
        })
    }

    @objc private func toggleEnabled() {
        guard let id = selectedID else { return }
        let enabled = toggle.state == .on
        let title = enabled ? (manager.sourceURL(for: id) == nil ? L("Downloading source and enabling…") : L("Enabling…")) : L("Disabling…")
        enqueue(title: title, toolID: id, operation: { [weak self] in
            try await self?.lifecycleAction(enabled ? .enable : .disable, for: id)
        })
    }

    @objc private func reloadSource() {
        guard let id = selectedID else { return }
        view.window?.makeFirstResponder(nil)
        enqueue(title: L("Reloading source…"), toolID: id, operation: { [weak self] in try await self?.lifecycleAction(.reload, for: id) })
    }

    @objc private func checkForUpdates() {
        guard !busy else { return }
        enqueue(title: L("Checking for extension updates…"), operation: { [manager] in
            try await manager.checkForUpdates()
        }, success: { [weak self] in
            guard let self else { return }
            self.batchSummary = self.manager.tools.contains { $0.availableVersion != nil }
                ? L("Extension updates are available.") : L("No extension updates found.")
        })
    }

    @objc private func updateListedTool(_ sender: NSButton) {
        guard let id = updateButtons.first(where: { $0.value === sender })?.key else { return }
        updateExtension(id)
    }

    @objc private func updateSelectedTool() {
        guard let selectedID else { return }
        updateExtension(selectedID)
    }

    private func updateExtension(_ id: String) {
        guard !busy, let item = manager.tools.first(where: { $0.id == id }), item.availableVersion != nil else { return }
        view.window?.makeFirstResponder(nil)
        guard !busy else { return }
        let hasPromptDraft = promptDrafts.contains { $0.key.toolID == id && $0.value.isDirty }
        if hasPromptDraft || pendingValues.keys.contains(where: { $0.toolID == id }) {
            let message = hasPromptDraft ? L("Save or revert this extension’s prompt changes before updating.") : L("Finish your changes first")
            globalError = message
            operationErrors[id] = OperationFailure(message: message, reloadCount: item.reloadCount)
            refreshDisplay()
            return
        }
        enqueue(title: L("Reviewing update…"), toolID: id, operation: { [weak self] in
            guard let self else { return }
            do {
                let preview = try await self.manager.previewUpdate(id)
                guard self.reviewUpdate(preview) else { throw CancellationError() }
                self.workingTitle = L("Updating %@…", item.displayName)
                self.refreshDisplay()
                let backup = try await self.manager.installUpdate(preview)
                let message = L("Updated %@ to %@. The previous source is backed up.", item.displayName, preview.manifest.version)
                self.completedUpdates[id] = (message, backup)
                self.batchSummary = message
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.globalError = error.localizedDescription
                throw error
            }
        })
    }

    private func reviewUpdate(_ preview: SourceExtensionUpdatePreview) -> Bool {
        if let sourceUpdateReviewer { return sourceUpdateReviewer(preview) }
        let alert = NSAlert()
        alert.messageText = L("Update %@?", preview.manifest.displayName)
        var address = URLComponents(url: preview.catalogURL, resolvingAgainstBaseURL: false)
        address?.query = nil
        let source = String((address?.string ?? preview.catalogURL.path).prefix(360))
        let leftToRight: (String) -> String = {
            AppLocalization.shared.isRightToLeft ? "\u{2066}\($0)\u{2069}" : $0
        }
        var sections = [
            L("Version %@ → %@", leftToRight(preview.currentVersion), leftToRight(preview.manifest.version))
                + "\n" + L("Catalog %@", leftToRight(source)),
            L("Requested permissions") + "\n" + sourcePermissionReviewText(preview.manifest.permissions),
            L("MacHelper will replace the installed source and keep a backup of the previous source folder. Your settings and enabled state are retained.")
        ]
        if preview.isLocallyModified {
            sections.append(L("This extension has local edits. MacHelper will save them in the backup."))
        }
        alert.informativeText = sections.joined(separator: "\n\n")
        alert.addButton(withTitle: L("Update"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func showUpdateBackup() {
        guard let selectedID, let backup = completedUpdates[selectedID]?.backup else { return }
        NSWorkspace.shared.open(backup)
    }

    @objc private func settingChanged(_ control: NSControl) {
        guard let binding = bindings[ObjectIdentifier(control)] else { return }
        let value: Any
        if let popup = control as? NSPopUpButton {
            guard let selected = popup.selectedItem?.representedObject as? String else { return }
            value = selected
        } else if let checkbox = control as? NSButton { value = checkbox.state == .on }
        else { return }
        saveSetting(binding, value: value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let text = notification.object as? NSTextField,
              let binding = bindings[ObjectIdentifier(text)] else { return }
        saveSetting(binding, value: text.stringValue)
        if pendingFormRebuild { refreshDisplay() }
    }

    private func saveSetting(_ binding: FormBinding, value: Any) {
        let key = SettingKey(toolID: binding.toolID, key: binding.key)
        pendingValues[key] = value
        enqueue(title: L("Saving settings…"), toolID: binding.toolID, operation: { [manager] in
            try await manager.updateSetting(binding.key, value: value, for: binding.toolID)
        }, success: { [weak self] in
            guard let self, let pending = self.pendingValues[key], Self.equal(pending, value) else { return }
            self.pendingValues.removeValue(forKey: key)
        })
    }

    private func refreshPrompt(_ field: ScriptSettingField, toolID id: String) {
        guard let editor = promptEditors[field.key], let path = field.path else { return }
        let key = SettingKey(toolID: id, key: field.key)
        do {
            let current = try manager.promptValue(field.key, for: id)
            var draft = promptDrafts[key] ?? PromptDraft(path: path, baseline: current, text: current)
            // Saved generations may refresh a clean editor. Unsaved bytes stay
            // intact through watcher reloads, navigation, and failed operations.
            if !draft.isDirty { draft = PromptDraft(path: path, baseline: current, text: current) }
            promptDrafts[key] = draft
            let conflict = draft.path != path || !Self.sameBytes(draft.baseline, current)
            editor.display(text: draft.text, busy: busy, dirty: draft.isDirty, conflict: conflict)
        } catch {
            editor.display(text: promptDrafts[key]?.text ?? "", busy: true, dirty: false, conflict: false,
                           problem: L("The validated prompt could not be loaded. Repair the extension source and reload."))
        }
    }

    private func savePrompt(_ key: SettingKey) {
        guard let draft = promptDrafts[key], draft.isDirty else { return }
        let value = draft.text, expected = draft.baseline
        enqueue(title: L("Saving prompt…"), toolID: key.toolID, operation: { [manager] in
            try await manager.updatePrompt(key.key, value: value, expectedValue: expected, for: key.toolID)
        }, success: { [weak self] in
            guard let self, var latest = self.promptDrafts[key] else { return }
            latest.baseline = value
            self.promptDrafts[key] = latest
        })
    }

    private func revertPrompt(_ key: SettingKey) {
        enqueue(title: L("Reading saved prompt…"), toolID: key.toolID, operation: { [manager] in
            if manager.tools.first(where: { $0.id == key.toolID })?.isEnabled == true {
                try await manager.reload(key.toolID)
            } else { try await manager.prepareSettings(for: key.toolID) }
        }, success: { [weak self] in
            guard let self, let schema = self.manager.settingsSchema(for: key.toolID),
                  let path = try? schema.promptPath(for: key.key),
                  let current = try? self.manager.promptValue(key.key, for: key.toolID) else { return }
            self.promptDrafts[key] = PromptDraft(path: path, baseline: current, text: current)
        })
    }

    private static func sameBytes(_ first: String, _ second: String) -> Bool { Data(first.utf8) == Data(second.utf8) }

    @objc private func installSource() {
        let panel = NSOpenPanel()
        panel.message = L("Choose a JavaScript or native Swift extension source folder containing extension.json. It is installed disabled, with its source available to edit.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        if ["machextension", "bundle"].contains(source.pathExtension.lowercased()) {
            globalError = L("This compiled bundle uses the legacy native API. Migrate its source to the native worker SDK in the AI Extension Guide, then install the new source folder here.")
            refreshDisplay()
            return
        }
        let previous = Set(manager.tools.map(\.id))
        enqueue(title: L("Installing source…"), operation: { [manager] in try await manager.importSource(from: source) }, success: { [weak self] in
            guard let self else { return }
            if let item = self.manager.tools.first(where: { !previous.contains($0.id) }) { self.selectTool(item.id) }
        })
    }

    @objc private func addCatalog() {
        let alert = NSAlert()
        alert.messageText = L("Add a tool catalog")
        alert.informativeText = L("Enter the catalog JSON URL. Tools are downloaded when you enable them.")
        alert.addButton(withTitle: L("Add Catalog"))
        alert.addButton(withTitle: L("Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.placeholderString = "https://example.com/catalog.json"
        input.setAccessibilityLabel(L("Catalog URL"))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let string = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["https", "http", "file"].contains(scheme), scheme == "file" || url.host != nil else {
            globalError = L("Enter a complete catalog URL.")
            refreshDisplay()
            return
        }
        enqueue(title: L("Loading catalog…"), operation: { [manager] in try await manager.addCatalog(from: url) })
    }

    @objc private func editSource() {
        guard !busy, let id = selectedID else { return }
        openSources(for: [id])
    }

    private func openSources(for ids: [String]) {
        let sources = ids.compactMap { id -> (String, URL)? in
            guard let url = manager.sourceURL(for: id) else { return nil }
            return (id, url)
        }
        guard !sources.isEmpty else { return }
        let counts = Dictionary(uniqueKeysWithValues: manager.tools.map { ($0.id, $0.reloadCount) })
        sources.forEach { operationErrors.removeValue(forKey: $0.0) }
        globalError = nil; batchSummary = nil
        refreshDisplay()
        let completion: @MainActor (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            if let error {
                for (id, _) in sources {
                    self.operationErrors[id] = OperationFailure(message: L("Could not open source: %@", error.localizedDescription),
                                                                reloadCount: counts[id] ?? 0)
                }
            } else {
                self.batchSummary = sources.count == 1 ? L("Opened source for %ld extension.", sources.count) : L("Opened source for %ld extensions.", sources.count)
            }
            self.refreshDisplay()
        }
        if let sourceFolderOpener {
            sourceFolderOpener(sources.map(\.1), completion)
            return
        }
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCodeInsiders") {
            workspace.open(sources.map(\.1), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        } else {
            for (id, source) in sources {
                if !workspace.open(source) {
                    operationErrors[id] = OperationFailure(message: L("The source folder could not be opened."), reloadCount: counts[id] ?? 0)
                }
            }
            refreshDisplay()
        }
    }

    @objc private func openExtensionGuide() {
        let bundledGuide = Bundle.main.url(forResource: "AI_EXTENSION_GUIDE", withExtension: "md")
        do {
            let url = try bundledGuide ?? MarketplaceConfiguration.websiteURL().appendingPathComponent("AI_EXTENSION_GUIDE.md")
            guard NSWorkspace.shared.open(url) else {
                globalError = L("The AI Extension Guide could not be opened. Check your default app for Markdown files or visit the marketplace.")
                refreshDisplay()
                return
            }
        } catch {
            globalError = L("The AI Extension Guide could not be opened: %@", error.localizedDescription)
            refreshDisplay()
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return value as? String ?? String(describing: value)
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                              color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private static func flexibleSpace() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }

    private static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private struct FormBinding { let toolID: String; let key: String }
    private struct SettingKey: Hashable { let toolID: String; let key: String }
    private struct PromptDraft {
        let path: String
        var baseline: String
        var text: String
        var isDirty: Bool { Data(baseline.utf8) != Data(text.utf8) }
    }
    private struct OperationFailure { let message: String; let reloadCount: Int }
    private struct QueuedOperation {
        let title: String
        let toolID: String?
        let operation: @MainActor () async throws -> Void
        let success: (@MainActor () -> Void)?
    }
}

/// A plain-text source editor with explicit persistence. NSTextView changes only
/// update the caller's draft; neither focus changes nor reload notifications save.
@MainActor
private final class SourcePromptEditorView: NSView, NSTextViewDelegate {
    var onChange: ((String) -> Void)?
    var onSave: (() -> Void)?
    var onRevert: (() -> Void)?
    var onEndEditing: (() -> Void)?
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 164))
    private let saveButton = NSButton(title: L("Save Prompt"), target: nil, action: nil)
    private let revertButton = NSButton(title: L("Revert"), target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    var isEditing: Bool { window?.firstResponder === textView }

    init(label: String, path: String) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let source = NSTextField(wrappingLabelWithString: path)
        source.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        source.textColor = .secondaryLabelColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 9, height: 9)
        textView.minSize = NSSize(width: 0, height: 164)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.delegate = self
        textView.setAccessibilityLabel(label)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        saveButton.target = self; saveButton.action = #selector(save)
        revertButton.target = self; revertButton.action = #selector(revert)
        let actions = NSStackView(views: [saveButton, revertButton])
        actions.spacing = 8
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, source, scroll, message, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 164),
            source.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(text: String, busy: Bool, dirty: Bool, conflict: Bool, problem: String? = nil) {
        if Data(textView.string.utf8) != Data(text.utf8) { textView.string = text }
        textView.isEditable = !busy
        saveButton.isEnabled = !busy && dirty && !conflict
        revertButton.isEnabled = !busy && (dirty || conflict)
        message.stringValue = problem ?? (conflict
            ? L("The source changed outside this editor. Your draft is retained; Revert loads the current saved prompt.")
            : dirty ? L("Unsaved changes. Save Prompt writes this source file and reloads the enabled tool.")
            : L("The source prompt is sent exactly as written. Changes are saved only with Save Prompt."))
        message.textColor = problem != nil || conflict ? .systemOrange : .secondaryLabelColor
    }
    func textDidChange(_ notification: Notification) { onChange?(textView.string) }
    func textDidEndEditing(_ notification: Notification) { onEndEditing?() }
    @objc private func save() { onSave?() }
    @objc private func revert() { onRevert?() }
}

private final class SourceSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private enum SourceToolSurface {
    static func background(emphasized: Bool = false) -> NSColor {
        let base = NSColor.controlBackgroundColor
        let fill = emphasized ? base.blended(withFraction: 0.14, of: .controlAccentColor) ?? base : base
        return fill.withAlphaComponent(0.84)
    }
}

@MainActor
private final class SourceToolIconView: NSView {
    private let artworkView = NSImageView()
    private var artworkSize: [NSLayoutConstraint] = []
    private var signature: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setAccessibilityElement(false)
        addSubview(artworkView)
        artworkSize = [artworkView.widthAnchor.constraint(equalToConstant: 44),
                       artworkView.heightAnchor.constraint(equalToConstant: 44)]
        NSLayoutConstraint.activate(artworkSize + [
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            artworkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            artworkView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ artwork: SourceToolArtwork?) {
        let digest = artwork?.digest ?? ""
        guard signature != digest else { return }
        signature = digest
        if let artwork, let image = NSImage(data: artwork.data) {
            artworkView.image = image
            artworkView.symbolConfiguration = nil
            artworkView.contentTintColor = nil
            layer?.backgroundColor = nil
            artworkSize.forEach { $0.constant = 44 }
        } else {
            artworkView.image = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: nil)
            artworkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
            artworkView.contentTintColor = .controlAccentColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            artworkSize.forEach { $0.constant = 24 }
        }
    }
}

/// One keyboard-accessible button per tool; labels never intercept its click.
@MainActor
private final class SourceToolCard: NSButton {
    let toolID: String
    private var batchSelected = false

    func setBatchSelected(_ selected: Bool) {
        guard batchSelected != selected else { return }
        batchSelected = selected
        needsDisplay = true
        layer?.setNeedsDisplay()
    }

    init(tool: SourceToolInfo, error: String?, target: AnyObject, action: Selector) {
        toolID = tool.id
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        identifier = NSUserInterfaceItemIdentifier("source-tool-" + tool.id)
        let installed = tool.sourceURL != nil
        let problem = error ?? tool.error
        let state = problem != nil ? L("Needs attention") : !installed ? L("Available")
            : tool.isRunning ? L("Running") : tool.isEnabled ? L("Enabled") : L("Disabled")
        let availableVersion = tool.availableVersion.map { L("Version %@ available", $0) }
        setAccessibilityLabel(tool.displayName + ", " + state + ". " + tool.summary
            + (availableVersion.map { " " + $0 } ?? ""))
        setAccessibilityHelp(L("Open tool details and settings"))
        toolTip = problem ?? tool.summary

        let icon = SourceToolIconView()
        icon.show(tool.artwork)
        let name = NSTextField(labelWithString: tool.displayName)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let description = NSTextField(wrappingLabelWithString: tool.summary)
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 2
        let badge = NSTextField(labelWithString: state)
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = problem != nil ? .systemOrange : tool.isRunning ? .systemGreen : .secondaryLabelColor
        let metadata = NSTextField(labelWithString: (tool.version.isEmpty ? "" : L("Version %@", tool.version))
            + (tool.isLocallyModified ? "  ·  " + L("Edited locally") : ""))
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        let meta = NSStackView(views: [badge, metadata])
        meta.spacing = 10
        let labels = NSStackView(views: [name, description, meta])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in [name, description] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: AppLocalization.shared.isRightToLeft ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: [icon, labels, chevron])
        row.distribution = .fill
        row.spacing = 16
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            labels.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -88)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SourceToolSurface.background(emphasized: isHighlighted || batchSelected).cgColor
            layer?.borderColor = (batchSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}

@MainActor
private final class SourceToolEmptyView: NSView {
    init(title: String, message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .medium)
        let note = NSTextField(wrappingLabelWithString: L(message))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        let stack = NSStackView(views: [heading, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SourceToolSurface.background().cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
