import AppKit
import Carbon
import MacHelper

@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let login: LoginItemManager
    private let enabledToggle = NSButton(checkboxWithTitle: L("Enable MacHelper"), target: nil, action: nil)
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let changeShortcutButton = NSButton(title: L("Change Shortcut…"), target: nil, action: nil)
    private let resetShortcutButton = NSButton(title: L("Use Default"), target: nil, action: nil)
    private var shortcutHint = ""
    private var shortcutMonitor: Any?
    private var pendingShortcut: (keyCode: UInt16, shortcut: GlobalShortcut)?
    var onBeginShortcutRecording: (() -> Void)?
    var onFinishShortcutRecording: ((GlobalShortcut?) -> Bool)?
    var onResetShortcut: (() -> Bool)?
    var onMacHelperEnabledChange: ((Bool) -> Void)? {
        didSet { enabledToggle.isEnabled = onMacHelperEnabledChange != nil }
    }
    private let toggle = NSButton(checkboxWithTitle: L("Launch MacHelper at login"), target: nil, action: nil)
    private let languagePicker = NSPopUpButton()
    var onLanguageChange: ((String) -> Bool)?
    private let status = NSTextField(wrappingLabelWithString: "")
    var registrationError: String?

    init(login: LoginItemManager) { self.login = login; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let document = GeneralSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let title = NSTextField(labelWithString: L("General"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: L("Language, startup, and background behavior."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let section = NSTextField(labelWithString: L("Startup"))
        section.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.target = self
        toggle.action = #selector(changeLogin)
        status.font = .systemFont(ofSize: 12)
        let button = NSButton(title: L("Open Login Items…"), target: self, action: #selector(openLoginItems))
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        let startup = NSStackView(views: [section, toggle, status, button])
        startup.orientation = .vertical
        startup.alignment = .leading
        startup.spacing = 14
        let shortcutTitle = NSTextField(labelWithString: L("Global keyboard shortcut"))
        shortcutTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        enabledToggle.target = self
        enabledToggle.action = #selector(changeMacHelperEnabled)
        enabledToggle.identifier = NSUserInterfaceItemIdentifier("machelper-enabled")
        enabledToggle.isEnabled = onMacHelperEnabledChange != nil
        shortcutStatus.font = .systemFont(ofSize: 12)
        shortcutStatus.textColor = .secondaryLabelColor
        changeShortcutButton.target = self
        changeShortcutButton.action = #selector(changeShortcut)
        changeShortcutButton.identifier = NSUserInterfaceItemIdentifier("change-global-shortcut")
        changeShortcutButton.isEnabled = onBeginShortcutRecording != nil && onFinishShortcutRecording != nil
        resetShortcutButton.target = self
        resetShortcutButton.action = #selector(resetShortcut)
        resetShortcutButton.identifier = NSUserInterfaceItemIdentifier("reset-global-shortcut")
        resetShortcutButton.isEnabled = onResetShortcut != nil
        let shortcutControls = NSStackView(views: [changeShortcutButton, resetShortcutButton])
        shortcutControls.alignment = .centerY
        shortcutControls.spacing = 8
        let shortcut = NSStackView(views: [shortcutTitle, enabledToggle, shortcutStatus, shortcutControls])
        shortcut.orientation = .vertical
        shortcut.alignment = .leading
        shortcut.spacing = 10
        let languageTitle = NSTextField(labelWithString: L("Interface language"))
        languageTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        languagePicker.addItem(withTitle: L("System language"))
        languagePicker.addItems(withTitles: AppLocalization.supportedLanguages.map(\.name))
        languagePicker.selectItem(at: languageIndex)
        languagePicker.target = self
        languagePicker.action = #selector(changeLanguage)
        languagePicker.identifier = NSUserInterfaceItemIdentifier("interface-language")
        languagePicker.setAccessibilityLabel(L("Interface language"))
        let language = NSStackView(views: [languageTitle, languagePicker])
        language.orientation = .vertical
        language.alignment = .leading
        language.spacing = 10
        let stack = NSStackView(views: [header, language, startup, shortcut])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -56)
        // Keep the 720-point form cap from resizing the settings window.
        preferredWidth.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            preferredWidth,
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcut.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            startup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func updateMacHelperState(isEnabled: Bool, shortcut: String, shortcutAvailable: Bool) {
        enabledToggle.state = isEnabled ? .on : .off
        let displayedShortcut = AppLocalization.shared.isRightToLeft ? "\u{2066}\(shortcut)\u{2069}" : shortcut
        shortcutHint = shortcutAvailable
            ? L("Press %@ in any app to pause or resume MacHelper.", displayedShortcut)
            : L("The global shortcut %@ is unavailable. You can still pause or resume MacHelper here.", displayedShortcut)
        if shortcutMonitor == nil { shortcutStatus.stringValue = shortcutHint }
    }

    func cancelShortcutRecording() {
        finishShortcutRecording(nil)
    }

    @objc private func changeShortcut() {
        if shortcutMonitor != nil {
            cancelShortcutRecording()
            return
        }
        guard let window = view.window, let begin = onBeginShortcutRecording, onFinishShortcutRecording != nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
            guard let self, let window, window.isKeyWindow, event.window == nil || event.window === window else { return event }
            return self.handleShortcutRecordingEvent(event)
        }
        guard shortcutMonitor != nil else {
            showUnavailableShortcut()
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutRecordingWindowResigned(_:)),
            name: NSWindow.didResignKeyNotification, object: window)
        begin()
        changeShortcutButton.title = L("Cancel Recording")
        resetShortcutButton.isEnabled = false
        shortcutStatus.stringValue = L("Press a key with at least two modifiers. Press Escape to cancel.")
    }

    private func handleShortcutRecordingEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let point = changeShortcutButton.convert(event.locationInWindow, from: nil)
            if !changeShortcutButton.bounds.contains(point) { cancelShortcutRecording() }
            return event
        case .keyDown:
            if event.keyCode == kVK_Escape {
                cancelShortcutRecording()
            } else if !event.isARepeat, pendingShortcut == nil {
                if let shortcut = GlobalShortcut(event: event) {
                    pendingShortcut = (event.keyCode, shortcut)
                } else {
                    shortcutStatus.stringValue = L("Use at least two modifiers and a supported key.")
                }
            }
        case .keyUp:
            if let pendingShortcut, event.keyCode == pendingShortcut.keyCode {
                // Register after the recording keystroke is released, so it cannot also toggle MacHelper.
                finishShortcutRecording(pendingShortcut.shortcut)
            }
        default: return event
        }
        return nil
    }

    private func finishShortcutRecording(_ shortcut: GlobalShortcut?) {
        guard let shortcutMonitor else { return }
        NSEvent.removeMonitor(shortcutMonitor)
        self.shortcutMonitor = nil
        pendingShortcut = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        changeShortcutButton.title = L("Change Shortcut…")
        resetShortcutButton.isEnabled = onResetShortcut != nil
        shortcutStatus.stringValue = shortcutHint
        let accepted = onFinishShortcutRecording?(shortcut) == true
        if shortcut != nil, !accepted { showUnavailableShortcut() }
    }

    @objc private func shortcutRecordingWindowResigned(_ notification: Notification) {
        cancelShortcutRecording()
    }

    @objc private func resetShortcut() {
        if onResetShortcut?() != true { showUnavailableShortcut() }
    }

    private func showUnavailableShortcut() {
        shortcutStatus.stringValue = L("That shortcut is unavailable. Choose another combination.") + "\n" + shortcutHint
    }

    func refreshStatus() {
        loadViewIfNeeded()
        if login.isEnabled || login.requiresApproval { registrationError = nil }
        toggle.state = login.isEnabled || login.requiresApproval ? .on : .off
        let message = registrationError.map { L("Startup error: %@", L($0)) } ?? login.statusMessage
        status.stringValue = message ?? ""
        status.isHidden = message == nil
        status.textColor = registrationError == nil ? .secondaryLabelColor : .systemRed
    }

    private var languageIndex: Int {
        AppLocalization.supportedLanguages.firstIndex { $0.code == AppLocalization.shared.language }.map { $0 + 1 } ?? 0
    }

    @objc private func changeLanguage() {
        let index = languagePicker.indexOfSelectedItem
        let languages = AppLocalization.supportedLanguages
        let code = index > 0 && languages.indices.contains(index - 1) ? languages[index - 1].code : "system"
        if onLanguageChange?(code) != true { languagePicker.selectItem(at: languageIndex) }
    }

    @objc private func changeMacHelperEnabled() {
        onMacHelperEnabledChange?(enabledToggle.state == .on)
    }

    @objc private func changeLogin() {
        do {
            if toggle.state == .on { try login.register() } else { try login.unregister() }
            registrationError = nil
        } catch { registrationError = error.localizedDescription }
        refreshStatus()
    }
    @objc private func openLoginItems() { login.openLoginSettings() }
}

private final class GeneralSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
