import Foundation
import CoreFoundation
import Darwin

public struct ScriptSettingOption {
    public let value: String
    public let label: String
}
public struct ScriptSettingField {
    public let key: String
    public let label: String
    public let type: String
    public let defaultValue: Any
    public let options: [ScriptSettingOption]
    /// Prompt contents live exclusively in this source resource, not settings.json.
    public let path: String?
}
public struct ScriptSettingsSchema {
    public let fields: [ScriptSettingField]
    public init(data: Data) throws {
        guard data.count <= 64 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let items = object["fields"] as? [[String: Any]], items.count <= 32 else {
            throw SourcePackageError.invalid("The settings schema must contain at most 32 fields.")
        }
        var result: [ScriptSettingField] = [], keys = Set<String>(), promptPaths = Set<String>()
        for item in items {
            guard let key = item["key"] as? String,
                  key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
                  keys.insert(key).inserted,
                  let label = item["label"] as? String, !label.isEmpty, label.count <= 120,
                  let type = item["type"] as? String, ["select", "text", "boolean", "prompt"].contains(type) else {
                throw SourcePackageError.invalid("A settings field has an invalid name, type, or default.")
            }
            let path: String?
            let defaultValue: Any
            if type == "prompt" {
                guard let resource = item["path"] as? String,
                      resource.hasSuffix(".txt"), item["default"] == nil,
                      promptPaths.insert(resource.lowercased()).inserted else {
                    throw SourcePackageError.invalid("A prompt setting requires its own .txt source path and no duplicate default.")
                }
                try SourcePackageRules.validatePath(resource)
                path = resource; defaultValue = NSNull()
            } else {
                guard let value = item["default"], item["path"] == nil else {
                    throw SourcePackageError.invalid("An ordinary setting requires a default and cannot declare a source path.")
                }
                path = nil; defaultValue = value
            }
            var options: [ScriptSettingOption] = []
            if type == "select" {
                guard let values = item["options"] as? [[String: String]], !values.isEmpty, values.count <= 100 else {
                    throw SourcePackageError.invalid("A select setting requires a bounded list of choices.")
                }
                for value in values {
                    guard let id = value["value"], !id.isEmpty, id.count <= 200,
                          let title = value["label"], !title.isEmpty, title.count <= 200,
                          !options.contains(where: { $0.value == id }) else {
                        throw SourcePackageError.invalid("Settings choices must have unique values and labels.")
                    }
                    options.append(.init(value: id, label: title))
                }
            }
            let field = ScriptSettingField(key: key, label: label, type: type, defaultValue: defaultValue, options: options, path: path)
            guard type == "prompt" || Self.accepts(defaultValue, field: field) else { throw SourcePackageError.invalid("A setting's default value is invalid.") }
            result.append(field)
        }
        fields = result
    }
    public var defaults: [String: Any] { Dictionary(uniqueKeysWithValues: fields.filter { $0.type != "prompt" }.map { ($0.key, $0.defaultValue) }) }
    public func normalized(_ values: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: fields.filter { $0.type != "prompt" }.map { field in
            let value = values[field.key].flatMap { Self.accepts($0, field: field) ? $0 : nil } ?? field.defaultValue
            return (field.key, value)
        })
    }
    public func validate(_ value: Any, for key: String) throws {
        guard let field = fields.first(where: { $0.key == key }), Self.accepts(value, field: field) else {
            throw SourcePackageError.invalid("Choose a valid value for this setting.")
        }
    }
    public func promptPath(for key: String) throws -> String {
        guard let field = fields.first(where: { $0.key == key && $0.type == "prompt" }), let path = field.path else {
            throw SourcePackageError.invalid("Choose a declared prompt resource for this extension.")
        }
        return path
    }
    /// Validate every declared prompt against the same frozen source generation.
    public func validatePromptResources(in snapshot: SourcePackageSnapshot) throws {
        for field in fields where field.type == "prompt" {
            guard let path = field.path, let text = snapshot.resources[path] else {
                throw SourcePackageError.invalid("A declared prompt resource is missing or is not UTF-8 text.")
            }
            try ScriptPromptResource.validate(text)
        }
    }
    private static func accepts(_ value: Any, field: ScriptSettingField) -> Bool {
        switch field.type {
        case "select": return (value as? String).map { candidate in field.options.contains { $0.value == candidate } } ?? false
        case "text": return (value as? String).map { $0.count <= 12_000 && !$0.contains("\0") } ?? false
        case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        default: return false
        }
    }
}

