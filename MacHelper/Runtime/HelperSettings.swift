import Foundation

public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case chatGPT = "chatgpt"
    case ollama
    case lmStudio = "lmstudio"

    public var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .chatGPT: return ""
        case .ollama: return "http://127.0.0.1:11434"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        }
    }

    public var explanation: String {
        switch self {
        case .chatGPT: return "Uses your signed-in ChatGPT account. Requests are processed online; no separate API key is needed."
        case .ollama: return "Uses models running on this Mac in Ollama. Start Ollama and download a model first."
        case .lmStudio: return "Uses models running on this Mac in LM Studio. Load a model and start its local server first."
        }
    }
}

public enum HelperSettingsError: LocalizedError, Equatable {
    case invalidModel
    case invalidBaseURL

    public var errorDescription: String? {
        switch self {
        case .invalidModel:
            return "Choose a model with a valid ID of at most 200 bytes."
        case .invalidBaseURL:
            return "Enter an HTTP or HTTPS address on this Mac, such as http://127.0.0.1:11434. Do not include credentials, a query, or a fragment."
        }
    }
}

/// Shared preferences contain backend choices only, never message text or credentials.
public struct HelperSettings: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var model: String
    public var baseURL: String

    public init(provider: AIProvider = .chatGPT, model: String = "", baseURL: String? = nil) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL ?? provider.defaultBaseURL
    }

    private enum CodingKeys: String, CodingKey { case provider, model, baseURL }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .chatGPT
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? provider.defaultBaseURL
    }

    /// Return normalized, safe settings before using or persisting user input.
    public func validated() throws -> HelperSettings {
        var result = self
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.model.utf8.count <= 200,
              !result.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HelperSettingsError.invalidModel
        }
        guard provider != .chatGPT else {
            result.baseURL = ""
            return result
        }

        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = address.isEmpty ? provider.defaultBaseURL : address
        guard let components = URLComponents(string: result.baseURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.url != nil,
              !result.baseURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HelperSettingsError.invalidBaseURL
        }
        while result.baseURL.hasSuffix("/") { result.baseURL.removeLast() }
        return result
    }
}

public struct HelperSettingsStore: Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalAIBaseTools/MacHelper", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) { self.fileURL = fileURL }

    public func load() throws -> HelperSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return HelperSettings() }
        return try JSONDecoder().decode(HelperSettings.self, from: Data(contentsOf: fileURL)).validated()
    }

    public func save(_ settings: HelperSettings) throws {
        let settings = try settings.validated()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
