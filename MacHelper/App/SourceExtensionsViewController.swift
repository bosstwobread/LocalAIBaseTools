import AppKit
import MacHelper

/// Source tool controls deliberately retain their form while source/status
/// updates arrive, so a live reload cannot erase text the user is editing.
@MainActor
final class SourceExtensionsViewController: NSViewController, NSTextFieldDelegate {
    var onShowNativeExtensions: (() -> Void)? {
        didSet { if isViewLoaded { nativeButton.isHidden = onShowNativeExtensions == nil } }
    }
    var onOpenMarketplace: (() -> Void)?

    private let manager: SourceExtensionManager
    private let picker = NSPopUpButton()
    private let toggle = NSButton(checkboxWithTitle: "Enable tool", target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sourceState = NSTextField(wrappingLabelWithString: "")
    private let permissionStatus = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install Source…", target: nil, action: nil)
    private let marketplaceButton = NSButton(title: "Marketplace…", target: nil, action: nil)
    private let catalogButton = NSButton(title: "Add Catalog…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit Source", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let nativeButton = NSButton(title: "Native tools…", target: nil, action: nil)
    private let demoButton = NSButton(title: "Try Demo…", target: nil, action: nil)
    private let clipboardButton = NSButton(title: "Translate Clipboard…", target: nil, action: nil)
    private let settingsScroll = NSScrollView()
    private let settingsDocument = SourceSettingsDocumentView()
    private let form = NSStackView()
    private var permissionTimer: Timer?
    private var ids: [String] = []
    private var pickerTitles: [String] = []
    private var formToolID: String?
    private var formSignature = ""
    private var controls: [String: NSControl] = [:]
    private var bindings: [ObjectIdentifier: FormBinding] = [:]
    private var pendingFormRebuild = false
    private var operationErrors: [String: OperationFailure] = [:]
    private var globalError: String?
    private var operations: [QueuedOperation] = []
    private var operationTask: Task<Void, Never>?
    private var workingTitle: String?
    private var requestedSelectionID: String?

    init(manager: SourceExtensionManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        manager.onChange = { [weak self] in self?.refreshDisplay() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        marketplaceButton.target = self; marketplaceButton.action = #selector(openMarketplace)
        let marketplaceNote = NSTextField(labelWithString: "Find tools for your local AI connection.")
        marketplaceNote.font = .systemFont(ofSize: 12)
        marketplaceNote.textColor = .secondaryLabelColor
        let marketplaceRow = NSStackView(views: [marketplaceButton, marketplaceNote])
        marketplaceRow.spacing = 10
        marketplaceRow.alignment = .centerY
        let toolbar = NSStackView(views: [installButton, catalogButton, editButton, reloadButton, nativeButton])
        toolbar.spacing = 8
        installButton.target = self; installButton.action = #selector(installSource)
        catalogButton.target = self; catalogButton.action = #selector(addCatalog)
        editButton.target = self; editButton.action = #selector(editSource)
        reloadButton.target = self; reloadButton.action = #selector(reloadSource)
        nativeButton.target = self; nativeButton.action = #selector(showNativeExtensions)
        nativeButton.isHidden = onShowNativeExtensions == nil
        picker.target = self; picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("Source tool")
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.cell?.lineBreakMode = .byTruncatingTail
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        toggle.target = self; toggle.action = #selector(toggleEnabled)
        let selection = NSStackView(views: [picker, toggle])
        selection.spacing = 16
        selection.alignment = .centerY
        for label in [summary, status, sourceState] {
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 2
        }
        summary.textColor = .secondaryLabelColor
        sourceState.textColor = .secondaryLabelColor
        let aiButton = NSButton(title: "AI Settings…", target: self, action: #selector(openAISettings))
        let accessibilityButton = NSButton(title: "Accessibility Settings…", target: self, action: #selector(openAccessibility))
        permissionStatus.font = .systemFont(ofSize: 11)
        let connections = NSStackView(views: [aiButton, accessibilityButton, permissionStatus])
        connections.spacing = 10
        connections.alignment = .centerY
        demoButton.target = self; demoButton.action = #selector(runDemo)
        clipboardButton.target = self; clipboardButton.action = #selector(translateClipboard)
        let actions = NSStackView(views: [demoButton, clipboardButton])
        actions.spacing = 8

        settingsScroll.drawsBackground = false
        settingsScroll.hasVerticalScroller = true
        settingsScroll.autohidesScrollers = true
        settingsScroll.documentView = settingsDocument
        settingsDocument.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 16
        form.translatesAutoresizingMaskIntoConstraints = false
        settingsDocument.addSubview(form)
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        let stack = NSStackView(views: [marketplaceRow, toolbar, selection, summary, status, sourceState, connections, actions, settingsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            selection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceState.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            settingsDocument.widthAnchor.constraint(equalTo: settingsScroll.contentView.widthAnchor),
            settingsDocument.leadingAnchor.constraint(equalTo: settingsScroll.contentView.leadingAnchor),
            settingsDocument.topAnchor.constraint(equalTo: settingsScroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: settingsDocument.leadingAnchor, constant: 12),
            form.trailingAnchor.constraint(equalTo: settingsDocument.trailingAnchor, constant: -12),
            form.topAnchor.constraint(equalTo: settingsDocument.topAnchor, constant: 12),
            form.bottomAnchor.constraint(equalTo: settingsDocument.bottomAnchor, constant: -16)
        ])
        refreshDisplay()
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

    private var selectedID: String? {
        ids.indices.contains(picker.indexOfSelectedItem) ? ids[picker.indexOfSelectedItem] : nil
    }

    private var busy: Bool { operationTask != nil }

    func selectTool(_ id: String) {
        requestedSelectionID = id
        loadViewIfNeeded()
        view.window?.makeFirstResponder(nil)
        refreshDisplay()
    }

    var selectedToolID: String? { selectedID }

    func refreshDisplay() {
        guard isViewLoaded else { return }
        let previous = selectedID
        let tools = manager.tools
        // A failed manual reload may be repaired by the file watcher. Keep its
        // error while that source is still bad, and clear it only when a newer
        // working runtime has successfully replaced the failed generation.
        for tool in tools {
            if let failure = operationErrors[tool.id], tool.isEnabled, tool.isRunning,
               tool.error == nil, tool.reloadCount > failure.reloadCount {
                operationErrors.removeValue(forKey: tool.id)
            }
        }
        let nextIDs = tools.map(\.id)
        let titles = tools.map(\.displayName)
        if nextIDs != ids || titles != pickerTitles {
            ids = nextIDs; pickerTitles = titles
            picker.removeAllItems()
            picker.addItems(withTitles: titles)
            if let previous, let index = ids.firstIndex(of: previous) { picker.selectItem(at: index) }
        }
        if let requestedSelectionID, let index = ids.firstIndex(of: requestedSelectionID) {
            picker.selectItem(at: index)
            self.requestedSelectionID = nil
        }
        let item = tools.first { $0.id == selectedID }
        toggle.state = item?.isEnabled == true ? .on : .off
        summary.stringValue = item.map { "\($0.summary)  ·  \($0.version)" }
            ?? "Install an editable tool source folder or add a catalog."
        status.stringValue = workingTitle ?? item?.status ?? "No source tools installed."
        if let item {
            sourceState.stringValue = item.sourceURL == nil ? "Enable to download the complete source."
                : "\(item.isLocallyModified ? "Source edited locally" : "Local source ready")  ·  Reloads: \(item.reloadCount)"
            sourceState.toolTip = item.sourceURL?.path
        } else {
            sourceState.stringValue = ""
            sourceState.toolTip = nil
        }
        let message = selectedID.flatMap { operationErrors[$0]?.message } ?? globalError ?? item?.error
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        status.textColor = message == nil ? .secondaryLabelColor : .systemRed
        refreshForm(for: selectedID)
        refreshPermission()
        updateEnabledControls()
    }

    private func refreshPermission() {
        let granted = manager.accessibilityGranted
        permissionStatus.stringValue = granted ? "Accessibility enabled" : "Accessibility required for selection"
        permissionStatus.textColor = granted ? .secondaryLabelColor : .systemOrange
    }

    private func refreshForm(for id: String?) {
        let schema = id.flatMap { manager.settingsSchema(for: $0) }
        let signature = schema?.fields.map { field in
            [field.key, field.label, field.type, String(describing: field.defaultValue),
             field.options.map { $0.value + ":" + $0.label }.joined(separator: "|")].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}") ?? "none"
        if id != formToolID || signature != formSignature {
            if isEditingFormText, id == formToolID { pendingFormRebuild = true; return }
            rebuildForm(for: id, schema: schema, signature: signature)
        }
        guard let id, let schema else { return }
        let values = manager.settings(for: id)
        for field in schema.fields {
            guard let control = controls[field.key] else { continue }
            let value = values[field.key] ?? field.defaultValue
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
        controls.removeAll(); bindings.removeAll()
        formToolID = id; formSignature = signature; pendingFormRebuild = false
        form.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        guard let id, let schema else {
            let message: String
            if let id { message = manager.sourceURL(for: id) == nil ? "Enable this tool to download its source and settings." : "Enable this tool to open its settings." }
            else { message = "Choose a tool to view its settings." }
            let note = NSTextField(wrappingLabelWithString: message)
            note.textColor = .secondaryLabelColor
            form.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
            return
        }
        if schema.fields.isEmpty {
            let note = NSTextField(labelWithString: "This tool has no additional settings.")
            note.textColor = .secondaryLabelColor
            form.addArrangedSubview(note)
        }
        for field in schema.fields {
            let control: NSControl
            if field.type == "boolean" {
                let checkbox = NSButton(checkboxWithTitle: field.label, target: self, action: #selector(settingChanged(_:)))
                control = checkbox
                form.addArrangedSubview(checkbox)
            } else {
                let label = NSTextField(labelWithString: field.label)
                label.font = .systemFont(ofSize: 12, weight: .medium)
                if field.type == "select" {
                    let popup = NSPopUpButton()
                    for option in field.options {
                        popup.addItem(withTitle: option.label)
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
            control.setAccessibilityLabel(field.label)
            controls[field.key] = control
            bindings[ObjectIdentifier(control)] = FormBinding(toolID: id, key: field.key)
        }
        settingsDocument.scroll(.zero)
    }

    private var isEditingFormText: Bool {
        controls.values.contains { ($0 as? NSTextField)?.currentEditor() != nil }
    }

    private func updateEnabledControls() {
        let item = manager.tools.first { $0.id == selectedID }
        picker.isEnabled = !busy && !ids.isEmpty
        toggle.isEnabled = !busy && item != nil
        installButton.isEnabled = !busy
        catalogButton.isEnabled = !busy
        editButton.isEnabled = !busy && selectedID.flatMap { manager.sourceURL(for: $0) } != nil
        reloadButton.isEnabled = editButton.isEnabled && item?.isEnabled == true
        demoButton.isEnabled = !busy && item?.isRunning == true
        clipboardButton.isEnabled = demoButton.isEnabled
        controls.values.forEach { $0.isEnabled = !busy }
    }

    private func enqueue(title: String, toolID: String? = nil, operation: @escaping @MainActor () async throws -> Void,
                         success: (@MainActor () -> Void)? = nil) {
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
                self.globalError = nil
                if let id = next.toolID { self.operationErrors.removeValue(forKey: id) }
                self.refreshDisplay()
                do {
                    try await next.operation()
                    next.success?()
                } catch {
                    if let id = next.toolID {
                        self.operationErrors[id] = OperationFailure(message: error.localizedDescription, reloadCount: startingReloadCount)
                    }
                    else { self.globalError = error.localizedDescription }
                }
            }
            self.workingTitle = nil
            self.operationTask = nil
            self.refreshDisplay()
        }
        updateEnabledControls()
    }

    @objc private func selectionChanged() {
        view.window?.makeFirstResponder(nil)
        refreshDisplay()
    }

    @objc private func openMarketplace() { onOpenMarketplace?() }

    @objc private func toggleEnabled() {
        guard let id = selectedID else { return }
        let enabled = toggle.state == .on
        let title = enabled ? (manager.sourceURL(for: id) == nil ? "Downloading source and enabling…" : "Enabling…") : "Disabling…"
        enqueue(title: title, toolID: id, operation: { [manager] in
            try await manager.setEnabled(enabled, for: id)
        })
    }

    @objc private func reloadSource() {
        guard let id = selectedID else { return }
        view.window?.makeFirstResponder(nil)
        enqueue(title: "Reloading source…", toolID: id, operation: { [manager] in try await manager.reload(id) })
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
        enqueue(title: "Saving settings…", toolID: binding.toolID, operation: { [manager] in
            try await manager.updateSetting(binding.key, value: value, for: binding.toolID)
        })
    }

    @objc private func installSource() {
        let panel = NSOpenPanel()
        panel.message = "Choose a trusted extension source folder. You can edit its files after installation."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let previous = Set(ids)
        enqueue(title: "Installing source…", operation: { [manager] in try await manager.importSource(from: source) }, success: { [weak self] in
            guard let self else { return }
            self.refreshDisplay()
            if let item = self.manager.tools.first(where: { !previous.contains($0.id) }), let index = self.ids.firstIndex(of: item.id) {
                self.picker.selectItem(at: index)
            }
        })
    }

    @objc private func addCatalog() {
        let alert = NSAlert()
        alert.messageText = "Add a tool catalog"
        alert.informativeText = "Enter the catalog JSON URL. Tools are downloaded when you enable them."
        alert.addButton(withTitle: "Add Catalog")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.placeholderString = "https://example.com/catalog.json"
        input.setAccessibilityLabel("Catalog URL")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let string = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["https", "http", "file"].contains(scheme), scheme == "file" || url.host != nil else {
            globalError = "Enter a complete catalog URL."
            refreshDisplay()
            return
        }
        enqueue(title: "Loading catalog…", operation: { [manager] in try await manager.addCatalog(from: url) })
    }

    @objc private func editSource() {
        guard let id = selectedID, let source = manager.sourceURL(for: id) else { return }
        let startingReloadCount = manager.tools.first(where: { $0.id == id })?.reloadCount ?? 0
        operationErrors.removeValue(forKey: id)
        refreshDisplay()
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCodeInsiders") {
            workspace.open([source], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.operationErrors[id] = OperationFailure(message: "Could not open VS Code: " + error.localizedDescription,
                                                                 reloadCount: startingReloadCount)
                    self?.refreshDisplay()
                }
            }
        } else { workspace.open(source) }
    }

    @objc private func runDemo() { if let id = selectedID { manager.runDemo(for: id) } }
    @objc private func translateClipboard() { if let id = selectedID { manager.translateClipboard(for: id) } }
    @objc private func openAISettings() { manager.openAISettings() }
    @objc private func showNativeExtensions() { onShowNativeExtensions?() }
    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return value as? String ?? String(describing: value)
    }

    private struct FormBinding { let toolID: String; let key: String }
    private struct OperationFailure { let message: String; let reloadCount: Int }
    private struct QueuedOperation {
        let title: String
        let toolID: String?
        let operation: @MainActor () async throws -> Void
        let success: (@MainActor () -> Void)?
    }
}

private final class SourceSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