/// Bounded source editing shared by all schema-declared prompt fields. Prompt
/// bytes never enter the separate ordinary-settings store.
public enum ScriptPromptResource {
    public static func validate(_ value: String) throws {
        guard value.count <= 12_000, value.utf8.count <= 48_000, !value.contains("\0"),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourcePackageError.invalid("A prompt must contain text, with at most 12,000 characters and 48,000 UTF-8 bytes, without NUL characters.")
        }
    }

    /// Validate a complete candidate before touching the user's source. The
    /// single-resource replacement preserves all unrelated files and rejects a
    /// stale editor instead of overwriting an external change.
    @discardableResult
    public static func replace(in snapshot: SourcePackageSnapshot, key: String, value: String,
                               expectedValue: String) throws -> SourcePackageSnapshot {
        try validate(value)
        let schema = try Self.schema(for: snapshot)
        let path = try schema.promptPath(for: key)
        guard snapshot.resources[path].map({ Data($0.utf8) }) == Data(expectedValue.utf8) else { throw changed() }
        let manager = FileManager.default
        let stage = snapshot.rootURL.deletingLastPathComponent().appendingPathComponent(".prompt-candidate-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        for relative in snapshot.fileHashes.keys.sorted() {
            let original = try SourcePackageRules.containedURL(relative, root: snapshot.rootURL)
            let bytes = try SourcePackageRules.boundedData(original)
            guard SourcePackageRules.digest(bytes) == snapshot.fileHashes[relative] else { throw changed() }
            let destination = stage.appendingPathComponent(relative)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try (relative == path ? Data(value.utf8) : bytes).write(to: destination, options: .atomic)
        }
        let candidate = try SourcePackageInspector.snapshot(at: stage)
        try Self.schema(for: candidate).validatePromptResources(in: candidate)
        guard try SourcePackageInspector.snapshot(at: snapshot.rootURL).fingerprint == snapshot.fingerprint else { throw changed() }
        try atomicReplace(value, expected: expectedValue, path: path, root: snapshot.rootURL)
        let result = try SourcePackageInspector.snapshot(at: snapshot.rootURL)
        guard result.fileHashes == candidate.fileHashes else { throw changed() }
        return result
    }

    private static func schema(for snapshot: SourcePackageSnapshot) throws -> ScriptSettingsSchema {
        guard let path = snapshot.manifest.settingsSchema, let text = snapshot.resources[path] else {
            throw SourcePackageError.invalid("This source does not declare a settings schema.")
        }
        let schema = try ScriptSettingsSchema(data: Data(text.utf8))
        try schema.validatePromptResources(in: snapshot)
        return schema
    }
    private static func changed() -> SourcePackageError {
        .invalid("The local source changed since this prompt was loaded. Revert to the current source before saving again.")
    }

    /// Open every directory without following symlinks. renameat keeps the
    /// replacement in that verified directory even if a path is later renamed.
    private static func atomicReplace(_ value: String, expected: String, path: String, root: URL) throws {
        try SourcePackageRules.validatePath(path)
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SourcePackageError.invalid("The prompt source folder is unavailable or is a symbolic link.") }
        defer { close(directory) }
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SourcePackageError.invalid("Prompt source folders must be ordinary directories.") }
            close(directory); directory = next
        }
        let name = parts.last!
        func currentData() throws -> Data {
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw changed() }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= 48_000 else { throw changed() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw changed() }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 48_000 else { throw changed() }
            }
            return bytes
        }
        let expectedBytes = Data(expected.utf8)
        guard try currentData() == expectedBytes else { throw changed() }
        let temporary = ".prompt-save-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SourcePackageError.invalid("The prompt could not be staged for saving.") }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try Data(value.utf8).withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SourcePackageError.invalid("The prompt could not be saved completely.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, try currentData() == expectedBytes else { throw changed() }
        guard renameat(directory, temporary, directory, name) == 0 else { throw SourcePackageError.invalid("The prompt could not be replaced atomically.") }
    }
}
