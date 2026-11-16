import Foundation

public enum DiscoveryError: LocalizedError, Equatable {
    case unavailable, invalidCatalog, invalidQuery, invalidMatch
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The tool catalog is unavailable. Connect to the internet and try again."
        case .invalidCatalog: return "The tool catalog is invalid."
        case .invalidQuery: return "Describe what you need using at most 2,000 characters."
        case .invalidMatch: return "The AI returned an invalid tool match. Try again or use keyword search."
        }
    }
}

public struct DiscoveryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let slug: String
    public let name: String
    public let version: String
    public let summary: String
    public let description: String
    public let capabilities: [String]
    public let exampleQueries: [String]
    public let keywords: [String]
    public let limitations: [String]
    public let platforms: [String]
    public let kind: String
    public let runtime: String
    public let translations: [String: [String: String]]

    public init(id: String, slug: String, name: String, version: String, summary: String, description: String,
                capabilities: [String] = [], exampleQueries: [String] = [], keywords: [String] = [],
                limitations: [String] = [], platforms: [String] = ["macOS"], kind: String = "mac-source",
                runtime: String = "javascript", translations: [String: [String: String]] = [:]) {
        self.id = id; self.slug = slug; self.name = name; self.version = version; self.summary = summary
        self.description = description; self.capabilities = capabilities; self.exampleQueries = exampleQueries
        self.keywords = keywords; self.limitations = limitations; self.platforms = platforms
        self.kind = kind; self.runtime = runtime; self.translations = translations
    }

    public func validate() throws {
        try SourcePackageRules.validateIdentifier(id)
        guard slug.range(of: #"^[a-z0-9][a-z0-9-]{0,99}$"#, options: .regularExpression) != nil,
              SourcePackageRules.validText(name, limit: 256), SourcePackageRules.validVersion(version),
              Self.validText(summary, units: 2000, bytes: 8000), Self.validText(description, units: 4000, bytes: 16000),
              ["mac-source", "browser"].contains(kind),
              kind == "browser" ? runtime == "browser" : ["javascript", "native"].contains(runtime) else {
            throw DiscoveryError.invalidCatalog
        }
        for (values, count, units, bytes) in [(capabilities, 32, 1000, 4000), (exampleQueries, 8, 1000, 4000),
            (keywords, 32, 128, 512), (limitations, 16, 1000, 4000), (platforms, 8, 128, 512)] {
            guard values.count <= count, values.allSatisfy({ Self.validText($0, units: units, bytes: bytes) }) else {
                throw DiscoveryError.invalidCatalog
            }
        }
        guard !capabilities.isEmpty, !exampleQueries.isEmpty, !platforms.isEmpty else { throw DiscoveryError.invalidCatalog }
        try SourceTextLocalizations(translations: translations).validate()
    }

    public func localized(_ text: String, language: String) -> String {
        SourceTextLocalizations(translations: translations).text(text, language: language)
    }

    static func validText(_ text: String, units: Int, bytes: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= units &&
            text.utf8.count <= bytes && !text.contains("\0")
    }
}

public struct DiscoveryIndex: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: String
    public let updatedAt: String
    public let extensions: [DiscoveryEntry]
    public init(schemaVersion: Int = 1, revision: String, updatedAt: String, extensions: [DiscoveryEntry]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.updatedAt = updatedAt; self.extensions = extensions
    }
    public func validate() throws {
        guard schemaVersion == 1, Self.validRevision(revision), Self.validDate(updatedAt), extensions.count <= 10_000,
              Set(extensions.map(\.id)).count == extensions.count,
              Set(extensions.map(\.slug)).count == extensions.count else { throw DiscoveryError.invalidCatalog }
        try extensions.forEach { try $0.validate() }
    }
    static func validRevision(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    static func validDate(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
}

public struct DiscoveryManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: String
    public let updatedAt: String
    public let indexUrl: String
    public let sha256: String
    public let size: Int
    public init(schemaVersion: Int = 1, revision: String, updatedAt: String, indexUrl: String = "discovery-index.json", sha256: String, size: Int) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.updatedAt = updatedAt
        self.indexUrl = indexUrl; self.sha256 = sha256; self.size = size
    }
    public func validate() throws {
        guard schemaVersion == 1, DiscoveryIndex.validRevision(revision), DiscoveryIndex.validRevision(sha256),
              DiscoveryIndex.validDate(updatedAt), size > 0, size <= DiscoveryCatalogStore.maximumIndexBytes,
              indexUrl == "discovery-index.json" else { throw DiscoveryError.invalidCatalog }
    }
}

public struct DiscoveryCatalogSnapshot: Sendable {
    public let index: DiscoveryIndex
    public let stale: Bool
    public init(index: DiscoveryIndex, stale: Bool) { self.index = index; self.stale = stale }
}

public struct DiscoveryMatch: Codable, Equatable, Sendable {
    public let id: String
    public let reason: String
    public let fit: String
    public init(id: String, reason: String, fit: String = "good") { self.id = id; self.reason = reason; self.fit = fit }
}

public struct DiscoverySearchResult: Codable, Equatable, Sendable {
    public let revision: String
    public let updatedAt: String
    public let stale: Bool
    public let model: String
    public let matches: [DiscoveryMatch]
    public let noMatchReason: String?
    public init(revision: String, updatedAt: String, stale: Bool, model: String, matches: [DiscoveryMatch], noMatchReason: String? = nil) {
        self.revision = revision; self.updatedAt = updatedAt; self.stale = stale; self.model = model
        self.matches = matches; self.noMatchReason = noMatchReason
    }
}

public enum DiscoveryQuery {
    public static func validate(_ value: String) throws -> String {
        guard DiscoveryEntry.validText(value, units: 2000, bytes: 8000) else { throw DiscoveryError.invalidQuery }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DiscoveryKeywordSearch {
    public static func search(query: String, in index: DiscoveryIndex, language: String) -> [DiscoveryEntry] {
        let wanted = normalized(query)
        guard !wanted.isEmpty else { return index.extensions }
        let terms = tokens(wanted)
        return index.extensions.compactMap { entry -> (DiscoveryEntry, Int)? in
            let strong = [entry.name, entry.summary, entry.description] + entry.capabilities + entry.exampleQueries + entry.keywords
            let fields = strong + strong.map { entry.localized($0, language: language) }
            let haystack = normalized(fields.joined(separator: " "))
            let score = (haystack.contains(wanted) ? 100 : 0) + terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return score > 0 ? (entry, score) : nil
        }.sorted { $0.1 == $1.1 ? $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending : $0.1 > $1.1 }.map(\.0)
    }
    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func tokens(_ value: String) -> [String] {
        Array(Set(value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }))
    }
}
