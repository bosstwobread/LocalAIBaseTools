import Foundation

public struct LocalGPTModel: Codable, Sendable, Equatable {
    public let model: String
    public let displayName: String
    public let isDefault: Bool
    public let defaultReasoningEffort: String?
    public let supportedReasoningEfforts: [String]

    /// Prefer fast message editing, then the model's advertised default or first effort.
    var messageReasoningEffort: String? {
        if supportedReasoningEfforts.contains("low") { return "low" }
        if let defaultReasoningEffort, supportedReasoningEfforts.contains(defaultReasoningEffort) {
            return defaultReasoningEffort
        }
        return supportedReasoningEfforts.first
    }

    public static func validIdentifier(_ value: String) -> Bool {
        validMetadata(value, maximumBytes: 200)
    }

    private static func validMetadata(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func parse(_ entry: [String: Any]) throws -> LocalGPTModel? {
        if entry["hidden"] as? Bool == true { return nil }
        if let rawModalities = entry["inputModalities"] {
            guard let modalities = rawModalities as? [String], modalities.count <= 32 else {
                throw LocalGPTError.protocolViolation("The model catalog contains invalid input modalities.")
            }
            guard modalities.contains("text") else { return nil }
        }
        guard let model = entry["model"] as? String, validIdentifier(model),
              let displayName = entry["displayName"] as? String, validMetadata(displayName, maximumBytes: 512),
              let isDefault = entry["isDefault"] as? Bool,
              let efforts = entry["supportedReasoningEfforts"] as? [[String: Any]], efforts.count <= 16 else {
            throw LocalGPTError.protocolViolation("The model catalog contains invalid model metadata.")
        }
        var supported: [String] = []
        for effort in efforts {
            guard let value = effort["reasoningEffort"] as? String, validMetadata(value, maximumBytes: 64) else {
                throw LocalGPTError.protocolViolation("The model catalog contains an invalid reasoning effort.")
            }
            if !supported.contains(value) { supported.append(value) }
        }
        var advertisedDefault: String?
        if let rawDefault = entry["defaultReasoningEffort"], !(rawDefault is NSNull) {
            guard let value = rawDefault as? String, validMetadata(value, maximumBytes: 64) else {
                throw LocalGPTError.protocolViolation("The model catalog contains an invalid default reasoning effort.")
            }
            advertisedDefault = value
        }
        return LocalGPTModel(model: model, displayName: displayName, isDefault: isDefault,
                             defaultReasoningEffort: advertisedDefault, supportedReasoningEfforts: supported)
    }
}

public struct LocalGPTModelCatalog: Codable, Sendable, Equatable {
    public let models: [LocalGPTModel]
    public let defaultModel: String?
}
