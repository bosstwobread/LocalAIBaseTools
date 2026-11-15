import AppKit
import CryptoKit
import Foundation
import MacHelperExtensionSDK
import ObjectiveC

public enum ExtensionRegistryError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

public struct ExtensionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identifier: String
    public let displayName: String
    public let version: String
    public let summary: String
    public let entryPoint: String

    public init(schemaVersion: Int = 1, identifier: String, displayName: String, version: String,
                summary: String, entryPoint: String) {
        self.schemaVersion = schemaVersion; self.identifier = identifier; self.displayName = displayName
        self.version = version; self.summary = summary; self.entryPoint = entryPoint
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ExtensionRegistryError.invalid("This extension needs a different MacHelper extension API version.") }
        guard Self.validIdentifier(identifier) else { throw ExtensionRegistryError.invalid("The extension identifier must use reverse-domain notation.") }
        guard Self.validText(displayName, maximumBytes: 256), Self.validText(summary, maximumBytes: 2_000),
              version.utf8.count <= 80, version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else {
            throw ExtensionRegistryError.invalid("The extension name, summary, or version is invalid.")
        }
        let pieces = entryPoint.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "Contents", pieces[1] == "MacOS",
              pieces[2] != ".", pieces[2] != "..", pieces[2].utf8.count <= 160,
              pieces[2].range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            throw ExtensionRegistryError.invalid("The extension entry point must be a file in Contents/MacOS.")
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 128 && value.range(of: #"^[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*){1,7}$"#, options: .regularExpression) != nil
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct InstalledExtension: Identifiable, Equatable, Sendable {
    public var id: String { manifest.identifier }
    public let manifest: ExtensionManifest
    public let bundleURL: URL
    public let isBundled: Bool
    let fingerprint: String
}

public struct ExtensionRegistryIssue: Equatable, Sendable {
    public let bundleURL: URL
    public let message: String
}

/// Discovers metadata without loading code. External native code runs only after
/// explicit enablement, and a changed external executable requires re-enablement.
/// Native extensions are trusted code inside MacHelper, not a security sandbox.
@MainActor
public final class ExtensionRegistry {
    nonisolated public static var defaultUserDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalAIBaseTools/Extensions", isDirectory: true)
    }
    nonisolated public static var defaultStateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalAIBaseTools/MacHelper/extensions.json")
    }
    nonisolated public static var defaultHelperExecutableURL: URL {
        HelperSettingsStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("mac-helper-host")
    }

    public private(set) var extensions: [InstalledExtension] = []
    public private(set) var issues: [ExtensionRegistryIssue] = []
    public private(set) var runtimeErrors: [String: String] = [:]
    public let userDirectory: URL
    private let bundledDirectory: URL?
    private let stateFileURL: URL
    private let helperExecutableURL: URL
    private let hostVersion: String
    private let openAISettings: () -> Void
    private let hideSettings: () -> Void
    private var preferences = EnablementState()
    private var preferenceError: String?
    private var loaded: [String: LoadedExtension] = [:]
    private var restartRequired = Set<String>()

    public init(bundledDirectory: URL? = nil, userDirectory: URL = defaultUserDirectory,
                stateFileURL: URL = defaultStateFileURL, helperExecutableURL: URL = defaultHelperExecutableURL,
                hostVersion: String = "4.3.0", openAISettings: @escaping () -> Void = {}, hideSettings: @escaping () -> Void = {}) {
        self.bundledDirectory = bundledDirectory; self.userDirectory = userDirectory; self.stateFileURL = stateFileURL
        self.helperExecutableURL = helperExecutableURL; self.hostVersion = hostVersion
        self.openAISettings = openAISettings; self.hideSettings = hideSettings
        if FileManager.default.fileExists(atPath: stateFileURL.path) {
            do {
                let data = try Self.boundedData(at: stateFileURL, maximumBytes: 64 * 1024)
                preferences = try JSONDecoder().decode(EnablementState.self, from: data)
                guard preferences.schemaVersion == 1, preferences.enabled.keys.allSatisfy(ExtensionManifest.validIdentifier),
                      preferences.approvedFingerprints.keys.allSatisfy(ExtensionManifest.validIdentifier) else {
                    throw ExtensionRegistryError.invalid("The extension enablement file is invalid.")
                }
            } catch {
                preferences = EnablementState()
                preferenceError = "Extension preferences could not be loaded. Enable an extension explicitly to reset them."
            }
        }
    }

    public func refresh() {
        var found: [InstalledExtension] = []
        var problems: [ExtensionRegistryIssue] = []
        if let preferenceError { problems.append(.init(bundleURL: stateFileURL, message: preferenceError)) }
        for (directory, bundled) in [(bundledDirectory, true), (Optional(userDirectory), false)] {
            guard let directory, FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                            options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for url in candidates where ["machextension", "bundle"].contains(url.pathExtension.lowercased()) {
                    do {
                        let item = try Self.inspect(url, isBundled: bundled)
                        guard !found.contains(where: { $0.id == item.id }) else {
                            throw ExtensionRegistryError.invalid("Another extension already uses this identifier; the bundled copy takes precedence.")
                        }
                        found.append(item)
                    } catch { problems.append(.init(bundleURL: url, message: error.localizedDescription)) }
                }
            } catch { problems.append(.init(bundleURL: directory, message: error.localizedDescription)) }
        }
        for (id, active) in loaded {
            guard found.first(where: { $0.id == id }) == active.descriptor else {
                if active.running { active.instance.stop(); active.running = false }
                restartRequired.insert(id)
                runtimeErrors[id] = "This extension changed or was removed. Restart MacHelper before loading it again."
                continue
            }
        }
        extensions = found
        issues = problems
    }

    public func isEnabled(_ identifier: String) -> Bool {
        guard preferenceError == nil, let item = extensions.first(where: { $0.id == identifier }) else { return false }
        if !item.isBundled {
            return preferences.enabled[identifier] == true && preferences.approvedFingerprints[identifier] == item.fingerprint
        }
        return preferences.enabled[identifier] ?? (identifier == "com.localaibasetools.translation")
    }

    public func isRunning(_ identifier: String) -> Bool { loaded[identifier]?.running == true }

    public func startEnabled() {
        for item in extensions where isEnabled(item.id) {
            do { _ = try start(item) }
            catch { runtimeErrors[item.id] = error.localizedDescription }
        }
    }

    public func setEnabled(_ enabled: Bool, for identifier: String) throws {
        guard let item = extensions.first(where: { $0.id == identifier }) else {
            throw ExtensionRegistryError.invalid("The extension is no longer installed. Refresh the extension list.")
        }
        let wasRunning = isRunning(identifier)
        if enabled { _ = try start(item) }
        var updated = preferences
        updated.enabled[identifier] = enabled
        if enabled && !item.isBundled { updated.approvedFingerprints[identifier] = item.fingerprint }
        do { try save(updated) }
        catch {
            if !wasRunning, let active = loaded[identifier], active.running { active.instance.stop(); active.running = false }
            throw error
        }
        preferences = updated
        preferenceError = nil
        if !enabled, let active = loaded[identifier], active.running { active.instance.stop(); active.running = false }
        runtimeErrors.removeValue(forKey: identifier)
    }

    public func settingsViewController(for identifier: String) throws -> NSViewController {
        guard isEnabled(identifier), let item = extensions.first(where: { $0.id == identifier }) else {
            throw ExtensionRegistryError.invalid("Enable this extension to open its settings. Native extensions run trusted code inside MacHelper.")
        }
        return try start(item).instance.makeSettingsViewController()
    }

    public func stopAll() {
        for active in loaded.values where active.running { active.instance.stop(); active.running = false }
    }

    @discardableResult
    public func importExtension(from source: URL) throws -> InstalledExtension {
        let candidate = try Self.inspect(source, isBundled: false)
        guard !extensions.contains(where: { $0.id == candidate.id && $0.isBundled }) else {
            throw ExtensionRegistryError.invalid("This identifier belongs to a bundled extension.")
        }
        guard loaded[candidate.id] == nil else { throw ExtensionRegistryError.invalid("Quit MacHelper before replacing an extension that has already been loaded.") }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = userDirectory.appendingPathComponent(candidate.id + ".machextension", isDirectory: true)
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            refresh()
            return try Self.inspect(destination, isBundled: false)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExtensionRegistryError.invalid("This extension is already installed. Quit MacHelper and replace its bundle in the Extensions folder to update it.")
        }
        let stage = userDirectory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: source, to: stage)
        _ = try Self.inspect(stage, isBundled: false, requiresExtensionSuffix: false)
        try FileManager.default.moveItem(at: stage, to: destination)
        refresh()
        return try Self.inspect(destination, isBundled: false)
    }

    private func start(_ descriptor: InstalledExtension) throws -> LoadedExtension {
        guard !restartRequired.contains(descriptor.id) else { throw ExtensionRegistryError.invalid("Restart MacHelper to load the updated extension.") }
        // Revalidate at activation so discovery cannot approve a replaced file.
        guard try Self.inspect(descriptor.bundleURL, isBundled: descriptor.isBundled) == descriptor else {
            throw ExtensionRegistryError.invalid("The extension changed since discovery. Refresh the list and enable this version explicitly.")
        }
        if let active = loaded[descriptor.id] {
            if !active.running { active.instance.start(context: active.context); active.running = true }
            return active
        }
        guard let bundle = Bundle(url: descriptor.bundleURL) else { throw ExtensionRegistryError.invalid("The extension bundle could not be opened.") }
        try bundle.loadAndReturnError()
        guard let principalClass = bundle.principalClass,
              let principal = principalClass as? any MacHelperExtension.Type,
              class_getClassMethod(principalClass, NSSelectorFromString("makeExtension")) != nil else {
            throw ExtensionRegistryError.invalid("The extension principal class does not implement MacHelperExtension API version 1.")
        }
        let settingsURL = stateFileURL.deletingLastPathComponent().appendingPathComponent("ExtensionSettings", isDirectory: true)
            .appendingPathComponent(descriptor.id, isDirectory: true)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let context = HostContext(helperExecutablePath: helperExecutableURL.path, settingsDirectory: settingsURL.path,
                                  hostVersion: hostVersion, openAISettings: openAISettings, hideSettings: hideSettings)
        let instance = principal.makeExtension()
        guard ["startWithContext:", "stop", "makeSettingsViewController"].allSatisfy({ instance.responds(to: NSSelectorFromString($0)) }) else {
            throw ExtensionRegistryError.invalid("The extension is missing a required lifecycle or settings method.")
        }
        let active = LoadedExtension(descriptor: descriptor, bundle: bundle, instance: instance, context: context)
        instance.start(context: context)
        active.running = true
        loaded[descriptor.id] = active
        runtimeErrors.removeValue(forKey: descriptor.id)
        return active
    }

    private func save(_ state: EnablementState) throws {
        let directory = stateFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFileURL.path)
    }

    private static func inspect(_ input: URL, isBundled: Bool, requiresExtensionSuffix: Bool = true) throws -> InstalledExtension {
        let root = input.standardizedFileURL.resolvingSymlinksInPath()
        guard !requiresExtensionSuffix || ["machextension", "bundle"].contains(root.pathExtension.lowercased()) else {
            throw ExtensionRegistryError.invalid("Choose a .machextension bundle.")
        }
        let manifestURL = try contained("Contents/Resources/extension.json", in: root)
        let infoURL = try contained("Contents/Info.plist", in: root)
        let manifestData = try boundedData(at: manifestURL, maximumBytes: 64 * 1024)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        try manifest.validate()
        let infoData = try boundedData(at: infoURL, maximumBytes: 64 * 1024)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == manifest.identifier,
              let executable = info["CFBundleExecutable"] as? String,
              manifest.entryPoint == "Contents/MacOS/" + executable,
              let principal = info["NSPrincipalClass"] as? String,
              principal.utf8.count <= 200, principal.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else {
            throw ExtensionRegistryError.invalid("The bundle identity, principal class, or executable does not match its manifest.")
        }
        let executableURL = try contained(manifest.entryPoint, in: root)
        let executableData = try boundedData(at: executableURL, maximumBytes: 128 * 1024 * 1024)
        guard !executableData.isEmpty else { throw ExtensionRegistryError.invalid("The extension executable is empty.") }
        var hash = SHA256(); hash.update(data: manifestData); hash.update(data: infoData); hash.update(data: executableData)
        return InstalledExtension(manifest: manifest, bundleURL: root, isBundled: isBundled,
                                  fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func contained(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw ExtensionRegistryError.invalid("An extension file escapes its bundle.") }
        return url
    }

    private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw ExtensionRegistryError.invalid("An extension file is invalid or exceeds its size limit.")
        }
        return try Data(contentsOf: url)
    }

    private struct EnablementState: Codable {
        var schemaVersion = 1
        var enabled: [String: Bool] = [:]
        var approvedFingerprints: [String: String] = [:]
    }

    private final class LoadedExtension {
        let descriptor: InstalledExtension
        let bundle: Bundle
        let instance: any MacHelperExtension
        let context: HostContext
        var running = false
        init(descriptor: InstalledExtension, bundle: Bundle, instance: any MacHelperExtension, context: HostContext) {
            self.descriptor = descriptor; self.bundle = bundle; self.instance = instance; self.context = context
        }
    }

    private final class HostContext: NSObject, MacHelperExtensionContext {
        let helperExecutablePath: String
        let settingsDirectory: String
        let hostVersion: String
        private let openCallback: () -> Void
        private let hideCallback: () -> Void
        init(helperExecutablePath: String, settingsDirectory: String, hostVersion: String,
             openAISettings: @escaping () -> Void, hideSettings: @escaping () -> Void) {
            self.helperExecutablePath = helperExecutablePath; self.settingsDirectory = settingsDirectory
            self.hostVersion = hostVersion; openCallback = openAISettings; hideCallback = hideSettings
        }
        func openAISettings() { invokeOnMain(openCallback) }
        func hideSettings() { invokeOnMain(hideCallback) }
        private func invokeOnMain(_ callback: @escaping () -> Void) {
            if Thread.isMainThread { callback() }
            else { DispatchQueue.main.async { callback() } }
        }
    }
}
