import Foundation

/// Answers describe matches only. Neither this service nor the model can
/// install an extension, read its source, or execute its code.
@MainActor
public final class DiscoverySearchEngine {
    public typealias Answer = @MainActor (HelperRequest, HelperSettings) async throws -> AIProviderAnswer
    private let store: DiscoveryCatalogStore
    private let settingsStore: HelperSettingsStore
    private let client = AIProviderClient()
    private let answerOverride: Answer?
    private var ticket: UUID?
    private var cancelled = Set<UUID>()
    private let workingDirectory: URL

    public init(store: DiscoveryCatalogStore = DiscoveryCatalogStore(), settingsStore: HelperSettingsStore = HelperSettingsStore(),
                answer: Answer? = nil) {
        self.store = store; self.settingsStore = settingsStore; answerOverride = answer
        workingDirectory = settingsStore.fileURL.deletingLastPathComponent().appendingPathComponent("Runtime", isDirectory: true)
    }

    public func search(query: String, language: String, onStatus: (@Sendable (String) -> Void)? = nil) async throws -> DiscoverySearchResult {
        guard ticket == nil else { throw LocalGPTError.busy }
        let query = try DiscoveryQuery.validate(query)
        guard AppLocalization.supportedLanguages.contains(where: { $0.code == language }) else { throw DiscoveryError.invalidQuery }
        let id = UUID(); ticket = id
        defer { ticket = nil; cancelled.remove(id) }
        return try await withTaskCancellationHandler {
            do {
                onStatus?("Updating tool catalog…")
                let snapshot = try await store.load()
                try check(id)
                guard !snapshot.index.extensions.isEmpty else {
                    return .init(revision: snapshot.index.revision, updatedAt: snapshot.index.updatedAt, stale: snapshot.stale,
                                 model: "", matches: [], noMatchReason: "No tools are available in the catalog yet.")
                }
                let settings = try settingsStore.load()
                if settings.provider != .chatGPT, settings.model.isEmpty { throw AIProviderError.modelRequired }
                var candidates = snapshot.index.extensions
                if candidates.count > 40 {
                    // Translate/expand the user's own query before local lexical
                    // retrieval. Do not send a large catalog to the model.
                    onStatus?("Understanding your request…")
                    let response = try await ask(["query": query], prompt: "expand", settings: settings, id: id)
                    let expanded = try Self.expansion(response.text)
                    var scores: [String: Double] = [:]
                    for (rank, entry) in DiscoveryKeywordSearch.search(query: query, in: snapshot.index, language: language).enumerated() { scores[entry.id, default: 0] += 1 / Double(rank + 1) }
                    for term in expanded {
                        for (rank, entry) in DiscoveryKeywordSearch.search(query: term, in: snapshot.index, language: language).enumerated() { scores[entry.id, default: 0] += 100 / Double(rank + 1) }
                    }
                    candidates = Array(snapshot.index.extensions.filter { scores[$0.id] != nil }.sorted {
                        scores[$0.id] == scores[$1.id] ? $0.id < $1.id : scores[$0.id]! > scores[$1.id]!
                    }.prefix(40))
                    if candidates.isEmpty {
                        await client.disconnect()
                        return .init(revision: snapshot.index.revision, updatedAt: snapshot.index.updatedAt, stale: snapshot.stale,
                                     model: response.model, matches: [], noMatchReason: "No suitable extension was found.")
                    }
                }
                onStatus?("Comparing matching tools…")
                // Bound the data independently of descriptor limits. Local
                // retrieval selects candidates; full limitations remain visible
                // in the catalog UI and are supplied to ranking when possible.
                var records: [[String: Any]] = []
                for entry in candidates {
                    let record: [String: Any] = ["id": entry.id, "name": entry.name, "summary": entry.summary,
                        "description": String(entry.description.prefix(1200)), "capabilities": Array(entry.capabilities.prefix(8)),
                        "limitations": entry.limitations, "platforms": entry.platforms, "kind": entry.kind]
                    let next = records + [record]
                    if try JSONSerialization.data(withJSONObject: next).count > 160_000 { continue }
                    records = next
                }
                let result = try await ask(["query": query, "answerLanguage": language, "candidates": records], prompt: "rank", settings: settings, id: id)
                let allowed = Set(records.compactMap { $0["id"] as? String })
                let ranked = try Self.matches(result.text, allowed: allowed)
                try check(id)
                await client.disconnect()
                return .init(revision: snapshot.index.revision, updatedAt: snapshot.index.updatedAt, stale: snapshot.stale,
                             model: result.model, matches: ranked.0, noMatchReason: ranked.1)
            } catch {
                await client.disconnect()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.ticket == id else { return }
                self.cancelled.insert(id)
                await self.client.disconnect()
            }
        }
    }

    public func cancel() async {
        guard let ticket else { return }
        cancelled.insert(ticket)
        await client.disconnect()
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        if cancelled.contains(id) { throw CancellationError() }
    }
    private func ask(_ object: [String: Any], prompt: String, settings: HelperSettings, id: UUID) async throws -> AIProviderAnswer {
        try check(id)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let request = HelperRequest(id: id.uuidString, action: .translate, text: text, systemPrompt: try Self.prompt(prompt))
        let result: AIProviderAnswer
        if let answerOverride { result = try await answerOverride(request, settings) }
        else {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            result = try await client.answer(request: request, workingDirectory: workingDirectory, settings: settings)
        }
        try check(id)
        return result
    }

    private static func prompt(_ name: String) throws -> String {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("DiscoveryPrompts/\(name).txt")
        let sidecar = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("DiscoveryPrompts/\(name).txt")
        var files = [bundled, sidecar].compactMap { $0 }
        #if DEBUG
        if let swift = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "DiscoveryPrompts") { files.append(swift) }
        #endif
        guard let file = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = String(data: try SourcePackageRules.boundedData(file, maximum: 16 * 1024), encoding: .utf8) else { throw DiscoveryError.invalidCatalog }
        return text
    }
    nonisolated static func expansion(_ text: String) throws -> [String] {
        guard text.utf8.count <= 8192, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["keywords"], let keywords = object["keywords"] as? [String], (1...8).contains(keywords.count),
              keywords.allSatisfy({ DiscoveryEntry.validText($0, units: 128, bytes: 512) }) else { throw DiscoveryError.invalidMatch }
        return keywords
    }
    nonisolated static func matches(_ text: String, allowed: Set<String>) throws -> ([DiscoveryMatch], String?) {
        guard text.utf8.count <= 32 * 1024, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["matches", "noMatchReason"]), let values = object["matches"] as? [[String: Any]], values.count <= 5 else { throw DiscoveryError.invalidMatch }
        var seen = Set<String>(), matches: [DiscoveryMatch] = []
        for value in values {
            guard Set(value.keys) == ["id", "reason", "fit"], let id = value["id"] as? String,
                  allowed.contains(id), seen.insert(id).inserted, let reason = value["reason"] as? String,
                  DiscoveryEntry.validText(reason, units: 1000, bytes: 4000), let fit = value["fit"] as? String,
                  ["good", "partial"].contains(fit) else { throw DiscoveryError.invalidMatch }
            matches.append(.init(id: id, reason: reason, fit: fit))
        }
        let reason = object["noMatchReason"]
        guard reason == nil || reason is NSNull || (reason is String && DiscoveryEntry.validText(reason as! String, units: 1000, bytes: 4000)) else { throw DiscoveryError.invalidMatch }
        guard !matches.isEmpty || reason is String else { throw DiscoveryError.invalidMatch }
        return (matches, matches.isEmpty ? reason as? String : nil)
    }
}
