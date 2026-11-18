import AppKit
import ApplicationServices
import Foundation
import MacHelper
import MacHelperCapabilities

struct SourceToolInfo {
    let id: String
    let displayName: String
    let summary: String
    let version: String
    let runtime: String
    let isEnabled: Bool
    let isRunning: Bool
    let sourceURL: URL?
    let isLocallyModified: Bool
    let reloadCount: Int
    let error: String?
    let status: String
}

@MainActor
final class SourceExtensionManager {
    static let translationID = "com.localaibasetools.translation"
    var onChange: (() -> Void)?
    var onApproveNativeExecution: ((SourceExtensionManifest) -> Bool)?
    var onApproveSelectionReplacement: ((SourceExtensionManifest) -> Bool)?
    var onApproveSelectionPaste: ((SourceExtensionManifest) -> Bool)?
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    private let store: SourcePackageStore
    private let stateDirectory: URL
    private let bundledCatalogURL: URL
    private let bundledSeedDirectory: URL?
    private let workerURL: URL
    private let helperURL: URL
    private let nativeSDKURL: URL
    private let headless: Bool
    private let testTransform: (([String: Any]) async throws -> [String: Any])?
    private let testStreamingTransform: (([String: Any], @escaping @MainActor ([String: Any]) -> Void) async throws -> [String: Any])?
    private var definitions: [String: Definition] = [:]
    private var snapshots: [String: SourcePackageSnapshot] = [:]
    private var preparedSettings: [String: PreparedSettings] = [:]
    private var configurationErrors: [String: String] = [:]
    private var active: [String: Running] = [:]
    private var pending: [String: ScriptWorkerClient] = [:]
    private var watchers: [String: SourceFileWatcher] = [:]
    private var reloadTasks: [String: Task<Void, Never>] = [:]
    private var epochs: [String: UUID] = [:]
    private var errors: [String: String] = [:]
    private var statuses: [String: String] = [:]
    private var counts: [String: Int] = [:]
    private var state = State()
    private var shuttingDown = false
    private var started = false
    private lazy var selectionCapability = SelectionActionCapability(title: "MacHelper")
    private var languageObserver: NSObjectProtocol?

    private struct State: Codable {
        var schemaVersion = 1
        var enabled: [String: Bool] = [:]
        var permissions: [String: [String]] = [:]
        var catalogs: [String] = []
    }
    private struct Definition { let entry: SourceCatalogEntry; let base: URL }
    private struct PreparedSettings {
        let snapshot: SourcePackageSnapshot
        let schema: ScriptSettingsSchema?
        var values: [String: Any]
    }
    private final class Gate { var invoking = false; var calls = 0; var model: String? }
    private final class Running {
        /// Stable for this validated source/settings activation. A crashed IPC
        /// process can recover inside it; source/settings reload creates a new
        /// Running and therefore a new toolbar authority.
        let activationGeneration = UUID().uuidString
        var snapshot: SourcePackageSnapshot
        var worker: ScriptWorkerClient
        var gate: Gate
        var schema: ScriptSettingsSchema?
        var settings: [String: Any]
        var actionInProgress = false
        init(snapshot: SourcePackageSnapshot, worker: ScriptWorkerClient, gate: Gate,
             schema: ScriptSettingsSchema?, settings: [String: Any]) {
            self.snapshot = snapshot; self.worker = worker; self.gate = gate
            self.schema = schema; self.settings = settings
        }
    }

