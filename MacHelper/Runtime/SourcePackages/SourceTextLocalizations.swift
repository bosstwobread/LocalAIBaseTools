import Foundation

/// Extension-owned UI labels. Prompt files and settings values never pass through this table.
public struct SourceTextLocalizations: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let translations: [String: [String: String]]

    public init(schemaVersion: Int = 1, translations: [String: [String: String]]) {
        self.schemaVersion = schemaVersion; self.translations = translations
    }

    public func validate() throws {
        guard schemaVersion == 1, translations.count <= 32 else {
            throw SourcePackageError.invalid("The extension UI translation catalog is invalid.")
        }
        for (locale, table) in translations {
            guard locale.range(of: #"^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8}){0,3}$"#, options: .regularExpression) != nil,
                  table.count <= 256,
                  table.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 2000 &&
                      !$0.value.isEmpty && $0.value.utf8.count <= 8000 &&
                      !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
                throw SourcePackageError.invalid("The extension UI translation catalog contains invalid labels.")
            }
        }
    }

    public func text(_ source: String, language: String) -> String {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let code = AppLocalization.match(normalized) ?? normalized
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return translations[code]?[source] ?? translations[base]?[source] ?? translations["en"]?[source] ?? source
    }
}
