import AppKit

@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let login: LoginItemManager
    private let toggle = NSButton(checkboxWithTitle: "Launch MacHelper at login", target: nil, action: nil)
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
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Startup and background behavior.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let section = NSTextField(labelWithString: "Startup")
        section.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.target = self
        toggle.action = #selector(changeLogin)
        status.font = .systemFont(ofSize: 12)
        let note = NSTextField(wrappingLabelWithString: "MacHelper keeps running when you close this window. Click its Dock icon to reopen Settings, or use the menu bar. Your enabled extensions start with it.")
        note.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open Login Items…", target: self, action: #selector(openLoginItems))
        note.font = .systemFont(ofSize: 12)
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        let startup = NSStackView(views: [section, toggle, status, button, note])
        startup.orientation = .vertical
        startup.alignment = .leading
        startup.spacing = 14
        let stack = NSStackView(views: [header, startup])
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
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func refreshStatus() {
        loadViewIfNeeded()
        if login.isEnabled || login.requiresApproval { registrationError = nil }
        toggle.state = login.isEnabled || login.requiresApproval ? .on : .off
        status.stringValue = registrationError ?? login.statusMessage
        status.textColor = registrationError == nil ? .secondaryLabelColor : .systemRed
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
