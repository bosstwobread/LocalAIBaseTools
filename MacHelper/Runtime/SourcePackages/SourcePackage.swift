import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SourcePackageError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

public struct SourceExtensionCommand: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let trigger: String
    public let systemSymbolName: String?
    public init(identifier: String, title: String, trigger: String, systemSymbolName: String? = nil) {
        self.identifier = identifier; self.title = title; self.trigger = trigger
        self.systemSymbolName = systemSymbolName
    }
}

public enum SourceSelectionPermissionReview: Equatable {
    case replacement, paste

    public static func required(requested: [String], approved: [String]) -> Self? {
        let existing = Set(approved)
        // The paste review explicitly includes replacement on Apply, so a new
        // tool requesting both capabilities needs one clear selection review.
        if requested.contains("selection.paste"), !existing.contains("selection.paste") { return .paste }
        if requested.contains("selection.replace"), !existing.contains("selection.replace") { return .replacement }
        return nil
    }
}

public enum SourceCompanionBrowser: String, CaseIterable, Codable, Hashable, Sendable {
    case chrome, edge, firefox, safari

    public func acceptsIdentifier(_ identifier: String) -> Bool {
        guard identifier.utf8.count <= 128 else { return false }
        let pattern: String
        switch self {
        case .chrome, .edge:
            pattern = #"\A[a-p]{32}\z"#
        case .firefox:
            guard identifier.utf8.count <= 80 else { return false }
            pattern = #"\A(?:[A-Za-z0-9._-]*@[A-Za-z0-9._-]+|\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\})\z"#
        case .safari:
            pattern = #"\A[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+\z"#
        }
        return identifier.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct SourceBrowserCompanion: Codable, Equatable, Sendable {
    public let browser: SourceCompanionBrowser
    public let identifier: String
    public let storeURL: String?
    public let packageURL: String?
    public let packageSHA256: String?
    public let sourceURL: String?

    public init(browser: SourceCompanionBrowser, identifier: String, storeURL: String? = nil,
                packageURL: String? = nil, packageSHA256: String? = nil, sourceURL: String? = nil) {
        self.browser = browser
        self.identifier = identifier
        self.storeURL = storeURL
        self.packageURL = packageURL
        self.packageSHA256 = packageSHA256
        self.sourceURL = sourceURL
    }

    public func validate() throws {
        guard browser.acceptsIdentifier(identifier) else {
            throw SourcePackageError.invalid("A browser companion declares an invalid extension identifier.")
        }
        if let storeURL, !acceptsStoreURL(storeURL) {
            throw SourcePackageError.invalid("A browser companion must use its official store listing.")
        }
        if let sourceURL, !Self.isPinnedGitHubURL(sourceURL, raw: false) {
            throw SourcePackageError.invalid("Browser companion source links must use a pinned GitHub file or folder.")
        }
        if packageURL != nil || packageSHA256 != nil {
            guard browser != .safari, let packageURL, let packageSHA256,
                  Self.isPinnedGitHubURL(packageURL, raw: true),
                  packageSHA256.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
                throw SourcePackageError.invalid("A browser development package needs a pinned GitHub JSON manifest and its SHA-256 digest.")
            }
        }
    }

    private func acceptsStoreURL(_ value: String) -> Bool {
        guard let url = Self.safeHTTPSComponents(value) else { return false }
        let host: String
        let pattern: String
        switch browser {
        case .chrome:
            host = "chromewebstore.google.com"
            pattern = #"\A/detail/(?:[A-Za-z0-9_-]+/)?"# + identifier + #"/?\z"#
        case .edge:
            host = "microsoftedge.microsoft.com"
            pattern = #"\A/addons/detail/(?:[A-Za-z0-9_-]+/)?"# + identifier + #"/?\z"#
        case .firefox:
            host = "addons.mozilla.org"
            pattern = #"\A/(?:[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*/)?firefox/addon/[A-Za-z0-9_-]+/?\z"#
        case .safari:
            host = "apps.apple.com"
            pattern = #"\A/(?:[A-Za-z]{2}/)?app/(?:[A-Za-z0-9_-]+/)?id[0-9]+/?\z"#
        }
        return url.host == host && url.percentEncodedPath.range(of: pattern, options: .regularExpression) != nil
    }

    private static func safeHTTPSComponents(_ value: String) -> URLComponents? {
        guard value.utf8.count <= 2048, let url = URLComponents(string: value),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.url?.absoluteString == value else { return nil }
        return url
    }

    private static func isPinnedGitHubURL(_ value: String, raw: Bool) -> Bool {
        guard let url = safeHTTPSComponents(value), url.host == (raw ? "raw.githubusercontent.com" : "github.com") else { return false }
        let path = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        let revision = raw ? 3 : 4
        guard path.count >= revision + 2, path[0].isEmpty,
              path[1].range(of: #"\A[A-Za-z0-9-]{1,39}\z"#, options: .regularExpression) != nil,
              path[2].count <= 100,
              raw || ["tree", "blob"].contains(path[3]),
              path[revision].range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
              !raw || path.last?.hasSuffix(".json") == true else { return false }
        return ([path[2]] + path.dropFirst(revision + 1)).allSatisfy { segment in
            segment != "." && segment != ".." &&
                segment.range(of: #"\A[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil
        }
    }
}

public struct SourceCompanion: Codable, Equatable, Sendable {
    public let chromeExtensionID: String?
    public let browsers: [SourceBrowserCompanion]?

    public init(chromeExtensionID: String) {
        self.chromeExtensionID = chromeExtensionID
        browsers = nil
    }

    public init(browsers: [SourceBrowserCompanion]) {
        chromeExtensionID = nil
        self.browsers = browsers
    }

    fileprivate func validate() throws {
        if let chromeExtensionID, browsers == nil, SourceCompanionBrowser.chrome.acceptsIdentifier(chromeExtensionID) { return }
        guard chromeExtensionID == nil, let browsers, (1...SourceCompanionBrowser.allCases.count).contains(browsers.count),
              Set(browsers.map(\.browser)).count == browsers.count else {
            throw SourcePackageError.invalid("Declare one companion per browser or use the legacy Chrome extension identifier.")
        }
        for browser in browsers { try browser.validate() }
    }
}

public struct SourceCompanionGrant: Codable, Equatable, Sendable {
    public static let permission = "companion.message"

    public let chromeExtensionID: String?
    public let browsers: [SourceBrowserCompanion]?
    public let commands: [String]
    public let allowsAI: Bool

    public var browserCompanions: [SourceBrowserCompanion] {
        browsers ?? chromeExtensionID.map { [.init(browser: .chrome, identifier: $0)] } ?? []
    }
}

public struct SourceExtensionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runtime: String
    public let identifier: String
    public let displayName: String
    public let version: String
    public let summary: String
    public let entryPoint: String
    public let permissions: [String]
    public let commands: [SourceExtensionCommand]
    public let settingsSchema: String?
    public let localizations: String?
    public let icon: String?
    public let companion: SourceCompanion?

    public init(schemaVersion: Int = 2, runtime: String = "javascript", identifier: String,
                displayName: String, version: String, summary: String, entryPoint: String = "main.js",
                permissions: [String], commands: [SourceExtensionCommand], settingsSchema: String? = nil,
                localizations: String? = nil, icon: String? = nil, companion: SourceCompanion? = nil) {
        self.schemaVersion = schemaVersion; self.runtime = runtime; self.identifier = identifier
        self.displayName = displayName; self.version = version; self.summary = summary
        self.entryPoint = entryPoint; self.permissions = permissions; self.commands = commands
        self.settingsSchema = settingsSchema
        self.localizations = localizations
        self.icon = icon
        self.companion = companion
    }

    public var companionGrant: SourceCompanionGrant? {
        guard let companion, permissions.contains(SourceCompanionGrant.permission) else { return nil }
        return SourceCompanionGrant(chromeExtensionID: companion.chromeExtensionID,
                                    browsers: companion.browsers?.sorted { $0.browser.rawValue < $1.browser.rawValue },
                                    commands: commands.filter { $0.trigger == "companion" }.map(\.identifier).sorted(),
                                    allowsAI: permissions.contains("ai.transform"))
    }

    public func validate() throws {
        guard schemaVersion == 2, ["javascript", "native"].contains(runtime) else {
            throw SourcePackageError.invalid("This extension needs API version 2 and a supported javascript or native runtime.")
        }
        try SourcePackageRules.validateIdentifier(identifier)
        guard SourcePackageRules.validText(displayName, limit: 256), SourcePackageRules.validText(summary, limit: 2000),
              SourcePackageRules.validVersion(version), entryPoint.hasSuffix(runtime == "native" ? ".swift" : ".js") else {
            throw SourcePackageError.invalid("The extension's name, summary, version, or runtime entry point is invalid.")
        }
        try SourcePackageRules.validatePath(entryPoint)
        if let settingsSchema { try SourcePackageRules.validatePath(settingsSchema) }
        if let localizations {
            try SourcePackageRules.validatePath(localizations)
            guard localizations.hasSuffix(".json") else {
                throw SourcePackageError.invalid("The extension UI translation catalog must be a JSON resource.")
            }
        }
        if let icon {
            try SourcePackageRules.validatePath(icon)
            guard icon.hasSuffix(".png") else {
                throw SourcePackageError.invalid("The extension icon must be a PNG resource.")
            }
        }
        // Accept old immutable packages' clipboard declaration for compatibility;
        // the current source-worker API does not provide a clipboard reader.
        var allowed: Set<String> = ["selection.read", "selection.replace", "selection.paste", "clipboard.read", "ai.transform", "ui.panel",
                                    SourceCompanionGrant.permission]
        if runtime == "native" { allowed.insert("native.execute") }
        guard permissions.count <= allowed.count, Set(permissions).count == permissions.count,
              permissions.allSatisfy(allowed.contains), !commands.isEmpty, commands.count <= 16,
              Set(commands.map(\.identifier)).count == commands.count else {
            throw SourcePackageError.invalid("The source extension declares unsupported permissions or duplicate commands.")
        }
        if runtime == "native", !permissions.contains("native.execute") {
            throw SourcePackageError.invalid("Native extensions must declare native.execute permission for trusted native code execution.")
        }
        if permissions.contains("selection.replace"), !permissions.contains("selection.read") {
            throw SourcePackageError.invalid(L("Selected-text replacement requires selection.read permission."))
        }
        if permissions.contains("selection.paste"), !Set(["selection.read", "selection.replace"]).isSubset(of: Set(permissions)) {
            throw SourcePackageError.invalid(L("Selected-text paste requires selection.read and selection.replace permissions."))
        }
        if let grant = companionGrant, let companion {
            try companion.validate()
            guard !grant.commands.isEmpty else {
                throw SourcePackageError.invalid("A browser companion needs a companion command.")
            }
        } else if companion != nil || permissions.contains(SourceCompanionGrant.permission) ||
                    commands.contains(where: { $0.trigger == "companion" }) {
            throw SourcePackageError.invalid("Companion commands require a companion declaration and companion.message permission.")
        }
        for command in commands {
            guard command.identifier.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil,
                  SourcePackageRules.validText(command.title, limit: 160), ["selection", "manual", "companion"].contains(command.trigger) else {
                throw SourcePackageError.invalid("The source extension declares an invalid command.")
            }
            if let symbol = command.systemSymbolName,
               symbol.range(of: #"\A[a-z0-9][a-z0-9.-]{0,99}\z"#, options: .regularExpression) == nil {
                throw SourcePackageError.invalid("The source extension declares an invalid command icon.")
            }
            if command.trigger == "selection", !permissions.contains("selection.read") {
                throw SourcePackageError.invalid("Selection commands must declare selection.read permission.")
            }
        }
    }
}

public struct SourcePackageSnapshot: Sendable {
    public let manifest: SourceExtensionManifest
    public let rootURL: URL
    public let entrySource: String
    /// Frozen UTF-8 resources for this generation. No direct filesystem access is exposed to scripts.
    public let resources: [String: String]
    public let fingerprint: String
    public let isLocallyModified: Bool
    public let fileHashes: [String: String]
    public let localizations: SourceTextLocalizations?
    public let iconData: Data?
}

public enum SourcePackageRules {
    public static let maximumFiles = 128
    public static let maximumFileBytes = 512 * 1024
    public static let maximumPackageBytes = 4 * 1024 * 1024
    public static let maximumRuntimeTextBytes = 96 * 1024
    static let receiptName = ".macsource-receipt.json"

    public static func validateIdentifier(_ value: String) throws {
        guard value.utf8.count <= 128,
              value.range(of: #"^[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*){1,7}$"#, options: .regularExpression) != nil else {
            throw SourcePackageError.invalid("A reverse-domain extension identifier is required.")
        }
    }
    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 512, parts.count <= 12,
              parts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_. -]{0,119}$"#, options: .regularExpression) != nil }) else {
            throw SourcePackageError.invalid("A source file path is invalid or escapes its package.")
        }
    }
    static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func validVersion(_ value: String) -> Bool {
        value.utf8.count <= 80 && value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil
    }
    public static func isNewerVersion(_ candidate: String, than installed: String) -> Bool {
        guard validVersion(candidate), validVersion(installed) else { return false }
        let new = candidate.split(separator: "-", maxSplits: 1)
        let old = installed.split(separator: "-", maxSplits: 1)
        let core = new[0].compare(old[0], options: .numeric)
        if core != .orderedSame { return core == .orderedDescending }
        if new.count != old.count { return new.count == 1 }
        guard new.count == 2 else { return false }
        let newPrerelease = new[1].split(separator: ".", omittingEmptySubsequences: false)
        let oldPrerelease = old[1].split(separator: ".", omittingEmptySubsequences: false)
        for (lhs, rhs) in zip(newPrerelease, oldPrerelease) where lhs != rhs {
            let lhsNumeric = !lhs.isEmpty && lhs.allSatisfy(\.isASCII) && lhs.allSatisfy(\.isNumber)
            let rhsNumeric = !rhs.isEmpty && rhs.allSatisfy(\.isASCII) && rhs.allSatisfy(\.isNumber)
            if lhsNumeric != rhsNumeric { return rhsNumeric }
            if lhsNumeric {
                let result = lhs.compare(rhs, options: .numeric)
                if result != .orderedSame { return result == .orderedDescending }
            } else {
                return lhs > rhs
            }
        }
        return newPrerelease.count > oldPrerelease.count
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func boundedData(_ url: URL, maximum: Int = maximumFileBytes) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? maximum + 1) <= maximum else {
            throw SourcePackageError.invalid("A source file is not a bounded regular file.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximum else { throw SourcePackageError.invalid("A source file exceeds its size limit.") }
        return data
    }
    static func containedURL(_ relative: String, root: URL) throws -> URL {
        try validatePath(relative)
        var candidate = root
        for piece in relative.split(separator: "/") {
            candidate.appendPathComponent(String(piece))
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SourcePackageError.invalid("Source packages cannot contain symbolic links.") }
        }
        guard candidate.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw SourcePackageError.invalid("A source file escapes its package.")
        }
        return candidate
    }
}

