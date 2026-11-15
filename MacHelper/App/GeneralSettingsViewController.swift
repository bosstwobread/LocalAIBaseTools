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
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        toggle.target = self
        toggle.action = #selector(changeLogin)
        status.font = .systemFont(ofSize: 12)
        let note = NSTextField(wrappingLabelWithString: "MacHelper stays in the menu bar when you close this window. Your enabled extensions start with it.")
        note.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open Login Items…", target: self, action: #selector(openLoginItems))
        let stack = NSStackView(views: [title, toggle, status, button, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
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
