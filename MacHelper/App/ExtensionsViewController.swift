import AppKit
import MacHelper

@MainActor
final class ExtensionsViewController: NSViewController {
    private let registry: ExtensionRegistry
    private let picker = NSPopUpButton()
    private let toggle = NSButton(checkboxWithTitle: "Enable extension", target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var settingsHost: NSView!
    private var settingsScroll: NSScrollView!
    private var settingsHeight: NSLayoutConstraint!
    private var settingsController: NSViewController?
    private var ids: [String] = []

    init(registry: ExtensionRegistry) { self.registry = registry; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let install = NSButton(title: "Install Extension…", target: self, action: #selector(installExtension))
        let folder = NSButton(title: "Open Extensions Folder", target: self, action: #selector(openFolder))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshExtensions))
        let actions = NSStackView(views: [install, folder, refresh])
        actions.spacing = 10
        picker.target = self
        picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("Installed extension")
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true
        toggle.target = self
        toggle.action = #selector(toggleEnabled)
        let selection = NSStackView(views: [picker, toggle])
        selection.spacing = 18
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 2
        settingsHost = ExtensionSettingsDocumentView()
        settingsHost.translatesAutoresizingMaskIntoConstraints = false
        settingsScroll = NSScrollView()
        settingsScroll.drawsBackground = false
        settingsScroll.hasVerticalScroller = true
        settingsScroll.autohidesScrollers = true
        settingsScroll.documentView = settingsHost
        settingsHeight = settingsHost.heightAnchor.constraint(equalToConstant: 500)
        let stack = NSStackView(views: [actions, selection, summary, status, settingsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            settingsHost.widthAnchor.constraint(equalTo: settingsScroll.contentView.widthAnchor),
            settingsHost.leadingAnchor.constraint(equalTo: settingsScroll.contentView.leadingAnchor),
            settingsHost.topAnchor.constraint(equalTo: settingsScroll.contentView.topAnchor),
            settingsHeight
        ])
    }

    private var selectedID: String? {
        ids.indices.contains(picker.indexOfSelectedItem) ? ids[picker.indexOfSelectedItem] : nil
    }

    func refreshDisplay() {
        loadViewIfNeeded()
        let previous = selectedID
        ids = registry.extensions.map(\.id)
        picker.removeAllItems()
        picker.addItems(withTitles: registry.extensions.map { $0.manifest.displayName })
        if let previous, let index = ids.firstIndex(of: previous) { picker.selectItem(at: index) }
        showSelectedSettings()
    }

    private func showSelectedSettings() {
        settingsController?.view.removeFromSuperview()
        settingsController?.removeFromParent()
        settingsController = nil
        settingsHost.subviews.forEach { $0.removeFromSuperview() }
        guard let id = selectedID, let item = registry.extensions.first(where: { $0.id == id }) else {
            toggle.isEnabled = false
            summary.stringValue = "Install a .machextension bundle to add a tool here."
            status.stringValue = registry.issues.first?.message ?? "No extensions installed."
            return
        }
        toggle.isEnabled = true
        toggle.state = registry.isEnabled(id) ? .on : .off
        toggle.title = "Enable \(item.manifest.displayName)"
        summary.stringValue = "\(item.manifest.summary)  ·  \(item.manifest.version)"
        status.textColor = .secondaryLabelColor
        guard registry.isEnabled(id) else {
            status.stringValue = "Disabled. Enable only extensions you trust; enabled extensions share MacHelper’s access."
            return
        }
        do {
            let controller = try registry.settingsViewController(for: id)
            settingsController = controller
            addChild(controller)
            let child = controller.view
            settingsHeight.constant = min(2000, max(320, controller.preferredContentSize.height > 0 ? controller.preferredContentSize.height : 500))
            child.translatesAutoresizingMaskIntoConstraints = false
            settingsHost.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: settingsHost.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: settingsHost.trailingAnchor),
                child.topAnchor.constraint(equalTo: settingsHost.topAnchor),
                child.bottomAnchor.constraint(equalTo: settingsHost.bottomAnchor)
            ])
            status.stringValue = "Running in MacHelper."
            settingsHost.scroll(.zero)
        } catch {
            status.stringValue = error.localizedDescription
            status.textColor = .systemRed
        }
    }

    @objc private func selectionChanged() { showSelectedSettings() }

    @objc private func toggleEnabled() {
        guard let id = selectedID else { return }
        do { try registry.setEnabled(toggle.state == .on, for: id); showSelectedSettings() }
        catch {
            toggle.state = registry.isEnabled(id) ? .on : .off
            status.stringValue = error.localizedDescription
            status.textColor = .systemRed
        }
    }

    @objc private func refreshExtensions() {
        registry.refresh()
        registry.startEnabled()
        refreshDisplay()
        if let issue = registry.issues.first { status.stringValue = issue.message; status.textColor = .systemRed }
    }

    @objc private func openFolder() {
        do {
            try FileManager.default.createDirectory(at: registry.userDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(registry.userDirectory)
        } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }

    @objc private func installExtension() {
        let panel = NSOpenPanel()
        panel.message = "Choose a trusted .machextension bundle. It will be added disabled until you enable it."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let item = try registry.importExtension(from: url)
            refreshDisplay()
            if let index = ids.firstIndex(of: item.id) { picker.selectItem(at: index); showSelectedSettings() }
        } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
}

private final class ExtensionSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
