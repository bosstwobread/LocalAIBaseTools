import AppKit
import MacHelper
import MacHelperCapabilities

@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let login: LoginItemManager
    private let toggle = NSButton(checkboxWithTitle: L("Launch MacHelper at login"), target: nil, action: nil)
    private let compatibilityToggle = NSButton(checkboxWithTitle: L("Improve compatibility with Electron apps"), target: nil, action: nil)
    private let languagePicker = NSPopUpButton()
    var onLanguageChange: ((String) -> Bool)?
    private let status = NSTextField(wrappingLabelWithString: "")
    var registrationError: String?

    init(login: LoginItemManager) { self.login = login; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        let note = NSTextField(wrappingLabelWithString: L("MacHelper keeps running when you close this window. Click its Dock icon to reopen Settings, or use the menu bar. Your enabled extensions start with it."))
        note.textColor = .secondaryLabelColor
        let button = NSButton(title: L("Open Login Items…"), target: self, action: #selector(openLoginItems))
        note.font = .systemFont(ofSize: 12)
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        let startup = NSStackView(views: [section, toggle, status, button, note])
        startup.orientation = .vertical
        startup.alignment = .leading
        startup.spacing = 14
        let languageTitle = NSTextField(labelWithString: L("Interface language"))
        languageTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        languagePicker.addItem(withTitle: L("System language"))
        languagePicker.addItems(withTitles: AppLocalization.supportedLanguages.map(\.name))
        languagePicker.selectItem(at: languageIndex)
        languagePicker.target = self
        languagePicker.action = #selector(changeLanguage)
        languagePicker.identifier = NSUserInterfaceItemIdentifier("interface-language")
        languagePicker.setAccessibilityLabel(L("Interface language"))
        let languageNote = NSTextField(wrappingLabelWithString: L("Choose the language used in MacHelper."))
        languageNote.font = .systemFont(ofSize: 12)
        languageNote.textColor = .secondaryLabelColor
        let language = NSStackView(views: [languageTitle, languagePicker, languageNote])
        language.orientation = .vertical
        language.alignment = .leading
        language.spacing = 10
        let compatibilityTitle = NSTextField(labelWithString: L("App compatibility"))
        compatibilityTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        compatibilityToggle.state = SelectionCompatibilityPreferences.isEnabled ? .on : .off
        compatibilityToggle.target = self
        compatibilityToggle.action = #selector(changeCompatibility)
        compatibilityToggle.identifier = NSUserInterfaceItemIdentifier("electron-compatibility")
        compatibilityToggle.cell?.wraps = true
        compatibilityToggle.cell?.lineBreakMode = .byWordWrapping
        compatibilityToggle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let compatibilityNote = NSTextField(wrappingLabelWithString: L("Off by default. After you select text, MacHelper can ask supporting apps to expose full Accessibility information. Select the text again after changing this option."))
        let compatibilityEffects = NSTextField(wrappingLabelWithString: L("Some apps may change behavior. VS Code may enable Screen Reader Optimized mode, affecting features such as folding and the minimap."))
        let compatibilityReset = NSTextField(wrappingLabelWithString: L("Turning this off stops new requests. Apps already enabled may need to restart to revert. This does not turn on VoiceOver or change macOS permissions."))
        for label in [compatibilityNote, compatibilityEffects, compatibilityReset] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        let compatibility = NSStackView(views: [compatibilityTitle, compatibilityToggle, compatibilityNote, compatibilityEffects, compatibilityReset])
        compatibility.orientation = .vertical
        compatibility.alignment = .leading
        compatibility.spacing = 10
        let fallbackTitle = NSTextField(labelWithString: L("Automatic selection fallback"))
        fallbackTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let fallbackNote = NSTextField(wrappingLabelWithString: L("If Accessibility cannot read a selection, MacHelper temporarily copies it and restores the clipboard when safe."))
        let fallbackPrivacy = NSTextField(wrappingLabelWithString: L("Clipboard snapshots stay in memory for the capture attempt. They are never saved to files, logged, or sent to AI."))
        for label in [fallbackNote, fallbackPrivacy] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        let fallback = NSStackView(views: [fallbackTitle, fallbackNote, fallbackPrivacy])
        fallback.orientation = .vertical
        fallback.alignment = .leading
        fallback.spacing = 10
        let stack = NSStackView(views: [header, language, startup, compatibility, fallback])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -56)
        preferredWidth.priority = .defaultHigh
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
            startup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            compatibility.widthAnchor.constraint(equalTo: stack.widthAnchor),
            compatibilityToggle.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            compatibilityNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            compatibilityEffects.widthAnchor.constraint(equalTo: stack.widthAnchor),
            compatibilityReset.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fallback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fallbackNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fallbackPrivacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func refreshStatus() {
        loadViewIfNeeded()
        if login.isEnabled || login.requiresApproval { registrationError = nil }
        toggle.state = login.isEnabled || login.requiresApproval ? .on : .off
        compatibilityToggle.state = SelectionCompatibilityPreferences.isEnabled ? .on : .off
        status.stringValue = registrationError.map { L("Startup error: %@", L($0)) } ?? L(login.statusMessage)
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

    @objc private func changeLogin() {
        do {
            if toggle.state == .on { try login.register() } else { try login.unregister() }
            registrationError = nil
        } catch { registrationError = error.localizedDescription }
        refreshStatus()
    }
    @objc private func changeCompatibility() {
        SelectionCompatibilityPreferences.isEnabled = compatibilityToggle.state == .on
    }
    @objc private func openLoginItems() { login.openLoginSettings() }
}

private final class GeneralSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
