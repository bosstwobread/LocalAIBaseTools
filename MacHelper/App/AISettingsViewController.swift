import AppKit
import MacHelper

@MainActor
final class AISettingsViewController: NSViewController {
    private let store = HelperSettingsStore()
    private let providerPicker = NSPopUpButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let addressField = NSTextField()
    private let modelPicker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var addressRow: NSStackView!
    private var refreshButton: NSButton!
    private var testButton: NSButton!
    private var saveButton: NSButton!
    private var modelIDs = [""]
    private var settings = HelperSettings()
    private var isLoading = false
    private let websiteStatus = NSTextField(wrappingLabelWithString: "")
    var onRestartWebsiteConnection: (() -> Void)?
    var websiteConnectionState: MarketplaceLocalService.State = .stopped {
        didSet { if isViewLoaded { updateWebsiteConnectionStatus() } }
    }

    var hasPendingChanges: Bool {
        guard isViewLoaded else { return false }
        return isLoading || (try? currentSettings()) != settings
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        do { settings = try store.load() }
        catch { setStatus(L("Settings could not be loaded: %@", error.localizedDescription), error: true) }
        providerPicker.selectItem(at: AIProvider.allCases.firstIndex(of: settings.provider) ?? 0)
        addressField.stringValue = settings.baseURL
        showCurrentModel(settings.model)
        updateProviderDescription()
        refreshModels(nil)
    }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let document = AISettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 16
        container.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(container)
        let preferredWidth = container.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -56)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            container.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            preferredWidth,
            container.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            container.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])

        let title = NSTextField(labelWithString: L("AI Connection"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        container.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: L("Choose the AI service and model shared by your tools."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        container.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        providerPicker.addItems(withTitles: AIProvider.allCases.map { L($0.displayName) })
        providerPicker.target = self
        providerPicker.action = #selector(providerChanged(_:))
        providerPicker.setAccessibilityLabel(L("AI service"))
        addRow(label: "AI service", control: providerPicker, in: container)

        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        container.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        addressField.placeholderString = "http://127.0.0.1:11434"
        addressField.setAccessibilityLabel(L("Local service address"))
        addressRow = addRow(label: "Address", control: addressField, in: container)

        modelPicker.setAccessibilityLabel(L("AI model"))
        refreshButton = NSButton(title: L("Refresh"), target: self, action: #selector(refreshModels(_:)))
        let modelControls = NSStackView(views: [modelPicker, refreshButton])
        modelControls.spacing = 8
        modelControls.distribution = .fill
        modelPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true
        modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addRow(label: "Model", control: modelControls, in: container)

        let note = NSTextField(wrappingLabelWithString: L("Refresh reads the current model list from your AI service. New models appear without updating your tools."))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        container.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 0
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 8
        container.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        testButton = NSButton(title: L("Test Connection"), target: self, action: #selector(testConnection(_:)))
        saveButton = NSButton(title: L("Save"), target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [testButton, saveButton])
        buttons.spacing = 12
        container.addArrangedSubview(buttons)

        let websiteTitle = NSTextField(labelWithString: L("Website connection"))
        websiteTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        container.addArrangedSubview(websiteTitle)
        websiteStatus.font = .systemFont(ofSize: 12)
        container.addArrangedSubview(websiteStatus)
        websiteStatus.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        updateWebsiteConnectionStatus()
        let websiteNote = NSTextField(wrappingLabelWithString: L("Click Find with AI on the Extension Market. MacHelper connects automatically. A new or reinstalled browser may ask you to allow local access."))
        websiteNote.font = .systemFont(ofSize: 12)
        websiteNote.textColor = .secondaryLabelColor
        container.addArrangedSubview(websiteNote)
        websiteNote.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.addArrangedSubview(NSButton(title: L("Restart Connection"), target: self, action: #selector(restartWebsiteConnection(_:))))
    }

    private func updateWebsiteConnectionStatus() {
        websiteStatus.textColor = .secondaryLabelColor
        switch websiteConnectionState {
        case .ready: websiteStatus.stringValue = L("Ready — no browser extension needed.")
        case .starting: websiteStatus.stringValue = L("Starting website connection…")
        case .stopped: websiteStatus.stringValue = L("Website connection is stopped.")
        case .failed:
            websiteStatus.stringValue = L("Website connection could not start. Quit other copies of MacHelper and try again.")
            websiteStatus.textColor = .systemRed
        }
    }

    @objc private func restartWebsiteConnection(_ sender: Any?) { onRestartWebsiteConnection?() }

    @discardableResult
    private func addRow(label: String, control: NSView, in container: NSStackView) -> NSStackView {
        let title = NSTextField(labelWithString: L(label))
        title.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        let row = NSStackView(views: [title, control])
        row.spacing = 12
        row.alignment = .centerY
        row.distribution = .fill
        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private var selectedProvider: AIProvider {
        AIProvider.allCases[max(0, providerPicker.indexOfSelectedItem)]
    }

    private func currentSettings() throws -> HelperSettings {
        let index = modelPicker.indexOfSelectedItem
        let model = modelIDs.indices.contains(index) ? modelIDs[index] : ""
        return try HelperSettings(provider: selectedProvider, model: model,
                                  baseURL: addressField.stringValue).validated()
    }

    private func updateProviderDescription() {
        explanation.stringValue = L(selectedProvider.explanation)
        addressRow.isHidden = selectedProvider == .chatGPT
        addressField.placeholderString = selectedProvider.defaultBaseURL
    }

    @objc private func providerChanged(_ sender: Any?) {
        addressField.stringValue = selectedProvider.defaultBaseURL
        showCurrentModel("")
        updateProviderDescription()
        setStatus(L("Choose a model, then save your settings."))
        refreshModels(nil)
    }

    private func showCurrentModel(_ model: String) {
        modelPicker.removeAllItems()
        modelPicker.addItem(withTitle: selectedProvider == .chatGPT ? L("Automatic (service default)") : L("Choose a model…"))
        modelIDs = [""]
        if !model.isEmpty {
            modelIDs.append(model)
            modelPicker.addItem(withTitle: model)
            modelPicker.selectItem(at: 1)
        }
    }

    @objc private func refreshModels(_ sender: Any?) { loadModels(isTest: false) }
    @objc private func testConnection(_ sender: Any?) { loadModels(isTest: true) }

    private func loadModels(isTest: Bool) {
        guard !isLoading else { return }
        let chosen: HelperSettings
        do { chosen = try currentSettings() }
        catch { setStatus(error.localizedDescription, error: true); return }
        setLoading(true)
        setStatus(isTest ? L("Checking connection…") : L("Loading models…"))
        Task { [weak self] in
            guard let self else { return }
            defer { self.setLoading(false) }
            do {
                let catalog = try await SettingsHostClient.listModels(settings: chosen)
                self.showCurrentModel("")
                for model in catalog.models {
                    guard !self.modelIDs.contains(model.model) else { continue }
                    self.modelIDs.append(model.model)
                    self.modelPicker.addItem(withTitle: model.displayName)
                }
                if !chosen.model.isEmpty {
                    if let index = self.modelIDs.firstIndex(of: chosen.model) {
                        self.modelPicker.selectItem(at: index)
                    } else {
                        self.modelIDs.append(chosen.model)
                        self.modelPicker.addItem(withTitle: L("%@ (unavailable)", chosen.model))
                        self.modelPicker.selectItem(at: self.modelIDs.count - 1)
                    }
                } else if chosen.provider != .chatGPT, self.modelIDs.count > 1 {
                    self.modelPicker.selectItem(at: 1)
                }
                let count = catalog.models.count
                if count == 0 {
                    self.setStatus(L("Connected. No models are available; load or download a model in %@.", L(chosen.provider.displayName)))
                } else {
                    self.setStatus(count == 1 ? L("Connected to %@. %ld model available.", L(chosen.provider.displayName), count) : L("Connected to %@. %ld models available.", L(chosen.provider.displayName), count))
                }
            } catch { self.setStatus(error.localizedDescription, error: true) }
        }
    }

    @objc private func save(_ sender: Any?) {
        do {
            settings = try currentSettings()
            guard settings.provider == .chatGPT || !settings.model.isEmpty else {
                setStatus(L("Choose a model before saving. Refresh the list after starting your AI service."), error: true)
                return
            }
            try store.save(settings)
            addressField.stringValue = settings.baseURL
            setStatus(L("Saved. Your tools will use these settings for their next request."))
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    private func setLoading(_ loading: Bool) {
        isLoading = loading
        providerPicker.isEnabled = !loading
        addressField.isEnabled = !loading
        modelPicker.isEnabled = !loading
        refreshButton.isEnabled = !loading
        testButton.isEnabled = !loading
        saveButton.isEnabled = !loading
        loading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func setStatus(_ message: String, error: Bool = false) {
        status.stringValue = error ? L("Connection error: %@", L(message)) : L(message)
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }
}

private final class AISettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
