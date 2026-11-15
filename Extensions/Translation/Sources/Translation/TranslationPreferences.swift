import Foundation

struct TranslationPreferences: Codable, Equatable {
    var schemaVersion = 1
    var targetLanguage: String
}

/// Extension-owned settings contain only the target language, never selections
/// or translation output. The host supplies the extension's storage directory.
final class TranslationPreferencesStore {
    private let legacyDefaults: UserDefaults
    private let previousApplicationDefaults: UserDefaults?
    private(set) var targetLanguage: String
    private var settingsURL: URL?
    private let legacyKey = "Translation.targetLanguage"

    init(legacyDefaults: UserDefaults = .standard,
         previousApplicationDefaults: UserDefaults? = UserDefaults(suiteName: "com.localaibasetools.translation")) {
        self.legacyDefaults = legacyDefaults
        self.previousApplicationDefaults = previousApplicationDefaults
        let candidates = [legacyDefaults.string(forKey: legacyKey), previousApplicationDefaults?.string(forKey: legacyKey)]
        targetLanguage = candidates.compactMap { $0 }.first(where: Self.supported) ?? "zh-CN"
    }

    func configure(directory: URL) throws {
        settingsURL = directory.appendingPathComponent("settings.json")
        guard let settingsURL else { return }
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            guard data.count <= 16_384 else { throw TranslationError.invalid("Translation settings are too large. Choose a target language to reset them.") }
            let settings = try JSONDecoder().decode(TranslationPreferences.self, from: data)
            guard settings.schemaVersion == 1, Self.supported(settings.targetLanguage) else {
                throw TranslationError.invalid("Translation settings use an unsupported format or language. Choose a target language to reset them.")
            }
            targetLanguage = settings.targetLanguage
        } else {
            // The first hosted launch migrates the old standalone app's language.
            try persist()
        }
    }

    func setTargetLanguage(_ code: String) throws {
        guard Self.supported(code) else { throw TranslationError.invalid("Choose a supported target language.") }
        targetLanguage = code
        if settingsURL != nil { try persist() }
        else { legacyDefaults.set(code, forKey: legacyKey) }
    }

    private func persist() throws {
        guard let settingsURL else { return }
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(TranslationPreferences(targetLanguage: targetLanguage)).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private static func supported(_ code: String) -> Bool {
        TranslationLanguage.all.contains { $0.code == code }
    }
}
