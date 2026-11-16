import Foundation

public enum MacHelperError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Chrome and Edge use a four-byte little-endian length followed by UTF-8 JSON.
public struct NativeFrameDecoder {
    public static let maximumFrameBytes = 256 * 1024
    private var header = Data()
    private var payload = Data()
    private var expectedLength: Int?

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in bytes {
            if let expectedLength {
                payload.append(byte)
                if payload.count == expectedLength {
                    frames.append(payload)
                    payload.removeAll(keepingCapacity: false)
                    self.expectedLength = nil
                }
            } else {
                header.append(byte)
                if header.count == 4 {
                    let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                    header.removeAll(keepingCapacity: true)
                    guard length > 0, length <= Self.maximumFrameBytes else {
                        throw MacHelperError.invalid("The request exceeds the native message size limit or is empty.")
                    }
                    expectedLength = Int(length)
                }
            }
        }
        return frames
    }

    public func finish() throws {
        guard header.isEmpty, expectedLength == nil else {
            throw MacHelperError.invalid("The browser disconnected during a native message.")
        }
    }
}

public enum NativeFrameEncoder {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty, payload.count <= NativeFrameDecoder.maximumFrameBytes else {
            throw MacHelperError.invalid("The result exceeds the native message size limit.")
        }
        let length = UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        frame.append(payload)
        return frame
    }
}

