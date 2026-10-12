import Foundation

public enum MessageHelperError: LocalizedError, Equatable {
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
                        throw MessageHelperError.invalid("The request exceeds the native message size limit or is empty.")
                    }
                    expectedLength = Int(length)
                }
            }
        }
        return frames
    }

    public func finish() throws {
        guard header.isEmpty, expectedLength == nil else {
            throw MessageHelperError.invalid("The browser disconnected during a native message.")
        }
    }
}

public enum NativeFrameEncoder {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard !payload.isEmpty, payload.count <= NativeFrameDecoder.maximumFrameBytes else {
            throw MessageHelperError.invalid("The result exceeds the native message size limit.")
        }
        let length = UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        frame.append(payload)
        return frame
    }
}

public struct HelperRequest: Decodable, Sendable {
    public enum Action: String, Decodable, Sendable { case ping, listModels, translate, polish }
    public static let languages = ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "pt", "it"]
    public static let tones = ["professional", "friendly", "concise"]
    public static let maximumTextCharacters = 24_000
    public let id: String
    public let action: Action
    public let text: String?
    public let targetLanguage: String?
    public let tone: String?
    public let model: String?

    public init(id: String, action: Action, text: String? = nil, targetLanguage: String? = nil, tone: String? = nil, model: String? = nil) {
        self.id = id; self.action = action; self.text = text
        self.targetLanguage = targetLanguage; self.tone = tone
        self.model = model
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MessageHelperError.invalid("A valid request ID is required.")
        }
        if let targetLanguage, !Self.languages.contains(targetLanguage) {
            throw MessageHelperError.invalid("Choose a supported translation language.")
        }
        if let tone, !Self.tones.contains(tone) {
            throw MessageHelperError.invalid("Choose a supported polishing tone.")
        }
        if let model, !model.isEmpty, !LocalGPTModel.validIdentifier(model) {
            throw MessageHelperError.invalid("Choose a model with a valid ID of at most 200 bytes.")
        }
        guard action != .ping, action != .listModels else { return }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageHelperError.invalid("The message is empty.")
        }
        guard text.count <= Self.maximumTextCharacters, text.utf8.count <= 96_000 else {
            throw MessageHelperError.invalid("Messages must contain at most 24,000 characters.")
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw MessageHelperError.invalid("The message contains an unsupported null character.")
        }
    }

    /// A JSON field prevents quoted message content from becoming request instructions.
    public func prompt() throws -> String {
        try validate()
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "action": action.rawValue,
            "targetLanguage": action == .polish ? "en" : targetLanguage ?? "zh-CN",
            "tone": tone ?? "professional",
            "text": text ?? ""
        ], options: [.sortedKeys]), as: UTF8.self)
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

    public init(id: String, text: String? = nil, model: String? = nil) {
        self.id = id; ok = true; self.text = text; self.model = model
        version = "1.1.0"; error = nil; models = nil; defaultModel = nil
    }
    public init(id: String, catalog: LocalGPTModelCatalog) {
        self.id = id; ok = true; text = nil; model = nil; version = "1.1.0"; error = nil
        models = catalog.models; defaultModel = catalog.defaultModel
    }
    public init(id: String, error: String) {
        self.id = id; ok = false; text = nil; model = nil; version = nil; self.error = error
        models = nil; defaultModel = nil
    }
}

public enum NativeHostOrigin {
    /// Chrome provides its extension origin as argv[1]; manual framed smoke tests omit it.
    public static func validate(arguments: [String], allowedExtensionIDs: [String]) throws {
        guard arguments.count <= 2 else {
            throw MessageHelperError.invalid("Unexpected native host arguments.")
        }
        guard let origin = arguments.dropFirst().first else { return }
        guard allowedExtensionIDs.contains(where: { origin == "chrome-extension://\($0)/" }) else {
            throw MessageHelperError.invalid("This browser extension is not authorized to use MessageHelper.")
        }
    }
}
