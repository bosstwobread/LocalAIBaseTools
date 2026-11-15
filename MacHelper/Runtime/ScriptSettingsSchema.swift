import Foundation
import CoreFoundation

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
        var result: [ScriptSettingField] = [], keys = Set<String>()
        for item in items {
            guard let key = item["key"] as? String,
                  key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
                  keys.insert(key).inserted,
                  let label = item["label"] as? String, !label.isEmpty, label.count <= 120,
                  let type = item["type"] as? String, ["select", "text", "boolean"].contains(type),
                  let defaultValue = item["default"] else {
                throw SourcePackageError.invalid("A settings field has an invalid name, type, or default.")
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
            let field = ScriptSettingField(key: key, label: label, type: type, defaultValue: defaultValue, options: options)
            guard Self.accepts(defaultValue, field: field) else { throw SourcePackageError.invalid("A setting's default value is invalid.") }
            result.append(field)
        }
        fields = result
    }
    public var defaults: [String: Any] { Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) }) }
    public func normalized(_ values: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: fields.map { field in
            let value = values[field.key].flatMap { Self.accepts($0, field: field) ? $0 : nil } ?? field.defaultValue
            return (field.key, value)
        })
    }
    public func validate(_ value: Any, for key: String) throws {
        guard let field = fields.first(where: { $0.key == key }), Self.accepts(value, field: field) else {
            throw SourcePackageError.invalid("Choose a valid value for this setting.")
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