public struct HelperRequest: Decodable, Sendable {
    public enum Action: String, Decodable, Sendable { case ping, listModels, translate, polish, searchExtensions }
    public static let languages = ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "pt", "it"]
    public static let tones = ["professional", "friendly", "concise"]
    public static let maximumTextCharacters = 24_000
    public static let maximumExplicitPromptTextBytes = 192_000
    public let id: String
    public let action: Action
    public let text: String?
    public let targetLanguage: String?
    public let tone: String?
    public let model: String?
    public let provider: String?
    public let baseURL: String?
    public let guidance: String?
    public let stream: Bool?
    public let systemPrompt: String?
    public let interfaceLanguage: String?

    public init(id: String, action: Action, text: String? = nil, targetLanguage: String? = nil, tone: String? = nil, model: String? = nil, provider: String? = nil, baseURL: String? = nil, guidance: String? = nil, stream: Bool? = nil, systemPrompt: String? = nil, interfaceLanguage: String? = nil) {
        self.id = id; self.action = action; self.text = text
        self.targetLanguage = targetLanguage; self.tone = tone
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.guidance = guidance
        self.stream = stream
        self.systemPrompt = systemPrompt
        self.interfaceLanguage = interfaceLanguage
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MacHelperError.invalid("A valid request ID is required.")
        }
        if action == .searchExtensions {
            guard let text, targetLanguage == nil, tone == nil, model == nil, provider == nil, baseURL == nil,
                  guidance == nil, systemPrompt == nil, stream != true,
                  interfaceLanguage.map({ lang in AppLocalization.supportedLanguages.contains(where: { $0.code == lang }) }) ?? true else {
                throw DiscoveryError.invalidQuery
            }
            _ = try DiscoveryQuery.validate(text)
            return
        }
        if let interfaceLanguage, !AppLocalization.supportedLanguages.contains(where: { $0.code == interfaceLanguage }) { throw DiscoveryError.invalidQuery }
        if let targetLanguage, !Self.languages.contains(targetLanguage) {
            throw MacHelperError.invalid("Choose a supported translation language.")
        }
        if let tone, !Self.tones.contains(tone) {
            throw MacHelperError.invalid("Choose a supported polishing tone.")
        }
        if let model, !model.isEmpty, !LocalGPTModel.validIdentifier(model) {
            throw MacHelperError.invalid("Choose a model with a valid ID of at most 200 bytes.")
        }
        if let provider, AIProvider(rawValue: provider) == nil {
            throw MacHelperError.invalid("Choose a supported local AI provider.")
        }
        if let baseURL, baseURL.utf8.count > 2048 {
            throw MacHelperError.invalid("The local service address is too long.")
        }
        if let guidance, guidance.count > 12_000 || guidance.utf8.count > 48_000 || guidance.contains("\0") {
            throw MacHelperError.invalid("Translation guidance must contain at most 12,000 characters and no null characters.")
        }
        if let systemPrompt { try Self.validateSystemPrompt(systemPrompt) }
        guard action != .ping, action != .listModels else { return }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacHelperError.invalid("The message is empty.")
        }
        if systemPrompt != nil {
            guard text.utf8.count <= Self.maximumExplicitPromptTextBytes else {
                throw MacHelperError.invalid("Extension input data must contain at most 192,000 UTF-8 bytes.")
            }
        } else {
            guard text.count <= Self.maximumTextCharacters, text.utf8.count <= 96_000 else {
                throw MacHelperError.invalid("Messages must contain at most 24,000 characters.")
            }
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw MacHelperError.invalid("The message contains an unsupported null character.")
        }
    }

    static func validateSystemPrompt(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= 12_000, value.utf8.count <= 48_000, !value.contains("\0") else {
            throw MacHelperError.invalid("The system prompt must be nonempty, contain at most 12,000 characters/48,000 UTF-8 bytes, and contain no null characters.")
        }
    }

    /// Ordinary clients omit overrides and use the shared configuration for every request.
    public func resolvedSettings(_ saved: HelperSettings) throws -> HelperSettings {
        try validate()
        let selected = provider.flatMap(AIProvider.init(rawValue:)) ?? saved.provider
        let changedProvider = selected != saved.provider
        return try HelperSettings(provider: selected,
                                  model: model.flatMap { $0.isEmpty ? nil : $0 } ?? (changedProvider ? "" : saved.model),
                                  baseURL: baseURL ?? (changedProvider ? "" : saved.baseURL)).validated()
    }

    public func resolvedSettings(from store: HelperSettingsStore) throws -> HelperSettings {
        try validate()
        // A complete settings preview must remain usable when an older settings
        // file is corrupt. Ordinary clients still report corrupt preferences.
        if action == .listModels, let provider, let selected = AIProvider(rawValue: provider),
           let baseURL, let model {
            return try HelperSettings(provider: selected, model: model, baseURL: baseURL).validated()
        }
        return try resolvedSettings(store.load())
    }

    /// A JSON field prevents quoted message content from becoming request instructions.
    public func prompt() throws -> String {
        try validate()
        // Explicit extension prompts own both messages. Preserve source bytes
        // represented by the strings; do not wrap or append legacy defaults.
        if systemPrompt != nil { return text ?? "" }
        var fields = [
            "action": action.rawValue,
            "targetLanguage": action == .polish ? "en" : targetLanguage ?? "zh-CN",
            "tone": tone ?? "professional",
            "text": text ?? ""
        ]
        if let guidance, !guidance.isEmpty { fields["guidance"] = guidance }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Optional incremental output. Clients still wait for the ordinary terminal
/// HelperResponse before treating an answer as complete and validated.
public struct HelperStreamUpdate: Encodable, Sendable {
    public let id: String
    public let event = "delta"
    public let delta: String
    public let model: String?

    public init(id: String, delta: String, model: String? = nil) {
        self.id = id; self.delta = delta; self.model = model
    }
}

public struct HelperResponse: Encodable, Sendable {
    public let id: String
    public let ok: Bool
    public let text: String?
    public let version: String?
    public let model: String?
    public let models: [LocalGPTModel]?
    public let defaultModel: String?
    public let error: String?
    public let search: DiscoverySearchResult?

    public init(id: String, text: String? = nil, model: String? = nil) {
        self.id = id; ok = true; self.text = text; self.model = model
        version = "6.4.0"; error = nil; models = nil; defaultModel = nil; search = nil
    }
    public init(id: String, catalog: LocalGPTModelCatalog) {
        self.id = id; ok = true; text = nil; model = nil; version = "6.4.0"; error = nil; search = nil
        models = catalog.models; defaultModel = catalog.defaultModel
    }
    public init(id: String, error: String) {
        self.id = id; ok = false; text = nil; model = nil; version = nil; self.error = error
        models = nil; defaultModel = nil; search = nil
    }
    public init(id: String, search: DiscoverySearchResult) {
        self.id = id; ok = true; self.search = search; text = nil; model = nil; version = "6.4.0"
        models = nil; defaultModel = nil; error = nil
    }
}

public enum NativeHostOrigin {
    /// Chrome provides its extension origin as argv[1]; manual framed smoke tests omit it.
    public static func validate(arguments: [String], allowedExtensionIDs: [String]) throws {
        guard arguments.count <= 2 else {
            throw MacHelperError.invalid("Unexpected native host arguments.")
        }
        guard let origin = arguments.dropFirst().first else { return }
        guard allowedExtensionIDs.contains(where: { origin == "chrome-extension://\($0)/" }) else {
            throw MacHelperError.invalid("This browser extension is not authorized to use MacHelper.")
        }
    }
}
