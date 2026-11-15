import CryptoKit
import Foundation

public enum SourcePackageError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

public struct SourceExtensionCommand: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let trigger: String
    public init(identifier: String, title: String, trigger: String) {
        self.identifier = identifier; self.title = title; self.trigger = trigger
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

    public init(schemaVersion: Int = 2, runtime: String = "javascript", identifier: String,
                displayName: String, version: String, summary: String, entryPoint: String = "main.js",
                permissions: [String], commands: [SourceExtensionCommand], settingsSchema: String? = nil) {
        self.schemaVersion = schemaVersion; self.runtime = runtime; self.identifier = identifier
        self.displayName = displayName; self.version = version; self.summary = summary
        self.entryPoint = entryPoint; self.permissions = permissions; self.commands = commands
        self.settingsSchema = settingsSchema
    }

    public func validate() throws {
        guard schemaVersion == 2, runtime == "javascript" else {
            throw SourcePackageError.invalid("This source extension needs the JavaScript extension API version 2.")
        }
        try SourcePackageRules.validateIdentifier(identifier)
        guard SourcePackageRules.validText(displayName, limit: 256), SourcePackageRules.validText(summary, limit: 2000),
              SourcePackageRules.validVersion(version), entryPoint.hasSuffix(".js") else {
            throw SourcePackageError.invalid("The source extension's name, summary, version, or JavaScript entry point is invalid.")
        }
        try SourcePackageRules.validatePath(entryPoint)
        if let settingsSchema { try SourcePackageRules.validatePath(settingsSchema) }
        let allowed: Set<String> = ["selection.read", "clipboard.read", "ai.transform", "ui.panel"]
        guard permissions.count <= allowed.count, Set(permissions).count == permissions.count,
              permissions.allSatisfy(allowed.contains), !commands.isEmpty, commands.count <= 16,
              Set(commands.map(\.identifier)).count == commands.count else {
            throw SourcePackageError.invalid("The source extension declares unsupported permissions or duplicate commands.")
        }
        for command in commands {
            guard command.identifier.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil,
                  SourcePackageRules.validText(command.title, limit: 160), ["selection", "manual"].contains(command.trigger) else {
                throw SourcePackageError.invalid("The source extension declares an invalid command.")
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
    public static func snapshot(at input: URL) throws -> SourcePackageSnapshot {
        let rootValues = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SourcePackageError.invalid("Choose a source extension folder.")
        }
        let root = input.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = try SourcePackageRules.containedURL("extension.json", root: root)
        let manifest = try JSONDecoder().decode(SourceExtensionManifest.self, from: SourcePackageRules.boundedData(manifestURL, maximum: 64 * 1024))
        try manifest.validate()
        let files = try sourceFiles(in: root)
        var resources: [String: String] = [:]
        var hashes: [String: String] = [:]
        var packageBytes = 0
        var runtimeBytes = 0
        for relative in files {
            let data = try SourcePackageRules.boundedData(SourcePackageRules.containedURL(relative, root: root))
            packageBytes += data.count
            guard packageBytes <= SourcePackageRules.maximumPackageBytes else { throw SourcePackageError.invalid("The source package is too large.") }
            hashes[relative] = SourcePackageRules.digest(data)
            if let text = String(data: data, encoding: .utf8) {
                // Documentation and licenses remain editable on disk but do not
                // need to cross the bounded worker protocol on every generation.
                let ext = URL(fileURLWithPath: relative).pathExtension.lowercased()
                if ["js", "json", "txt", "md", "prompt"].contains(ext), !relative.lowercased().hasPrefix("readme") {
                    runtimeBytes += data.count
                    guard runtimeBytes <= SourcePackageRules.maximumRuntimeTextBytes else {
                        throw SourcePackageError.invalid("The extension's runtime scripts and resources exceed 96 KiB.")
                    }
                    resources[relative] = text
                }
            }
        }
        guard let entry = resources[manifest.entryPoint], !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourcePackageError.invalid("The JavaScript entry point is missing, empty, or not UTF-8 text.")
        }
        if let schema = manifest.settingsSchema {
            guard let text = resources[schema], let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), object is [String: Any] else {
                throw SourcePackageError.invalid("The extension settings schema is missing or invalid JSON.")
            }
        }
        var digestInput = Data()
        for key in hashes.keys.sorted() { digestInput.append(Data((key + "\0" + hashes[key]! + "\n").utf8)) }
        let receiptURL = root.appendingPathComponent(SourcePackageRules.receiptName)
        let receipt = (try? SourcePackageRules.boundedData(receiptURL, maximum: 128 * 1024))
            .flatMap { try? JSONDecoder().decode(SourcePackageReceipt.self, from: $0) }
        let modified = receipt.map { $0.identifier != manifest.identifier || $0.hashes != hashes } ?? false
        return SourcePackageSnapshot(manifest: manifest, rootURL: root, entrySource: entry, resources: resources,
                                     fingerprint: SourcePackageRules.digest(digestInput), isLocallyModified: modified, fileHashes: hashes)
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
