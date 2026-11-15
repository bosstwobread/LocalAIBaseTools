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

    override func viewDidLoad() {
        super.viewDidLoad()
        do { settings = try store.load() }
        catch { setStatus("Settings could not be loaded: \(error.localizedDescription)", error: true) }
        providerPicker.selectItem(at: AIProvider.allCases.firstIndex(of: settings.provider) ?? 0)
        addressField.stringValue = settings.baseURL
        showCurrentModel(settings.model)
        updateProviderDescription()
        refreshModels(nil)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 490))
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 16
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 26)
        ])

        let title = NSTextField(labelWithString: "One AI connection for your tools")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        container.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Choose the AI service used by Translation and your extensions.")
        subtitle.textColor = .secondaryLabelColor
        container.addArrangedSubview(subtitle)

        providerPicker.addItems(withTitles: AIProvider.allCases.map(\.displayName))
        providerPicker.target = self
        providerPicker.action = #selector(providerChanged(_:))
        providerPicker.setAccessibilityLabel("AI service")
        container.addArrangedSubview(row(label: "AI service", control: providerPicker))

        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.widthAnchor.constraint(equalToConstant: 504).isActive = true
        container.addArrangedSubview(explanation)

        addressField.placeholderString = "http://127.0.0.1:11434"
        addressField.setAccessibilityLabel("Local service address")
        addressRow = row(label: "Address", control: addressField)
        container.addArrangedSubview(addressRow)

        modelPicker.setAccessibilityLabel("AI model")
        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshModels(_:)))
        let modelControls = NSStackView(views: [modelPicker, refreshButton])
        modelControls.spacing = 8
        modelPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true
        container.addArrangedSubview(row(label: "Model", control: modelControls))

        let note = NSTextField(wrappingLabelWithString: "Refresh reads the current model list from your AI service. New models appear without updating your tools.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 504).isActive = true
        container.addArrangedSubview(note)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.spacing = 8
        statusRow.widthAnchor.constraint(equalToConstant: 504).isActive = true
        container.addArrangedSubview(statusRow)

        testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection(_:)))
        saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [testButton, saveButton])
        buttons.spacing = 12
        container.addArrangedSubview(buttons)
        container.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24).isActive = true
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let row = NSStackView(views: [title, control])
        row.spacing = 12
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 504).isActive = true
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
        explanation.stringValue = selectedProvider.explanation
        addressRow.isHidden = selectedProvider == .chatGPT
        addressField.placeholderString = selectedProvider.defaultBaseURL
    }

    @objc private func providerChanged(_ sender: Any?) {
        addressField.stringValue = selectedProvider.defaultBaseURL
        showCurrentModel("")
        updateProviderDescription()
        setStatus("Choose a model, then save your settings.")
        refreshModels(nil)
    }

    private func showCurrentModel(_ model: String) {
        modelPicker.removeAllItems()
        modelPicker.addItem(withTitle: selectedProvider == .chatGPT ? "Automatic (service default)" : "Choose a model…")
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
        setStatus(isTest ? "Checking connection…" : "Loading models…")
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
                        self.modelPicker.addItem(withTitle: "\(chosen.model) (unavailable)")
                        self.modelPicker.selectItem(at: self.modelIDs.count - 1)
                    }
                } else if chosen.provider != .chatGPT, self.modelIDs.count > 1 {
                    self.modelPicker.selectItem(at: 1)
                }
                let count = catalog.models.count
                if count == 0 {
                    self.setStatus("Connected. No models are available; load or download a model in \(chosen.provider.displayName).")
                } else {
                    self.setStatus("Connected to \(chosen.provider.displayName). \(count) model\(count == 1 ? "" : "s") available.")
                }
            } catch { self.setStatus(error.localizedDescription, error: true) }
        }
    }

    @objc private func save(_ sender: Any?) {
        do {
            settings = try currentSettings()
            guard settings.provider == .chatGPT || !settings.model.isEmpty else {
                setStatus("Choose a model before saving. Refresh the list after starting your AI service.", error: true)
                return
            }
            try store.save(settings)
            addressField.stringValue = settings.baseURL
            setStatus("Saved. Your tools will use these settings for their next request.")
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
        status.stringValue = message
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }
}