public enum SourcePackageInspector {
    private static let maximumIconBytes = 128 * 1024
    private static let maximumIconDimension = 512

    /// Reads only presentation metadata from a known package, such as an app-bundled seed.
    public static func iconData(at input: URL, matchingIdentifier identifier: String) -> Data? {
        guard let (root, manifest) = try? readManifest(at: input), manifest.identifier == identifier,
              let icon = manifest.icon, let url = try? SourcePackageRules.containedURL(icon, root: root),
              let data = try? SourcePackageRules.boundedData(url, maximum: maximumIconBytes) else { return nil }
        return validatedIcon(data)
    }

    public static func snapshot(at input: URL) throws -> SourcePackageSnapshot {
        let (root, manifest) = try readManifest(at: input)
        let files = try sourceFiles(in: root)
        if manifest.runtime == "native" {
            let swiftFiles = files.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "swift" }
            guard swiftFiles == [manifest.entryPoint] else {
                throw SourcePackageError.invalid("This native extension API compiles exactly one Swift entry file. Combine native code in its declared entryPoint; the SDK is supplied by MacHelper.")
            }
        }
        var resources: [String: String] = [:]
        var hashes: [String: String] = [:]
        var iconData: Data?
        var packageBytes = 0
        var runtimeBytes = 0
        for relative in files {
            let data = try SourcePackageRules.boundedData(SourcePackageRules.containedURL(relative, root: root))
            packageBytes += data.count
            guard packageBytes <= SourcePackageRules.maximumPackageBytes else { throw SourcePackageError.invalid("The source package is too large.") }
            hashes[relative] = SourcePackageRules.digest(data)
            if relative == manifest.icon {
                iconData = validatedIcon(data)
                if iconData != nil || manifest.runtime == "javascript" { continue }
            }
            if manifest.runtime == "native" {
                guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                    throw SourcePackageError.invalid("Native source packages contain UTF-8 source and text resources, not prebuilt executable files.")
                }
            }
            if let text = String(data: data, encoding: .utf8) {
                // Documentation and licenses remain editable on disk but do not
                // need to cross the bounded worker protocol on every generation.
                let ext = URL(fileURLWithPath: relative).pathExtension.lowercased()
                let runtimeExtensions = manifest.runtime == "native" ? ["js", "swift", "json", "txt", "md", "prompt"] : ["js", "json", "txt", "md", "prompt"]
                if runtimeExtensions.contains(ext), !relative.lowercased().hasPrefix("readme"), relative != "discovery.json" {
                    runtimeBytes += data.count
                    guard runtimeBytes <= SourcePackageRules.maximumRuntimeTextBytes else {
                        throw SourcePackageError.invalid("The extension's runtime scripts and resources exceed 96 KiB.")
                    }
                    resources[relative] = text
                }
            }
        }
        guard let entry = resources[manifest.entryPoint], !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourcePackageError.invalid("The extension entry point is missing, empty, or not UTF-8 text.")
        }
        if let schema = manifest.settingsSchema {
            guard let text = resources[schema], let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), object is [String: Any] else {
                throw SourcePackageError.invalid("The extension settings schema is missing or invalid JSON.")
            }
        }
        let localizations: SourceTextLocalizations?
        if let path = manifest.localizations {
            guard let text = resources[path], text.utf8.count <= 64 * 1024,
                  let table = try? JSONDecoder().decode(SourceTextLocalizations.self, from: Data(text.utf8)) else {
                throw SourcePackageError.invalid("The extension UI translation catalog is missing or invalid JSON.")
            }
            try table.validate()
            localizations = table
        } else { localizations = nil }
        var digestInput = Data()
        for key in hashes.keys.sorted() { digestInput.append(Data((key + "\0" + hashes[key]! + "\n").utf8)) }
        let receiptURL = root.appendingPathComponent(SourcePackageRules.receiptName)
        let receipt = (try? SourcePackageRules.boundedData(receiptURL, maximum: 128 * 1024))
            .flatMap { try? JSONDecoder().decode(SourcePackageReceipt.self, from: $0) }
        let modified = receipt.map { $0.identifier != manifest.identifier || $0.hashes != hashes } ?? false
        return SourcePackageSnapshot(manifest: manifest, rootURL: root, entrySource: entry, resources: resources,
                                     fingerprint: SourcePackageRules.digest(digestInput), isLocallyModified: modified,
                                     fileHashes: hashes, localizations: localizations, iconData: iconData)
    }

    private static func readManifest(at input: URL) throws -> (URL, SourceExtensionManifest) {
        let rootValues = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SourcePackageError.invalid("Choose a source extension folder.")
        }
        let root = input.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = try SourcePackageRules.containedURL("extension.json", root: root)
        let manifest = try JSONDecoder().decode(SourceExtensionManifest.self,
                                               from: SourcePackageRules.boundedData(manifestURL, maximum: 64 * 1024))
        try manifest.validate()
        return (root, manifest)
    }

    private static func validatedIcon(_ data: Data) -> Data? {
        guard data.count <= maximumIconBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        // Bounded source reads may map a mutable file. Freeze the bytes before
        // validating them so presentation sees the same image.
        let frozen = data.withUnsafeBytes { Data($0) }
        guard let source = CGImageSourceCreateWithData(frozen as CFData, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...maximumIconDimension).contains(width), (1...maximumIconDimension).contains(height),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary) != nil
        else { return nil }
        return frozen
    }

    static func sourceFiles(in root: URL) throws -> [String] {
        var files: [String] = []
        var queue: [(URL, String)] = [(root, "")]
        var seen = Set<String>()
        var directories = 0
        while let (directory, prefix) = queue.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                let relative = prefix + url.lastPathComponent
                try SourcePackageRules.validatePath(relative)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw SourcePackageError.invalid("Source packages cannot contain symbolic links.") }
                if values.isDirectory == true {
                    guard relative.split(separator: "/").count < 12 else { throw SourcePackageError.invalid("The source package has too many nested folders.") }
                    directories += 1
                    guard directories <= SourcePackageRules.maximumFiles else { throw SourcePackageError.invalid("The source package contains too many folders.") }
                    queue.append((url, relative + "/"))
                } else {
                    guard values.isRegularFile == true, seen.insert(relative.lowercased()).inserted else {
                        throw SourcePackageError.invalid("The source package contains unsupported files or duplicate paths.")
                    }
                    files.append(relative)
                    guard files.count <= SourcePackageRules.maximumFiles else { throw SourcePackageError.invalid("The source package contains too many files.") }
                }
            }
        }
        return files.sorted()
    }
}

struct SourcePackageReceipt: Codable {
    let identifier: String
    let version: String
    let hashes: [String: String]
}
