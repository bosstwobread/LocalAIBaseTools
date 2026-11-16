import AppKit
import MacHelper

/// Search is presentation over public listing metadata. No extension worker,
/// source installation, or AI request starts while someone types a query.
@MainActor
final class DiscoveryViewController: NSViewController, NSTextViewDelegate {
    struct Services {
        var load: @MainActor (Bool) async throws -> DiscoveryCatalogSnapshot
        var search: @MainActor (String, String, @escaping @Sendable (String) -> Void) async throws -> DiscoverySearchResult
        var cancel: @MainActor () async -> Void
    }

    struct Draft {
        var query = ""
        var describesNeed = false
    }

    private let services: Services
    private let openDetails: (URL) -> Bool
    private let marketplaceURL: () throws -> URL
    private let mode = NSSegmentedControl(labels: [L("Keywords"), L("Describe what you need")], trackingMode: .selectOne, target: nil, action: nil)
    private let query = DiscoveryQueryTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 86))
    private let refreshButton = NSButton(title: L("Refresh descriptions"), target: nil, action: nil)
    private let searchButton = NSButton(title: L("Find with AI"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L("Cancel"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let catalogStatus = NSTextField(wrappingLabelWithString: "")
    private let resultCount = NSTextField(labelWithString: "")
    private let results = NSStackView()
    private let examples = NSStackView()
    private let spinner = NSProgressIndicator()
    private var snapshot: DiscoveryCatalogSnapshot?
    private var aiResult: DiscoverySearchResult?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var initialDraft: Draft
    private var examplesByButton: [ObjectIdentifier: String] = [:]
    private var detailsByButton: [ObjectIdentifier: URL] = [:]
    private var initialLoadStarted = false
    private(set) var isBusy = false

    init(services: Services, draft: Draft = Draft(),
         marketplaceURL: @escaping () throws -> URL = { try MarketplaceConfiguration.websiteURL() },
         openDetails: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.services = services; initialDraft = draft
        self.marketplaceURL = marketplaceURL; self.openDetails = openDetails
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var draft: Draft {
        isViewLoaded ? Draft(query: query.string, describesNeed: mode.selectedSegment == 1) : initialDraft
    }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = DiscoveryDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)
        let stack = column(spacing: 16)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
        add(label(L("Find tools"), size: 24, weight: .semibold), to: stack)
        add(label(L("Search public descriptions, or ask your AI to find tools for a task."), size: 13, color: .secondaryLabelColor), to: stack)
        mode.selectedSegment = initialDraft.describesNeed ? 1 : 0
        mode.target = self; mode.action = #selector(changeSearchMode)
        mode.identifier = NSUserInterfaceItemIdentifier("discovery-mode")
        mode.setAccessibilityLabel(L("Search mode"))
        stack.addArrangedSubview(mode)

        query.isRichText = false; query.isAutomaticQuoteSubstitutionEnabled = false
        query.isAutomaticDashSubstitutionEnabled = false; query.isAutomaticTextReplacementEnabled = false
        query.drawsBackground = false; query.font = .systemFont(ofSize: 14)
        query.textColor = .labelColor; query.delegate = self
        query.textContainerInset = NSSize(width: 10, height: 9)
        query.isHorizontallyResizable = false; query.isVerticallyResizable = true
        query.autoresizingMask = [.width]; query.textContainer?.widthTracksTextView = true
        query.baseWritingDirection = .natural
        query.identifier = NSUserInterfaceItemIdentifier("discovery-query")
        query.setAccessibilityLabel(L("Keywords or a description"))
        query.string = initialDraft.query
        let queryScroll = NSScrollView()
        queryScroll.borderType = .bezelBorder; queryScroll.hasVerticalScroller = true
        queryScroll.autohidesScrollers = true; queryScroll.documentView = query
        add(queryScroll, to: stack)
        queryScroll.heightAnchor.constraint(equalToConstant: 86).isActive = true

        searchButton.target = self; searchButton.action = #selector(findWithAI)
        searchButton.bezelStyle = .rounded; searchButton.bezelColor = .controlAccentColor
        searchButton.identifier = NSUserInterfaceItemIdentifier("discovery-ai-search")
        cancelButton.target = self; cancelButton.action = #selector(cancelSearch)
        cancelButton.identifier = NSUserInterfaceItemIdentifier("discovery-cancel")
        refreshButton.target = self; refreshButton.action = #selector(refreshDescriptions)
        refreshButton.identifier = NSUserInterfaceItemIdentifier("discovery-refresh")
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let actions = NSStackView(views: [searchButton, cancelButton, spinner, flexibleSpace(), refreshButton])
        actions.alignment = .centerY; actions.spacing = 8
        add(actions, to: stack)
        add(label(L("Keyword search uses no AI. AI search uses your selected provider and never installs a tool."), size: 12, color: .secondaryLabelColor), to: stack)

        status.font = .systemFont(ofSize: 12); status.identifier = NSUserInterfaceItemIdentifier("discovery-status")
        catalogStatus.font = .systemFont(ofSize: 11); catalogStatus.textColor = .secondaryLabelColor
        catalogStatus.identifier = NSUserInterfaceItemIdentifier("discovery-catalog-status")
        add(status, to: stack); add(catalogStatus, to: stack)
        examples.orientation = .vertical; examples.alignment = .leading; examples.spacing = 5
        add(examples, to: stack)
        resultCount.font = .systemFont(ofSize: 13, weight: .semibold)
        resultCount.identifier = NSUserInterfaceItemIdentifier("discovery-result-count")
        add(resultCount, to: stack)
        results.orientation = .vertical; results.alignment = .leading; results.spacing = 12
        add(results, to: stack)
        updateControls(); render()
        applyAppLanguageDirection(to: view)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !initialLoadStarted else { return }
        initialLoadStarted = true
        loadDescriptions(refresh: true)
    }

    /// Receiving a website link only fills the form. AI still needs a click.
    func present(query text: String) {
        if isBusy { stopOperation(showStatus: false) }
        initialDraft = Draft(query: text, describesNeed: true)
        loadViewIfNeeded()
        query.string = text; mode.selectedSegment = 1; aiResult = nil
        status.stringValue = L("Review your request, then choose Find with AI.")
        status.textColor = .secondaryLabelColor
        updateControls(); render()
        view.window?.makeFirstResponder(query)
    }

    func prepareForTermination() { stopOperation(showStatus: false) }

    func textDidChange(_ notification: Notification) {
        aiResult = nil
        let invalid = !query.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? DiscoveryQuery.validate(query.string)) == nil
        status.stringValue = invalid ? L("Describe what you need using at most 2,000 characters.") : ""
        status.textColor = invalid ? .systemRed : .secondaryLabelColor
        updateControls(); render()
    }

    @objc private func changeSearchMode() { aiResult = nil; status.stringValue = ""; updateControls(); render() }
    @objc private func refreshDescriptions() { loadDescriptions(refresh: true) }
    @objc private func findWithAI() {
        guard !isBusy, let input = try? DiscoveryQuery.validate(query.string) else { return }
        mode.selectedSegment = 1
        let ticket = UUID(); generation = ticket
        aiResult = nil; setBusy(true)
        status.stringValue = L("Understanding your request…"); status.textColor = .secondaryLabelColor
        render()
        let language = AppLocalization.shared.resolvedLanguage
        let services = self.services
        operation = Task { [weak self] in
            do {
                let result = try await services.search(input, language, { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == ticket else { return }
                        self.status.stringValue = L(message)
                    }
                })
                try Task.checkCancellation()
                let current = try await services.load(false)
                guard let self, self.generation == ticket else { return }
                self.snapshot = current
                guard current.index.revision == result.revision else {
                    self.aiResult = nil; self.finishOperation()
                    self.status.stringValue = L("The catalog changed. Search again.")
                    self.status.textColor = .secondaryLabelColor
                    self.render(); return
                }
                self.aiResult = result; self.finishOperation()
                self.status.stringValue = result.model.isEmpty ? L("Descriptions are up to date.") : L("Matched with %@", result.model)
                self.status.textColor = .secondaryLabelColor
                self.render()
            } catch {
                guard let self, self.generation == ticket else { return }
                self.finishOperation()
                self.status.stringValue = error is CancellationError ? L("Search cancelled.") : L("Search could not finish: %@", L(error.localizedDescription))
                self.status.textColor = error is CancellationError ? .secondaryLabelColor : .systemRed
                self.render()
            }
        }
    }

    @objc private func cancelSearch() { stopOperation(showStatus: true) }
    private func stopOperation(showStatus: Bool) {
        let ticket = UUID(); generation = ticket
        let previous = operation; previous?.cancel(); operation = nil
        let cancel = services.cancel
        // Keep the form disabled until the old provider is disconnected. A new
        // search must never be cancelled by the previous search's cleanup.
        Task { [weak self] in
            await cancel()
            await previous?.value
            guard let self, self.generation == ticket else { return }
            self.setBusy(false)
            if showStatus { self.status.stringValue = L("Search cancelled."); self.status.textColor = .secondaryLabelColor }
        }
    }

    private func loadDescriptions(refresh: Bool) {
        guard !isBusy else { return }
        let ticket = UUID(); generation = ticket; setBusy(true)
        status.stringValue = L("Updating tool catalog…"); status.textColor = .secondaryLabelColor
        let load = services.load
        operation = Task { [weak self] in
            do {
                let value = try await load(refresh)
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                self.snapshot = value; self.aiResult = nil; self.finishOperation()
                self.status.stringValue = value.stale ? L("Using saved descriptions; refresh when online.") : L("Descriptions are up to date.")
                self.status.textColor = .secondaryLabelColor
                self.render()
            } catch {
                guard let self, self.generation == ticket else { return }
                self.finishOperation()
                self.status.stringValue = error is CancellationError ? L("Search cancelled.") : L("Descriptions could not be loaded: %@", L(error.localizedDescription))
                self.status.textColor = error is CancellationError ? .secondaryLabelColor : .systemRed
                self.render()
            }
        }
    }

    private func finishOperation() { operation = nil; setBusy(false) }
    private func setBusy(_ value: Bool) {
        isBusy = value
        if isViewLoaded { if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }; updateControls() }
    }
    private func updateControls() {
        let describesNeed = mode.selectedSegment == 1
        query.placeholder = describesNeed ? L("For example: Help me write professional replies to clients on Upwork.") : L("Search names, descriptions, or keywords…")
        query.isEditable = !isBusy; mode.isEnabled = !isBusy; refreshButton.isEnabled = !isBusy
        searchButton.isHidden = !describesNeed
        searchButton.isEnabled = !isBusy && !query.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? DiscoveryQuery.validate(query.string)) != nil
        cancelButton.isHidden = !isBusy
    }

    private func render() {
        guard isViewLoaded else { return }
        results.arrangedSubviews.forEach { results.removeArrangedSubview($0); $0.removeFromSuperview() }
        examples.arrangedSubviews.forEach { examples.removeArrangedSubview($0); $0.removeFromSuperview() }
        examplesByButton.removeAll(); detailsByButton.removeAll()
        guard let snapshot else {
            resultCount.stringValue = ""
            if !isBusy { add(label(L("Refresh descriptions to browse available tools."), size: 13, color: .secondaryLabelColor), to: results) }
            return
        }
        let language = AppLocalization.shared.resolvedLanguage
        catalogStatus.stringValue = L("%ld tools · Updated %@", snapshot.index.extensions.count, formattedDate(snapshot.index.updatedAt))
        if snapshot.stale || aiResult?.stale == true { catalogStatus.stringValue += "\n" + L("Using saved descriptions; refresh when online.") }
        if mode.selectedSegment == 1, aiResult == nil {
            for text in Array(snapshot.index.extensions.flatMap(\.exampleQueries).prefix(3)) {
                let owner = snapshot.index.extensions.first { $0.exampleQueries.contains(text) }
                let button = NSButton(title: owner?.localized(text, language: language) ?? text, target: self, action: #selector(useExample(_:)))
                button.bezelStyle = .inline; button.lineBreakMode = .byTruncatingTail
                examplesByButton[ObjectIdentifier(button)] = text
                examples.addArrangedSubview(button)
                button.widthAnchor.constraint(lessThanOrEqualTo: examples.widthAnchor).isActive = true
            }
        }
        if let aiResult {
            let entries = Dictionary(uniqueKeysWithValues: snapshot.index.extensions.map { ($0.id, $0) })
            let matches = aiResult.matches.compactMap { match -> (DiscoveryEntry, DiscoveryMatch)? in
                guard let entry = entries[match.id] else { return nil }; return (entry, match)
            }
            resultCount.stringValue = L("%ld matching tools", matches.count)
            if matches.isEmpty {
                add(label(L("No suitable extension was found."), size: 15, weight: .semibold), to: results)
                if let reason = aiResult.noMatchReason, !reason.isEmpty { add(label(L(reason), size: 13, color: .secondaryLabelColor), to: results) }
            }
            for (entry, match) in matches { add(makeCard(entry, reason: match.reason, fit: match.fit), to: results) }
        } else if mode.selectedSegment == 0 {
            let entries = DiscoveryKeywordSearch.search(query: query.string, in: snapshot.index, language: language)
            resultCount.stringValue = L("%ld matching tools", entries.count)
            if entries.isEmpty { add(label(L("No tools match these keywords."), size: 13, color: .secondaryLabelColor), to: results) }
            for entry in entries.prefix(100) { add(makeCard(entry, reason: nil, fit: nil), to: results) }
            if entries.count > 100 { add(label(L("Showing the first 100 tools. Refine your search to see more."), size: 12, color: .secondaryLabelColor), to: results) }
        } else {
            resultCount.stringValue = L("Describe a task to find a tool")
        }
        applyAppLanguageDirection(to: results)
    }

    @objc private func useExample(_ sender: NSButton) {
        guard let text = examplesByButton[ObjectIdentifier(sender)], !isBusy else { return }
        let language = AppLocalization.shared.resolvedLanguage
        let owner = snapshot?.index.extensions.first { $0.exampleQueries.contains(text) }
        query.string = owner?.localized(text, language: language) ?? text
        aiResult = nil; status.stringValue = L("Review your request, then choose Find with AI.")
        updateControls(); render(); view.window?.makeFirstResponder(query)
    }

    private func makeCard(_ entry: DiscoveryEntry, reason: String?, fit: String?) -> NSView {
        let language = AppLocalization.shared.resolvedLanguage
        let box = NSBox(); box.boxType = .custom; box.borderWidth = 1
        box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor; box.cornerRadius = 10
        box.contentViewMargins = NSSize(width: 16, height: 15)
        box.identifier = NSUserInterfaceItemIdentifier("discovery-result-" + entry.id)
        let body = column(spacing: 9)
        guard let content = box.contentView else { return box }
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor), body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: content.topAnchor), body.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let identity = NSStackView(views: [label(entry.name, size: 16, weight: .semibold), flexibleSpace(), label(entry.version, size: 11, color: .secondaryLabelColor)])
        identity.alignment = .centerY; identity.spacing = 8; add(identity, to: body)
        add(label(entry.localized(entry.summary, language: language), size: 13, color: .secondaryLabelColor), to: body)
        if let reason {
            add(label(fit == "partial" ? L("Partial match") : L("Good match"), size: 11, weight: .semibold, color: .controlAccentColor), to: body)
            add(label(reason, size: 13), to: body)
        }
        if !entry.limitations.isEmpty {
            let text = entry.limitations.prefix(3).map { "• " + entry.localized($0, language: language) }.joined(separator: "\n")
            add(label(L("Limitations"), size: 11, weight: .semibold), to: body)
            add(label(text, size: 12, color: .secondaryLabelColor), to: body)
        }
        let platforms = label(entry.platforms.joined(separator: " · "), size: 11, color: .secondaryLabelColor)
        let button = NSButton(title: L("Open details"), target: self, action: #selector(showDetails(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("discovery-details-" + entry.id)
        do {
            let base = try marketplaceURL()
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.fragment = "extension/" + entry.slug
            if let url = components?.url { detailsByButton[ObjectIdentifier(button)] = url }
            else { button.isEnabled = false }
        } catch { button.isEnabled = false }
        let footer = NSStackView(views: [platforms, flexibleSpace(), button]); footer.alignment = .centerY; footer.spacing = 10
        add(footer, to: body)
        return box
    }

    @objc private func showDetails(_ sender: NSButton) {
        guard let url = detailsByButton[ObjectIdentifier(sender)] else { return }
        if !openDetails(url) { status.stringValue = L("The marketplace could not be opened in your browser. Try again after checking your default browser."); status.textColor = .systemRed }
    }

    private func formattedDate(_ source: String) -> String {
        let parser = ISO8601DateFormatter()
        var parsed = parser.date(from: source)
        if parsed == nil { parser.formatOptions.insert(.withFractionalSeconds); parsed = parser.date(from: source) }
        guard let date = parsed else { return source }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: AppLocalization.shared.resolvedLanguage)
        formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        return label
    }
    private func column(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = spacing; stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    private func flexibleSpace() -> NSView { let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .horizontal); return space }
    private func add(_ child: NSView, to stack: NSStackView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

private final class DiscoveryDocumentView: NSView { override var isFlipped: Bool { true } }

private final class DiscoveryQueryTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    override var string: String { didSet { needsDisplay = true } }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(in: bounds.insetBy(dx: textContainerInset.width + 3, dy: textContainerInset.height), withAttributes: attributes)
    }
}
