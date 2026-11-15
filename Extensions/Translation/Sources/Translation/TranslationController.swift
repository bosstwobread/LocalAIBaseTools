import AppKit
import ApplicationServices

/// A reusable native tool. The hosting app owns application lifecycle, windows,
/// menus, permission identity, and shared AI settings.
@MainActor
public final class TranslationController: NSObject {
    public var onOpenAISettings: (() -> Void)?
    public var onPresentOverlay: (() -> Void)?
    public var onStatusChange: (() -> Void)?
    public private(set) var isRunning = false
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }

    private let monitor = SelectionMonitor()
    private let panels = FloatingTranslationPanels()
    private var client = NativeHelperClient()
    private let preferences = TranslationPreferencesStore()
    private var state = SelectionState()
    private var translationTask: Task<Void, Never>?
    private var settingsController: TranslationSettingsViewController?
    private let permissionLabel = NSTextField(labelWithString: "")
    private let settingsErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let languagePopup = NSPopUpButton()
    private var translationActionButtons: [NSButton] = []
    private var manualSelection = false

    public override init() {
        super.init()
        panels.onTranslate = { [weak self] in self?.translateSelection() }
        panels.onDismiss = { [weak self] in self?.dismiss() }
        monitor.shouldIgnoreOutsideClick = { [weak self] point in
            guard let self else { return false }
            if self.panels.contains(point) { return true }
            guard let view = self.settingsController?.viewIfLoaded,
                  let window = view.window, window.isVisible else { return false }
            return window.frame.contains(point)
        }
        monitor.onRead = { [weak self] value in self?.receive(value) }
        monitor.onDismiss = { [weak self] in self?.dismiss() }
        monitor.onFrontApplicationChange = { [weak self] in self?.clearSelection() }
        monitor.onSelectionGesture = { [weak self] selecting in
            guard let self, selecting else { return }
            self.manualSelection = false
            self.state.rearmAfterSelectionGesture()
        }
        monitor.onPermissionChange = { [weak self] _ in self?.refreshStatus() }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start()
        refreshStatus()
    }

    public func configure(helperExecutableURL: URL, settingsDirectory: URL) {
        client = NativeHelperClient(executableURL: helperExecutableURL)
        do {
            try preferences.configure(directory: settingsDirectory)
            setSettingsError(nil)
        } catch { setSettingsError(error.localizedDescription) }
        if languagePopup.numberOfItems > 0 {
            languagePopup.selectItem(at: TranslationLanguage.all.firstIndex(of: targetLanguage) ?? 0)
        }
    }

    public func stop() {
        isRunning = false
        monitor.stop()
        clearSelection()
        refreshStatus()
    }

    public func makeSettingsViewController() -> NSViewController {
        if let settingsController {
            refreshStatus()
            return settingsController
        }
        let controller = TranslationSettingsViewController()
        controller.view = makeSettingsView()
        controller.preferredContentSize = NSSize(width: 480, height: 500)
        controller.onAppear = { [weak self] in self?.refreshStatus() }
        settingsController = controller
        refreshStatus()
        return controller
    }

    /// Reads only text the user has already copied, after this explicit action.
    @objc public func translateClipboard() {
        guard isRunning else { return }
        onPresentOverlay?()
        let point = NSEvent.mouseLocation
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showManualError("Your clipboard does not contain text. Copy text yourself, then choose Translate Clipboard again.", at: point)
            return
        }
        useManualSelection(text, at: point)
        translateSelection()
    }

    /// Synthetic selection only; this action needs no Accessibility permission.
    @objc public func showDemo() {
        guard isRunning else { return }
        onPresentOverlay?()
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        useManualSelection("Hello! Select text in any supported Mac app, then click the translation icon.",
                           at: CGPoint(x: screen.midX - 120, y: screen.midY))
        if let selection = state.selection { panels.showIcon(near: selection.bounds) }
    }

    private var targetLanguage: TranslationLanguage {
        TranslationLanguage.all.first(where: { $0.code == preferences.targetLanguage })
            ?? TranslationLanguage.all[0]
    }

    private func receive(_ value: SelectionReadResult) {
        guard isRunning, !manualSelection else { return }
        let selection: TextSelection?
        switch value {
        case .selection(let found): selection = found
        case .empty, .unavailable: selection = nil
        }
        guard state.observe(selection) else { return }
        translationTask?.cancel()
        translationTask = nil
        if let selection, state.canTranslate { panels.showIcon(near: selection.bounds) }
        else { panels.hide() }
    }

    private func translateSelection() {
        guard state.canTranslate, let selection = state.selection else { return }
        translationTask?.cancel()
        let token = state.generation
        let language = targetLanguage
        panels.showLoading(near: selection.bounds, language: language.title)
        translationTask = Task { [weak self, client] in
            do {
                let response = try await client.translate(text: selection.text, targetLanguage: language.code)
                guard let self, !Task.isCancelled, self.state.acceptsResult(for: token) else { return }
                self.panels.showResponse(response, near: selection.bounds, language: language.title)
            } catch {
                guard let self, !Task.isCancelled, self.state.acceptsResult(for: token) else { return }
                self.panels.showError(error.localizedDescription, near: selection.bounds)
            }
        }
    }

    private func dismiss() {
        translationTask?.cancel()
        translationTask = nil
        state.dismiss()
        manualSelection = false
        panels.hide()
    }

    private func clearSelection() {
        dismiss()
        state.observe(nil)
    }

    private func useManualSelection(_ text: String, at point: CGPoint) {
        clearSelection()
        manualSelection = true
        state.observe(TextSelection(text: text, sourcePID: ProcessInfo.processInfo.processIdentifier,
                                    rangeLocation: -1, rangeLength: text.utf16.count,
                                    bounds: CGRect(x: point.x, y: point.y, width: 1, height: 20)))
    }

    private func showManualError(_ message: String, at point: CGPoint) {
        clearSelection()
        manualSelection = true
        panels.showError(message, near: CGRect(x: point.x, y: point.y, width: 1, height: 20), canRetry: false)
    }

    private func makeSettingsView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 500))
        let title = NSTextField(labelWithString: "Translate selected text anywhere")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let description = Self.wrappedLabel("Select text in an app, then click the small translation icon. Results appear near the selection. Press Esc or click elsewhere to dismiss.")
        let languageLabel = NSTextField(labelWithString: "Translate to")
        languagePopup.addItems(withTitles: TranslationLanguage.all.map(\.title))
        languagePopup.selectItem(at: TranslationLanguage.all.firstIndex(of: targetLanguage) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
        let languageRow = NSStackView(views: [languageLabel, languagePopup])
        languageRow.orientation = .horizontal
        languageRow.spacing = 16
        languageRow.alignment = .centerY
        permissionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let permissionHelp = Self.wrappedLabel("Allow MacHelper in System Settings → Privacy & Security → Accessibility. Some apps do not expose selected text; copy text yourself, then choose Translate Clipboard.")
        let permissionButton = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openAccessibility))
        permissionButton.bezelStyle = .rounded
        let helperLabel = Self.wrappedLabel("Your AI provider and model are managed in MacHelper’s AI settings.")
        helperLabel.textColor = .secondaryLabelColor
        let helperButton = NSButton(title: "AI Settings…", target: self, action: #selector(openAISettings))
        helperButton.bezelStyle = .rounded
        let demoButton = NSButton(title: "Try Demo…", target: self, action: #selector(showDemo))
        demoButton.bezelStyle = .rounded
        let clipboardButton = NSButton(title: "Translate Clipboard…", target: self, action: #selector(translateClipboard))
        clipboardButton.bezelStyle = .rounded
        translationActionButtons = [demoButton, clipboardButton]
        let actions = NSStackView(views: [helperButton, demoButton, clipboardButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        let privacy = Self.wrappedLabel("Text is sent only after you click Translate. Translation does not paste, send messages, or save text history. Your AI provider may retain its own records.")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        settingsErrorLabel.font = .systemFont(ofSize: 11)
        settingsErrorLabel.textColor = .systemOrange
        settingsErrorLabel.isHidden = settingsErrorLabel.stringValue.isEmpty
        let stack = NSStackView(views: [title, description, languageRow, permissionLabel, permissionHelp,
                                       permissionButton, helperLabel, actions, privacy, settingsErrorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            helperLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsErrorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        return content
    }

    private static func wrappedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func refreshStatus() {
        let trusted = accessibilityGranted
        permissionLabel.stringValue = trusted ? "Accessibility access is enabled" : "Accessibility access is required"
        permissionLabel.textColor = trusted ? .secondaryLabelColor : .systemOrange
        translationActionButtons.forEach { $0.isEnabled = isRunning }
        onStatusChange?()
    }

    @objc private func changeLanguage() {
        let index = languagePopup.indexOfSelectedItem
        guard TranslationLanguage.all.indices.contains(index) else { return }
        do {
            try preferences.setTargetLanguage(TranslationLanguage.all[index].code)
            setSettingsError(nil)
        } catch { setSettingsError("Could not save Translation settings: " + error.localizedDescription) }
    }

    private func setSettingsError(_ message: String?) {
        settingsErrorLabel.stringValue = message ?? ""
        settingsErrorLabel.isHidden = message == nil
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAISettings() { onOpenAISettings?() }
}

@MainActor
private final class TranslationSettingsViewController: NSViewController {
    var onAppear: (() -> Void)?
    override func viewWillAppear() {
        super.viewWillAppear()
        onAppear?()
    }
}
