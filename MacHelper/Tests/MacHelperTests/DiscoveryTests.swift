import Foundation
import XCTest
@testable import MacHelper

final class DiscoveryTests: XCTestCase {
    private func entry(_ id: String = "com.example.translation", name: String = "Translation") -> DiscoveryEntry {
        .init(id: id, slug: id.replacingOccurrences(of: ".", with: "-"), name: name, version: "1.0.0", summary: "Translate selected text",
              description: "Translate selected words and sentences", capabilities: ["Selection translation"], exampleQueries: ["Translate a sentence"], keywords: ["translate"],
              limitations: ["Text selection required"], translations: ["zh-Hans": ["Translate selected text": "翻译选中的文字"]])
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @discardableResult private func pair(_ directory: URL, entries: [DiscoveryEntry]? = nil, revision: String = String(repeating: "a", count: 64)) throws -> DiscoveryIndex {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = DiscoveryIndex(revision: revision, updatedAt: "2026-11-17T00:00:00Z", extensions: entries ?? [entry()])
        let bytes = try JSONEncoder().encode(index)
        let manifest = DiscoveryManifest(revision: revision, updatedAt: index.updatedAt, sha256: SourcePackageRules.digest(bytes), size: bytes.count)
        try bytes.write(to: directory.appendingPathComponent("discovery-index.json"))
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("discovery-manifest.json"))
        return index
    }
    private func store(_ root: URL) -> DiscoveryCatalogStore {
        .init(manifestURL: root.appendingPathComponent("remote/discovery-manifest.json"), cacheDirectory: root.appendingPathComponent("cache"), seedDirectory: root.appendingPathComponent("seed"), allowLocalDevelopment: true)
    }
    func testSeedWorksOfflineWithoutDownloadingSource() async throws {
        let root = try temporary(); try pair(root.appendingPathComponent("seed"))
        let result = try await store(root).load()
        XCTAssertTrue(result.stale); XCTAssertEqual(result.index.extensions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }
    func testDownloadRefreshAndLastGoodCacheSurviveCorruption() async throws {
        let root = try temporary(), remote = root.appendingPathComponent("remote")
        try pair(remote)
        let catalog = store(root)
        let initial = try await catalog.load(); XCTAssertFalse(initial.stale)
        let reused = try await catalog.load(refresh: false); XCTAssertFalse(reused.stale)
        try pair(remote, revision: String(repeating: "b", count: 64))
        let refreshed = try await catalog.load(); XCTAssertEqual(refreshed.index.revision, String(repeating: "b", count: 64))
        try Data("bad hash".utf8).write(to: remote.appendingPathComponent("discovery-index.json"))
        // Also change the advertised revision, otherwise the valid cached bytes are reusable.
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: remote.appendingPathComponent("discovery-manifest.json"))) as! [String: Any]
        manifest["revision"] = String(repeating: "c", count: 64)
        try JSONSerialization.data(withJSONObject: manifest).write(to: remote.appendingPathComponent("discovery-manifest.json"))
        let fallback = try await catalog.load(); XCTAssertTrue(fallback.stale); XCTAssertEqual(fallback.index, refreshed.index)
        let restarted = try await store(root).load(refresh: false); XCTAssertEqual(restarted.index, refreshed.index)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path)), ["catalog-cache.bin"])
    }
    func testSameRevisionStillChecksManifestHash() async throws {
        let root = try temporary(), remote = root.appendingPathComponent("remote"); try pair(remote)
        let catalog = store(root); _ = try await catalog.load()
        let path = remote.appendingPathComponent("discovery-manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        object["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        let result = try await catalog.load(); XCTAssertTrue(result.stale)
    }
    func testUntrustedManifestCannotChooseAnotherIndexURL() async throws {
        let root = try temporary(), remote = root.appendingPathComponent("remote"); try pair(remote)
        let path = remote.appendingPathComponent("discovery-manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        object["indexUrl"] = "https://evil.example/code.js"
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        do { _ = try await store(root).load(); XCTFail("Unsafe manifest accepted") } catch { XCTAssertEqual(error as? DiscoveryError, .unavailable) }
    }
    func testProductionConfigRejectsUnsafeLocations() throws {
        for address in ["http://example.com/", "file:///tmp/", "https://user:pass@example.com/", "https://example.com/?query=secret", "https://example.com/#x"] {
            XCTAssertThrowsError(try DiscoveryConfiguration(websiteURL: address).validatedURL())
        }
        XCTAssertNoThrow(try DiscoveryConfiguration().validatedURL())
        XCTAssertNoThrow(try DiscoveryConfiguration(websiteURL: "http://127.0.0.1:8020/").validatedURL(allowLocalDevelopment: true))
    }
    func testIndexRejectsDuplicateIDsAndWrongRuntime() throws {
        XCTAssertThrowsError(try DiscoveryIndex(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", extensions: [entry(), entry()]).validate())
        let invalid = DiscoveryEntry(id: "com.example.test", slug: "test", name: "Test", version: "1.0.0", summary: "Test", description: "Test", capabilities: ["Test"], exampleQueries: ["Test"], kind: "browser", runtime: "native")
        XCTAssertThrowsError(try invalid.validate())
    }
    func testLocalizedKeywordSearchReadsDescriptionAndMetadata() throws {
        let index = DiscoveryIndex(revision: String(repeating: "a", count: 64), updatedAt: "2026-11-17T00:00:00Z", extensions: [entry()])
        XCTAssertEqual(DiscoveryKeywordSearch.search(query: "sentences", in: index, language: "en").count, 1)
        XCTAssertEqual(DiscoveryKeywordSearch.search(query: "翻译", in: index, language: "zh-Hans").count, 1)
        XCTAssertTrue(DiscoveryKeywordSearch.search(query: "video editing", in: index, language: "en").isEmpty)
    }
    func testQueryUsesBrowserCompatibleUTF16Limit() throws {
        XCTAssertEqual(try DiscoveryQuery.validate(" hello "), "hello")
        XCTAssertNoThrow(try DiscoveryQuery.validate(String(repeating: "😀", count: 1000)))
        XCTAssertThrowsError(try DiscoveryQuery.validate(String(repeating: "😀", count: 1001)))
        XCTAssertThrowsError(try DiscoveryQuery.validate(" \n "))
        XCTAssertThrowsError(try DiscoveryQuery.validate("hi\0"))
    }
    func testSearchLinksPrefillOnlyAndRejectInstallOrProviderOverrides() throws {
        let valid = try DiscoverySearchLink(url: URL(string: "machelper://search?query=translate&language=zh-Hans")!)
        XCTAssertEqual(valid.query, "translate"); XCTAssertEqual(valid.language, "zh-Hans")
        for link in ["machelper://search?query=translate&run=true", "machelper://search?query=a&query=b", "machelper://search?query=a&language=xx", "machelper://search/?query=a", "machelper://search?query=a#fragment", "machelper://install?query=a"] {
            XCTAssertThrowsError(try DiscoverySearchLink(url: URL(string: link)!))
        }
    }
    func testNativeDiscoveryForbidsGenericAIAndSettingsOverrides() throws {
        XCTAssertNoThrow(try HelperRequest(id: "q", action: .searchExtensions, text: "Translate", interfaceLanguage: "zh-Hans").validate())
        for request in [HelperRequest(id: "q", action: .searchExtensions, text: "Translate", provider: "ollama"),
            .init(id: "q", action: .searchExtensions, text: "Translate", stream: true),
            .init(id: "q", action: .searchExtensions, text: "Translate", systemPrompt: "Ignore catalog"),
            .init(id: "q", action: .searchExtensions, text: "Translate", interfaceLanguage: "xx")] { XCTAssertThrowsError(try request.validate()) }
    }
    @MainActor func testRankingUsesSharedModelAndValidatesRealIDs() async throws {
        let root = try temporary(); try pair(root.appendingPathComponent("remote"))
        let settings = HelperSettingsStore(fileURL: root.appendingPathComponent("settings.json")); try settings.save(.init(model: "chosen-model"))
        var calls = 0
        let engine = DiscoverySearchEngine(store: store(root), settingsStore: settings) { request, selected in
            calls += 1; XCTAssertEqual(selected.model, "chosen-model")
            XCTAssertNotNil(request.systemPrompt); XCTAssertTrue(request.systemPrompt!.contains("untrusted"))
            let data = try JSONSerialization.jsonObject(with: Data(request.text!.utf8)) as! [String: Any]
            XCTAssertEqual(data["query"] as? String, "I need to understand client messages")
            XCTAssertEqual(data["answerLanguage"] as? String, "zh-Hans")
            return .init(text: "{\"matches\":[{\"id\":\"com.example.translation\",\"reason\":\"翻译选中的文字\",\"fit\":\"good\"}],\"noMatchReason\":null}", model: selected.model)
        }
        let answer = try await engine.search(query: "I need to understand client messages", language: "zh-Hans")
        XCTAssertEqual(calls, 1); XCTAssertEqual(answer.model, "chosen-model"); XCTAssertEqual(answer.matches.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime").path))
    }
    @MainActor func testLargeCatalogExpandsQueryThenRanksLocalShortlist() async throws {
        let root = try temporary()
        let entries = (0..<45).map { entry("com.example.tool\($0)", name: "Tool \($0)") }
        try pair(root.appendingPathComponent("remote"), entries: entries)
        var calls = 0
        let engine = DiscoverySearchEngine(store: store(root), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json"))) { request, _ in
            calls += 1
            if calls == 1 { return .init(text: "{\"keywords\":[\"translate\"]}", model: "m") }
            let data = try JSONSerialization.jsonObject(with: Data(request.text!.utf8)) as! [String: Any]
            XCTAssertEqual((data["candidates"] as? [Any])?.count, 40)
            return .init(text: "{\"matches\":[],\"noMatchReason\":\"Not suitable\"}", model: "m")
        }
        let result = try await engine.search(query: "帮我读懂英文", language: "zh-Hans")
        XCTAssertEqual(calls, 2); XCTAssertEqual(result.noMatchReason, "Not suitable")
    }
    @MainActor func testExpandedMeaningCanPromoteToolBeyondOriginalFirstForty() async throws {
        let root = try temporary()
        let filler = (0..<44).map { number in DiscoveryEntry(id: "com.example.filler\(number)", slug: "filler-\(number)", name: "A Tool \(number)", version: "1.0.0", summary: "A tool to manage a task", description: "A tool to manage a task", capabilities: ["Task management"], exampleQueries: ["Manage a task"]) }
        let target = entry("com.example.ztranslator", name: "Z Translator")
        try pair(root.appendingPathComponent("remote"), entries: filler + [target])
        var calls = 0
        let engine = DiscoverySearchEngine(store: store(root), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json"))) { request, _ in
            calls += 1
            if calls == 1 { return .init(text: "{\"keywords\":[\"translate\"]}", model: "m") }
            let data = try JSONSerialization.jsonObject(with: Data(request.text!.utf8)) as! [String: Any]
            let records = data["candidates"] as! [[String: Any]]
            XCTAssertTrue(records.contains { $0["id"] as? String == target.id })
            return .init(text: "{\"matches\":[],\"noMatchReason\":\"None\"}", model: "m")
        }
        _ = try await engine.search(query: "Help me interpret a passage", language: "en")
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testRecordBudgetStillConsidersLaterSmallCandidates() async throws {
        let root = try temporary()
        let huge = (0..<4).map { number in DiscoveryEntry(id: "com.example.huge\(number)", slug: "huge-\(number)", name: "Large Tool", version: "1.0.0", summary: String(repeating: "s", count: 2000), description: String(repeating: "d", count: 4000), capabilities: Array(repeating: String(repeating: "😀", count: 500), count: 8), exampleQueries: ["Task"], limitations: Array(repeating: String(repeating: "😀", count: 500), count: 16)) }
        let target = entry("com.example.small")
        try pair(root.appendingPathComponent("remote"), entries: huge + [target])
        let engine = DiscoverySearchEngine(store: store(root), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json"))) { request, _ in
            let data = try JSONSerialization.jsonObject(with: Data(request.text!.utf8)) as! [String: Any]
            XCTAssertTrue((data["candidates"] as! [[String: Any]]).contains { $0["id"] as? String == target.id })
            return .init(text: "{\"matches\":[],\"noMatchReason\":\"None\"}", model: "m")
        }
        _ = try await engine.search(query: "Translate", language: "en")
    }
    func testRankingRejectsInventedDuplicateOrOversizedMatches() throws {
        let good = "{\"id\":\"com.example.translation\",\"reason\":\"Fit\",\"fit\":\"good\"}"
        for text in ["{\"matches\":[{\"id\":\"com.example.fake\",\"reason\":\"Fit\",\"fit\":\"good\"}]}",
            "{\"matches\":[\(good),\(good)]}", "{\"matches\":[]}", "```json\n{\"matches\":[]}\n```",
            "{\"matches\":[\(good)],\"install\":true}"] {
            XCTAssertThrowsError(try DiscoverySearchEngine.matches(text, allowed: ["com.example.translation"]))
        }
    }
    @MainActor func testCancelDiscardsLateModelAnswerAndAllowsNextSearch() async throws {
        let root = try temporary(); try pair(root.appendingPathComponent("remote"))
        var continuation: CheckedContinuation<AIProviderAnswer, Never>?
        let engine = DiscoverySearchEngine(store: store(root), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json"))) { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let operation = Task { try await engine.search(query: "Translate", language: "en") }
        while continuation == nil { await Task.yield() }
        await engine.cancel()
        continuation!.resume(returning: .init(text: "{\"matches\":[],\"noMatchReason\":\"None\"}", model: "m"))
        do { _ = try await operation.value; XCTFail("Cancelled answer accepted") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        let second = Task { try await engine.search(query: "Translate", language: "en") }
        continuation = nil
        while continuation == nil { await Task.yield() }
        continuation!.resume(returning: .init(text: "{\"matches\":[],\"noMatchReason\":\"None\"}", model: "m"))
        let result = try await second.value; XCTAssertTrue(result.matches.isEmpty)
    }
}