    init(workerExecutableURL: URL, helperExecutableURL: URL, bundledCatalogURL: URL,
         bundledSeedDirectory: URL? = nil, stateDirectory: URL? = nil, nativeSDKURL: URL? = nil,
         sourceDirectory: URL = SourcePackageStore.defaultUserDirectory, headless: Bool = false,
         testTransform: (([String: Any]) async throws -> [String: Any])? = nil,
         testStreamingTransform: (([String: Any], @escaping @MainActor ([String: Any]) -> Void) async throws -> [String: Any])? = nil) {
        workerURL = workerExecutableURL; helperURL = helperExecutableURL
        self.bundledCatalogURL = bundledCatalogURL; self.bundledSeedDirectory = bundledSeedDirectory
        self.stateDirectory = stateDirectory ?? HelperSettingsStore.defaultFileURL.deletingLastPathComponent()
        self.nativeSDKURL = nativeSDKURL ?? Bundle.main.resourceURL?.appendingPathComponent("NativeExtensionSDK/MacHelperNativeSDK.swift")
            ?? URL(fileURLWithPath: "/unavailable/MacHelperNativeSDK.swift")
        self.headless = headless; self.testTransform = testTransform; self.testStreamingTransform = testStreamingTransform
        store = SourcePackageStore(directory: sourceDirectory)
        languageObserver = NotificationCenter.default.addObserver(forName: .macHelperLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeSelectionActions(invalidateCurrent: true) }
        }
    }

    var tools: [SourceToolInfo] {
        Set(definitions.keys).union(snapshots.keys).union(state.enabled.keys).sorted().map { id in
            let snapshot = snapshots[id] ?? active[id]?.snapshot
            let definition = definitions[id]?.entry
            let exists = (try? store.installedURL(for: id)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return SourceToolInfo(id: id, displayName: localizedText(snapshot?.manifest.displayName ?? definition?.displayName ?? id, for: id),
                                  summary: localizedText(snapshot?.manifest.summary ?? definition?.summary ?? L("Editable source extension"), for: id),
                                  version: snapshot?.manifest.version ?? definition?.version ?? "",
                                  runtime: snapshot?.manifest.runtime ?? "",
                                  isEnabled: state.enabled[id] == true, isRunning: active[id]?.worker.generation != nil,
                                  sourceURL: exists ? try? store.installedURL(for: id) : nil,
                                  isLocallyModified: snapshot?.isLocallyModified ?? false, reloadCount: counts[id] ?? 0,
                                  error: errors[id] ?? configurationErrors[id], status: L(statuses[id] ?? (exists ? "Source installed locally." : "Enable to download the complete source.")))
        }
    }

    func start() async {
        guard !started else { return }; started = true
        let file = stateURL
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                guard state.schemaVersion == 1 else { throw SourcePackageError.invalid(L("Unsupported extension preferences.")) }
                guard state.enabled.count <= 128, state.permissions.count <= 128, state.catalogs.count <= 32 else {
                    throw SourcePackageError.invalid(L("Extension preferences exceed their size limits."))
                }
                for id in Set(state.enabled.keys).union(state.permissions.keys) { try SourcePackageRules.validateIdentifier(id) }
            } catch { state = State(); errors[Self.translationID] = L("Source extension preferences could not be read. Enable the tool explicitly.") }
        } else if !headless {
            // Translation was enabled by default in MacHelper 3. Preserve that
            // existing choice; other catalog tools remain disabled until chosen.
            let legacy = stateDirectory.appendingPathComponent("extensions.json")
            let object = (try? Data(contentsOf: legacy)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let enabled = object?["enabled"] as? [String: Bool]
            if let previousChoice = enabled?[Self.translationID] {
                state.enabled[Self.translationID] = previousChoice
            } else if FileManager.default.fileExists(atPath: settingsURL(Self.translationID).path) {
                state.enabled[Self.translationID] = true
            }
        }
        do { try await readCatalog(bundledCatalogURL) } catch { errors[Self.translationID] = error.localizedDescription }
        for text in state.catalogs { if let url = URL(string: text) { try? await readCatalog(url) } }
        let discovered = store.discoverInstalled()
        for snapshot in discovered.packages { snapshots[snapshot.manifest.identifier] = snapshot }
        for issue in discovered.issues { if let id = issue.identifier { errors[id] = issue.message } }
        for (id, enabled) in state.enabled where enabled {
            do { try await activate(id, approving: state.permissions[id] == nil) }
            catch { errors[id] = error.localizedDescription; try? await recoverLastGood(id) }
        }
        notify()
    }

    func setEnabled(_ enabled: Bool, for id: String) async throws {
        guard !shuttingDown else { throw CancellationError() }
        if enabled {
            try await activate(id, approving: true)
        } else {
            state.enabled[id] = false
            try saveState()
            await stop(id)
            if state.enabled[id] == false { statuses[id] = "Disabled. Your editable source and settings are retained." }
        }
        notify()
    }

    func reload(_ id: String) async throws {
        guard state.enabled[id] == true else { throw SourcePackageError.invalid(L("Enable this extension before reloading it.")) }
        do { try await activate(id, approving: false) }
        catch {
            if !(error is CancellationError), state.enabled[id] == true, !shuttingDown {
                errors[id] = L("Reload failed; the last working version remains active. %@", error.localizedDescription); notify()
            }
            throw error
        }
    }

    func sourceURL(for id: String) -> URL? {
        guard let url = try? store.installedURL(for: id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    /// Reading a settings form never starts code, grants permissions, downloads
    /// source, or enables a tool. Running tools keep the schema belonging to
    /// their validated generation until the ordinary reloader replaces it.
    func prepareSettings(for id: String) async throws {
        guard !shuttingDown else { throw CancellationError() }
        try SourcePackageRules.validateIdentifier(id)
        do {
            let (snapshot, configuration) = try readSettingsSource(for: id)
            if active[id] == nil {
                snapshots[id] = snapshot
                preparedSettings[id] = configuration
            }
            configurationErrors.removeValue(forKey: id)
            notify()
        } catch {
            // A broken local edit must remain on disk. A previously validated
            // form may still be displayed, but saving always rereads the local
            // schema and refuses invalid source instead of silently using it.
            if active[id] == nil, preparedSettings[id] == nil,
               let cached = try? SourcePackageInspector.snapshot(at: cacheURL(id)),
               cached.manifest.identifier == id,
               Set(cached.manifest.permissions).isSubset(of: Set(state.permissions[id] ?? [])),
               let configuration = try? settingsConfiguration(cached, id: id) {
                preparedSettings[id] = configuration
            }
            configurationErrors[id] = L("Settings could not be read from the local source. %@", error.localizedDescription)
            notify()
            throw error
        }
    }

    func localizedText(_ text: String, for id: String) -> String {
        let snapshot = active[id]?.snapshot ?? preparedSettings[id]?.snapshot ?? snapshots[id]
        return snapshot?.localizations?.text(text, language: AppLocalization.shared.resolvedLanguage) ?? text
    }

    func settingsSchema(for id: String) -> ScriptSettingsSchema? {
        if let runtime = active[id] { return runtime.schema }
        return preparedSettings[id]?.schema
    }
    func settings(for id: String) -> [String: Any] { active[id]?.settings ?? preparedSettings[id]?.values ?? [:] }
    func promptValue(_ key: String, for id: String) throws -> String {
        guard let snapshot = active[id]?.snapshot ?? preparedSettings[id]?.snapshot,
              let schema = settingsSchema(for: id) else {
            throw SourcePackageError.invalid(L("Load this extension's validated source before editing a prompt."))
        }
        let path = try schema.promptPath(for: key)
        guard let value = snapshot.resources[path] else { throw SourcePackageError.invalid(L("The declared prompt resource is unavailable.")) }
        try ScriptPromptResource.validate(value)
        return value
    }
    func permissions(for id: String) -> [String] {
        active[id]?.snapshot.manifest.permissions ?? snapshots[id]?.manifest.permissions ?? []
    }
    /// Permission discovery reads validated source only; it never builds or runs
    /// disabled native code. Catalog installations use their manifest review.
    func requiresNativeApproval(for id: String) -> Bool {
        guard let snapshot = try? store.snapshot(for: id), snapshot.manifest.runtime == "native" else { return false }
        return !(state.permissions[id] ?? []).contains("native.execute")
    }

    func updateSetting(_ key: String, value: Any, for id: String) async throws {
        guard !shuttingDown else { throw CancellationError() }
        if let runtime = active[id] {
            guard let schema = runtime.schema else { throw SourcePackageError.invalid(L("This tool has no additional settings.")) }
            try schema.validate(value, for: key)
            var values = runtime.settings; values[key] = value
            try saveSettings(values, id: id)
            runtime.settings = values
            try await reload(id)
        } else {
            // Do not reuse a stale form after a disabled tool's source changed.
            // This synchronous read/validate/write cannot interleave with an
            // enable, and deliberately does not touch enabled/permission state.
            let (snapshot, configuration) = try readSettingsSource(for: id)
            guard let schema = configuration.schema else { throw SourcePackageError.invalid(L("This tool has no additional settings.")) }
            try schema.validate(value, for: key)
            var values = configuration.values; values[key] = value
            try saveSettings(values, id: id)
            snapshots[id] = snapshot
            preparedSettings[id] = PreparedSettings(snapshot: snapshot, schema: schema, values: values)
            configurationErrors.removeValue(forKey: id)
            notify()
        }
    }

    func updatePrompt(_ key: String, value: String, expectedValue: String, for id: String) async throws {
        guard !shuttingDown else { throw CancellationError() }
        let (snapshot, configuration) = try readSettingsSource(for: id)
        guard let displayed = active[id]?.snapshot ?? preparedSettings[id]?.snapshot,
              displayed.fingerprint == snapshot.fingerprint else {
            throw SourcePackageError.invalid(L("The extension source changed since this editor was loaded. Revert to the current source before saving again."))
        }
        let updated = try ScriptPromptResource.replace(in: snapshot, key: key, value: value, expectedValue: expectedValue)
        if active[id] != nil {
            // Avoid a competing watcher reload superseding the explicit save's
            // generation. The normal activator restores watching on success.
            reloadTasks.removeValue(forKey: id)?.cancel()
            watchers.removeValue(forKey: id)?.stop()
            defer { if state.enabled[id] == true { watch(id) } }
            try await reload(id)
        } else {
            snapshots[id] = updated
            preparedSettings[id] = PreparedSettings(snapshot: updated, schema: configuration.schema, values: configuration.values)
            configurationErrors.removeValue(forKey: id)
            notify()
        }
    }

    func importSource(from url: URL) async throws {
        let snapshot = try store.importSource(from: url)
        snapshots[snapshot.manifest.identifier] = snapshot
        statuses[snapshot.manifest.identifier] = "Complete source installed. Enable to run it."
        notify()
    }
    func addCatalog(from url: URL) async throws {
        try await readCatalog(url)
        if !state.catalogs.contains(url.absoluteString) { state.catalogs.append(url.absoluteString); try saveState() }
        notify()
    }

    func previewMarketplaceInstall(_ request: MarketplaceInstallRequest) async throws -> MarketplaceInstallPreview {
        guard !shuttingDown else { throw CancellationError() }
        return try await MarketplaceReviewLoader.load(request)
    }

    /// Called only after the native review's explicit Install & Enable action.
    /// Existing editable copies retain their files, enabled state, and settings.
    @discardableResult
    func installReviewedMarketplaceTool(_ preview: MarketplaceInstallPreview) async throws -> Bool {
        guard !shuttingDown, !Task.isCancelled else { throw CancellationError() }
        let id = preview.request.extensionID
        guard sourceURL(for: id) == nil else { return false }
        let catalog = preview.request.catalogURL.absoluteString
        guard state.catalogs.contains(catalog) || state.catalogs.count < 32 else {
            throw MarketplaceError.invalidLink(L("Too many tool catalogs are configured. Remove an unused catalog before installing another."))
        }
        definitions[id] = Definition(entry: preview.entry, base: preview.request.catalogURL)
        do {
            try await activate(id, approving: true,
                expectedFileHashes: Dictionary(uniqueKeysWithValues: preview.entry.files.map { ($0.path, $0.sha256.lowercased()) }))
        } catch MarketplaceError.existingSourceChanged { notify(); return false }
        if !state.catalogs.contains(catalog) { state.catalogs.append(catalog); try saveState() }
        notify()
        return true
    }

    func stopAll() async {
        shuttingDown = true
        epochs.removeAll()
        reloadTasks.values.forEach { $0.cancel() }; reloadTasks.removeAll()
        watchers.values.forEach { $0.stop() }; watchers.removeAll()
        if !headless { selectionCapability.stop() }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver); self.languageObserver = nil }
        let workers = active.values.map(\.worker) + Array(pending.values)
        active.removeAll(); pending.removeAll()
        for worker in workers { await worker.stop() }
    }

    // Also used by the isolated integration harness with a fake AI callback.
    func performCommand(for id: String, text: String, sentence: String? = nil, commandIdentifier: String? = nil,
                        onProgress: (@MainActor (CapabilityTranslationResult) -> Void)? = nil) async throws -> CapabilityTranslationResult {
        guard state.enabled[id] == true, let runtime = active[id], !shuttingDown else {
            throw SourcePackageError.invalid(L("This extension is disabled."))
        }
        guard !runtime.actionInProgress else { throw SourcePackageError.invalid(L("This extension is already processing an action.")) }
        var input: [String: Any] = ["text": text, "settings": runtime.settings]
        if let sentence {
            let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard runtime.snapshot.manifest.permissions.contains("selection.read"),
                  !selected.isEmpty, sentence.utf16.count <= 2_000, sentence.utf8.count <= 8_000,
                  !sentence.contains("\0"), sentence.contains(selected) else {
                throw SourcePackageError.invalid(L("The surrounding sentence is unavailable or invalid."))
            }
            input["sentence"] = sentence
        }
        runtime.actionInProgress = true
        defer { runtime.actionInProgress = false }
        if runtime.worker.generation == nil { try await replaceWorker(runtime) }
        try Task.checkCancellation()
        guard active[id] === runtime, state.enabled[id] == true, !shuttingDown else { throw CancellationError() }
        let command = commandIdentifier.flatMap { id in runtime.snapshot.manifest.commands.first { $0.identifier == id } }
            ?? (commandIdentifier == nil ? runtime.snapshot.manifest.commands.first : nil)
        guard let command else { throw SourcePackageError.invalid(L("This extension has no command.")) }
        let worker = runtime.worker, gate = runtime.gate
        gate.invoking = true; gate.calls = 0; gate.model = nil
        defer { gate.invoking = false }
        let result = try await worker.invoke(command: command.identifier, input: input) { [weak self, weak runtime] update in
            guard let self, let runtime, !Task.isCancelled, self.active[id] === runtime,
                  runtime.worker === worker, self.state.enabled[id] == true, gate.invoking,
                  let output = update["text"] as? String, !output.isEmpty, output.utf8.count <= 96_000,
                  !output.contains("\0") else { return }
            onProgress?(CapabilityTranslationResult(text: output, model: gate.model,
                title: (update["title"] as? String).map { String($0.prefix(120)) }))
        }
        try Task.checkCancellation()
        guard active[id] === runtime, runtime.worker === worker, state.enabled[id] == true,
              let output = result["text"] as? String, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.utf8.count <= 96_000 else { throw SourcePackageError.invalid(L("The extension returned an invalid or stale result.")) }
        return CapabilityTranslationResult(text: output, model: gate.model,
                                           title: (result["title"] as? String).map { String($0.prefix(120)) })
    }

    func workerPID(for id: String) -> Int32? { active[id]?.worker.processIdentifier }
    func activationGeneration(for id: String) -> String? { active[id]?.activationGeneration }

    private var stateURL: URL { stateDirectory.appendingPathComponent("source-extensions.json") }
    private func settingsURL(_ id: String) -> URL {
        stateDirectory.appendingPathComponent("ExtensionSettings/" + id + "/settings.json")
    }
    private func cacheURL(_ id: String) -> URL { stateDirectory.appendingPathComponent("SourceCache/" + id + ".macsource", isDirectory: true) }

    private func readCatalog(_ url: URL) async throws {
        let catalog = try await SourceCatalogLoader.load(from: url)
        for entry in catalog.extensions where definitions[entry.identifier] == nil {
            definitions[entry.identifier] = Definition(entry: entry, base: url)
        }
    }

    private func activate(_ id: String, approving: Bool, expectedFileHashes: [String: String]? = nil) async throws {
        let epoch = UUID(); epochs[id] = epoch
        statuses[id] = sourceURL(for: id) == nil ? "Downloading complete extension source…" : "Validating source…"
        notify()
        let snapshot: SourcePackageSnapshot
        do {
            if let definition = definitions[id] {
                do { snapshot = try await store.materialize(entry: definition.entry, baseURL: definition.base) }
                catch {
                    // The bundled first-party source seed supports offline first
                    // launch. Remote marketplace packages have no implicit seed.
                    guard definition.base == bundledCatalogURL, sourceURL(for: id) == nil,
                          let seeds = bundledSeedDirectory else { throw error }
                    let candidate = seeds.appendingPathComponent(id + ".macsource", isDirectory: true)
                    // Retain compatibility with the old Translation-only seed.
                    let seed = FileManager.default.fileExists(atPath: candidate.appendingPathComponent("extension.json").path)
                        ? candidate : seeds
                    guard let verified = try? SourcePackageInspector.snapshot(at: seed), verified.manifest.identifier == id else { throw error }
                    snapshot = try store.importSource(from: seed)
                }
            } else { snapshot = try store.snapshot(for: id) }
            guard epochs[id] == epoch, !shuttingDown else { throw CancellationError() }
            if let expectedFileHashes, snapshot.fileHashes != expectedFileHashes { throw MarketplaceError.existingSourceChanged }
            snapshots[id] = snapshot
            let approved = state.permissions[id]
            guard approving || approved.map({ Set(snapshot.manifest.permissions).isSubset(of: Set($0)) }) == true else {
                throw SourcePackageError.invalid(L("This edit requests new permissions. Disable and re-enable the extension to approve them."))
            }
            if snapshot.manifest.runtime == "native", !(approved ?? []).contains("native.execute"), !headless {
                guard approving, onApproveNativeExecution?(snapshot.manifest) == true else {
                    statuses[id] = active[id] == nil
                        ? "Native execution was not approved. The extension remains disabled."
                        : "Running the last working version; native execution was not approved."
                    notify()
                    throw CancellationError()
                }
                guard epochs[id] == epoch, !shuttingDown else { throw CancellationError() }
            }
            if !headless, let review = SourceSelectionPermissionReview.required(requested: snapshot.manifest.permissions, approved: approved ?? []) {
                guard approving else { throw CancellationError() }
                switch review {
                case .paste: guard onApproveSelectionPaste?(snapshot.manifest) == true else { throw CancellationError() }
                case .replacement: guard onApproveSelectionReplacement?(snapshot.manifest) == true else { throw CancellationError() }
                }
                guard epochs[id] == epoch, !shuttingDown else { throw CancellationError() }
            }
            let schema = try parseSchema(snapshot)
            let values = try loadSettings(id, schema: schema)
            let (worker, gate) = try await makeWorker(snapshot: snapshot, settings: values, epoch: epoch)
            guard epochs[id] == epoch, !shuttingDown, !Task.isCancelled else { await worker.stop(); throw CancellationError() }
            let old = active[id]
            let runtime = Running(snapshot: snapshot, worker: worker, gate: gate, schema: schema, settings: values)
            active[id] = runtime
            preparedSettings[id] = PreparedSettings(snapshot: snapshot, schema: schema, values: values)
            configurationErrors.removeValue(forKey: id)
            if pending[id] === worker { pending.removeValue(forKey: id) }
            state.enabled[id] = true
            if approving { state.permissions[id] = snapshot.manifest.permissions }
            synchronizeSelectionActions()
            if let old { await old.worker.stop() }
            guard epochs[id] == epoch, active[id] === runtime, !shuttingDown else { throw CancellationError() }
            counts[id, default: 0] += 1
            statuses[id] = "Running · watching local source for changes."
            errors.removeValue(forKey: id)
            try saveState()
            try saveSettings(values, id: id)
            try? saveLastGood(snapshot, id: id)
            watch(id)
            notify()
        } catch {
            if epochs[id] == epoch, !shuttingDown, !(error is CancellationError),
               (error as? MarketplaceError) != .existingSourceChanged {
                statuses[id] = active[id] == nil ? "Not running." : "Running the last working version."
                errors[id] = error.localizedDescription
                notify()
            }
            throw error
        }
    }

    private func makeWorker(snapshot: SourcePackageSnapshot, settings: [String: Any], epoch: UUID?) async throws -> (ScriptWorkerClient, Gate) {
        let id = snapshot.manifest.identifier
        let executable: URL
        if snapshot.manifest.runtime == "native" {
            statuses[id] = "Building native extension…"; notify()
            let builder = NativeSourceBuilder(sdkURL: nativeSDKURL,
                cacheDirectory: stateDirectory.appendingPathComponent("NativeBuildCache", isDirectory: true))
            executable = try await builder.build(snapshot: snapshot)
        } else { executable = workerURL }
        try Task.checkCancellation()
        guard epochs[id] == epoch, !shuttingDown else { throw CancellationError() }
        let worker = ScriptWorkerClient(executableURL: executable), gate = Gate()
        pending[id] = worker
        do {
            let commands = try await worker.load(entrySource: snapshot.entrySource, resources: snapshot.resources,
                settings: settings, permissions: snapshot.manifest.permissions,
                streamingCapabilityHandler: { [weak self, weak gate] payload, onProgress in
                    guard let self, let gate else { throw CancellationError() }
                    return try await self.transform(payload, snapshot: snapshot, gate: gate, onProgress: onProgress)
                }, capabilityHandler: { [weak self, weak gate] payload in
                    guard let self, let gate else { throw CancellationError() }
                    return try await self.transform(payload, snapshot: snapshot, gate: gate, onProgress: nil)
                })
            guard snapshot.manifest.commands.allSatisfy({ commands.contains($0.identifier) }) else {
                throw SourcePackageError.invalid(L("The source does not implement every command declared by its manifest."))
            }
            try Task.checkCancellation()
            guard epochs[id] == epoch, !shuttingDown else { throw CancellationError() }
            return (worker, gate)
        } catch {
            if pending[id] === worker { pending.removeValue(forKey: id) }
            await worker.stop()
            throw error
        }
    }

    private func transform(_ payload: [String: Any], snapshot: SourcePackageSnapshot, gate: Gate,
                           onProgress: (@MainActor ([String: Any]) -> Void)?) async throws -> [String: Any] {
        guard gate.invoking, !shuttingDown, snapshot.manifest.permissions.contains("ai.transform") else {
            throw SourcePackageError.invalid(L("AI requests require an explicit current tool action."))
        }
        gate.calls += 1
        guard gate.calls <= 8 else { throw SourcePackageError.invalid(L("This tool exceeded the AI calls allowed for one action.")) }
        if let test = testStreamingTransform, let onProgress {
            let result = try await test(payload) { update in
                guard gate.invoking, !Task.isCancelled else { return }
                if let model = update["model"] as? String { gate.model = model }
                onProgress(update)
            }
            gate.model = result["model"] as? String
            return result
        }
        if let test = testTransform {
            let result = try await test(payload); gate.model = result["model"] as? String; return result
        }
        let action = payload["action"] as? String ?? "translate"
        guard ["translate", "polish"].contains(action), let text = payload["text"] as? String else {
            throw SourcePackageError.invalid(L("The extension requested an unsupported AI transformation."))
        }
        let request = try CapabilityAIRequest(action: action, text: text,
            targetLanguage: payload["targetLanguage"] as? String, tone: payload["tone"] as? String,
            model: payload["model"] as? String ?? "", guidance: payload["guidance"] as? String,
            systemPrompt: payload["systemPrompt"] as? String)
        let client = NativeHelperTransformClient(executableURL: helperURL)
        let response: CapabilityAIResponse
        if let onProgress {
            // A single consumer preserves delta order and drains every queued
            // update before the terminal result can mark the panel complete.
            let channel = AsyncStream<(String, String?)>.makeStream()
            let pump = Task { @MainActor in
                var text = ""
                for await (delta, model) in channel.stream {
                    guard !Task.isCancelled, gate.invoking, !self.shuttingDown else { break }
                    text += delta
                    if let model { gate.model = model }
                    onProgress(["text": text, "delta": delta, "model": gate.model as Any? ?? NSNull()])
                }
            }
            defer { channel.continuation.finish(); pump.cancel() }
            response = try await client.transform(request) { delta, model in
                channel.continuation.yield((delta, model))
            }
            channel.continuation.finish()
            await pump.value
        } else { response = try await client.transform(request) }
        try Task.checkCancellation()
        gate.model = response.model
        return ["text": response.text ?? "", "model": response.model as Any? ?? NSNull()]
    }

    private func replaceWorker(_ runtime: Running) async throws {
        let id = runtime.snapshot.manifest.identifier
        let epoch = epochs[id]
        let (worker, gate) = try await makeWorker(snapshot: runtime.snapshot, settings: runtime.settings, epoch: epoch)
        guard active[id] === runtime, state.enabled[id] == true, !shuttingDown, epochs[id] == epoch else {
            if pending[id] === worker { pending.removeValue(forKey: id) }
            await worker.stop()
            throw CancellationError()
        }
        runtime.worker = worker; runtime.gate = gate
        if pending[id] === worker { pending.removeValue(forKey: id) }
        synchronizeSelectionActions()
        notify()
    }
    private func stop(_ id: String) async {
        epochs[id] = UUID()
        reloadTasks.removeValue(forKey: id)?.cancel()
        watchers.removeValue(forKey: id)?.stop()
        let candidate = pending.removeValue(forKey: id)
        let runtime = active.removeValue(forKey: id)
        if let runtime { preparedSettings[id] = PreparedSettings(snapshot: runtime.snapshot, schema: runtime.schema, values: runtime.settings) }
        synchronizeSelectionActions()
        if let candidate { await candidate.stop() }
        if let runtime { await runtime.worker.stop() }
    }
    private func watch(_ id: String) {
        guard watchers[id] == nil, let url = sourceURL(for: id) else { return }
        let watcher = SourceFileWatcher(rootURL: url) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.state.enabled[id] == true, !self.shuttingDown else { return }
                self.reloadTasks[id]?.cancel()
                self.reloadTasks[id] = Task { [weak self] in try? await self?.reload(id) }
            }
        }
        watchers[id] = watcher; watcher.start()
    }
    private func parseSchema(_ snapshot: SourcePackageSnapshot) throws -> ScriptSettingsSchema? {
        guard let path = snapshot.manifest.settingsSchema else { return nil }
        guard let text = snapshot.resources[path] else { throw SourcePackageError.invalid(L("The settings schema is missing.")) }
        let schema = try ScriptSettingsSchema(data: Data(text.utf8))
        try schema.validatePromptResources(in: snapshot)
        return schema
    }
    private func readSettingsSource(for id: String) throws -> (SourcePackageSnapshot, PreparedSettings) {
        let snapshot = try store.snapshot(for: id)
        return (snapshot, try settingsConfiguration(snapshot, id: id))
    }
    private func settingsConfiguration(_ snapshot: SourcePackageSnapshot, id: String) throws -> PreparedSettings {
        let schema = try parseSchema(snapshot)
        return PreparedSettings(snapshot: snapshot, schema: schema, values: try loadSettings(id, schema: schema))
    }
    private func loadSettings(_ id: String, schema: ScriptSettingsSchema?) throws -> [String: Any] {
        guard let schema else { return [:] }
        let url = settingsURL(id)
        let values = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return schema.normalized(values)
    }
    private func saveSettings(_ values: [String: Any], id: String) throws {
        try privateJSON(values, to: settingsURL(id))
    }
    private func saveState() throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    private func privateJSON(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func saveLastGood(_ snapshot: SourcePackageSnapshot, id: String) throws {
        let destination = cacheURL(id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".candidate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: snapshot.rootURL, to: stage)
        guard try SourcePackageInspector.snapshot(at: stage).fingerprint == snapshot.fingerprint else { return }
        let previous = destination.deletingLastPathComponent().appendingPathComponent(".previous-" + UUID().uuidString)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: destination, to: previous) }
        do { try FileManager.default.moveItem(at: stage, to: destination) }
        catch { if FileManager.default.fileExists(atPath: previous.path) { try? FileManager.default.moveItem(at: previous, to: destination) }; throw error }
        try? FileManager.default.removeItem(at: previous)
    }
    private func recoverLastGood(_ id: String) async throws {
        let epoch = epochs[id]
        guard FileManager.default.fileExists(atPath: cacheURL(id).path) else { return }
        let snapshot = try SourcePackageInspector.snapshot(at: cacheURL(id))
        guard snapshot.manifest.identifier == id,
              Set(snapshot.manifest.permissions).isSubset(of: Set(state.permissions[id] ?? [])) else { return }
        let schema = try parseSchema(snapshot), values = try loadSettings(id, schema: schema)
        let (worker, gate) = try await makeWorker(snapshot: snapshot, settings: values, epoch: epoch)
        guard !shuttingDown, state.enabled[id] == true, epochs[id] == epoch else {
            if pending[id] === worker { pending.removeValue(forKey: id) }
            await worker.stop()
            throw CancellationError()
        }
        active[id] = Running(snapshot: snapshot, worker: worker, gate: gate, schema: schema, settings: values)
        preparedSettings[id] = PreparedSettings(snapshot: snapshot, schema: schema, values: values)
        if pending[id] === worker { pending.removeValue(forKey: id) }
        synchronizeSelectionActions()
        statuses[id] = "Running the last working version while local edits are invalid."
        watch(id)
    }
    private func synchronizeSelectionActions(invalidateCurrent: Bool = false) {
        guard !headless, !shuttingDown else { return }
        let actions: [CapabilitySelectionAction] = active.keys.sorted().flatMap { id -> [CapabilitySelectionAction] in
            guard let runtime = active[id], state.enabled[id] == true, shouldMonitor(runtime.snapshot) else { return [] }
            return runtime.snapshot.manifest.commands.filter { $0.trigger == "selection" }.map { command in
                CapabilitySelectionAction(identifier: id + "/" + command.identifier, generation: runtime.activationGeneration,
                    title: localizedText(command.title, for: id),
                    allowsReplacement: runtime.snapshot.manifest.permissions.contains("selection.replace"),
                    allowsPaste: runtime.snapshot.manifest.permissions.contains("selection.paste")) { [weak self, weak runtime] input, progress in
                    guard let self, let runtime, self.active[id] === runtime else { throw CancellationError() }
                    return try await self.performCommand(for: id, text: input.text, sentence: input.sentence,
                        commandIdentifier: command.identifier, onProgress: progress)
                }
            }
        }
        selectionCapability.setActions(actions, invalidateCurrent: invalidateCurrent)
        selectionCapability.onStatusChange = { [weak self] in self?.notify() }
        if actions.isEmpty { selectionCapability.stop() }
        else { selectionCapability.start() }
    }

    private func shouldMonitor(_ snapshot: SourcePackageSnapshot) -> Bool {
        !headless && snapshot.manifest.permissions.contains("selection.read") && snapshot.manifest.permissions.contains("ui.panel") &&
            snapshot.manifest.commands.contains { $0.trigger == "selection" }
    }
    private func notify() { onChange?() }
}
