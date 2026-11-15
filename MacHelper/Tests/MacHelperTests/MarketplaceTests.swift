import Foundation
import XCTest
@testable import MacHelper

private final class MarketplaceFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [String: Data] = [:]
    static var visited: [URL] = []
    static func reset(_ responses: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        replies = responses; visited = []
    }
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return visited }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let url = request.url!
        Self.visited.append(url)
        let data = Self.replies[url.absoluteString]
        Self.lock.unlock()
        guard let data else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MarketplaceTests: XCTestCase {
    private let identifier = "com.localaibasetools.translation"
    private let catalogURL = URL(string: "https://market.example/extension-market/catalog.json")!

    private func link(catalog: String, id: String = "com.localaibasetools.translation") -> URL {
        var components = URLComponents()
        components.scheme = "machelper"; components.host = "install"
        components.queryItems = [URLQueryItem(name: "catalog", value: catalog), URLQueryItem(name: "extension", value: id)]
        return components.url!
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarketplaceFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacHelperMarketplaceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture() throws -> (SourceCatalogEntry, [String: Data]) {
        let manifest = SourceExtensionManifest(identifier: identifier, displayName: "Translation", version: "4.1.0", summary: "Editable fixture tool",
            permissions: ["selection.read", "ai.transform", "ui.panel"],
            commands: [.init(identifier: "translate", title: "Translate", trigger: "selection")], settingsSchema: "settings.schema.json")
        let files = ["extension.json": try JSONEncoder().encode(manifest),
            "main.js": Data("MacHelper.define({commands:{translate(input){return {text:input.text};}}});".utf8),
            "settings.schema.json": Data(#"{"schemaVersion":1,"fields":[]}"#.utf8),
            "prompts/translate.txt": Data("Preserve meaning.".utf8), "README.md": Data("Complete editable source".utf8), "LICENSE": Data("MIT".utf8)]
        let entry = SourceCatalogEntry(identifier: identifier, displayName: manifest.displayName, version: manifest.version, summary: manifest.summary,
            files: files.keys.sorted().map { .init(path: $0, url: "Translation/" + $0, sha256: SourcePackageRules.digest(files[$0]!), size: files[$0]!.count) })
        return (entry, files)
    }

    private func responses(entry: SourceCatalogEntry, files: [String: Data]) throws -> [String: Data] {
        var result = Dictionary(uniqueKeysWithValues: files.map {
            (catalogURL.deletingLastPathComponent().appendingPathComponent("Translation/" + $0.key).absoluteString, $0.value)
        })
        result[catalogURL.absoluteString] = try JSONEncoder().encode(SourceCatalog(extensions: [entry]))
        return result
    }

    func testInstallLinkDecodesCatalogExactlyOnceAndPreservesItsQuery() throws {
        let catalog = "https://tools.example/path/catalog.json?revision=v1%2B2&channel=stable"
        let request = try MarketplaceInstallRequest(url: link(catalog: catalog))
        XCTAssertEqual(request.catalogURL.absoluteString, catalog)
        XCTAssertEqual(request.extensionID, identifier)
        XCTAssertFalse(request.allowsLocalDevelopment)
    }

    func testInstallLinkRejectsExtraDuplicateAndMalformedComponents() {
        let valid = link(catalog: catalogURL.absoluteString).absoluteString
        let invalid = [
            valid.replacingOccurrences(of: "machelper:", with: "https:"),
            valid.replacingOccurrences(of: "://install?", with: "://other?"),
            valid.replacingOccurrences(of: "://install?", with: "://install/?"),
            valid.replacingOccurrences(of: "://install?", with: "://user@install?"),
            valid.replacingOccurrences(of: "://install?", with: "://install:123?"),
            valid.replacingOccurrences(of: "://install?", with: "://install:?"),
            valid.replacingOccurrences(of: "://install?", with: "://%69nstall?"),
            valid + "&extension=" + identifier,
            valid + "&%63atalog=https%3A%2F%2Fother.example%2Fcatalog.json",
            valid + "&enable=true", valid + "#fragment",
            "machelper://install?extension=" + identifier,
            "machelper://install?catalog=&extension=" + identifier,
        ]
        for text in invalid {
            guard let url = URL(string: text) else { continue }
            XCTAssertThrowsError(try MarketplaceInstallRequest(url: url), text)
        }
        for id in ["../translation", "com.Example.tool", "tool", "com.example.tool/path", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try MarketplaceInstallRequest(url: link(catalog: catalogURL.absoluteString, id: id)))
        }
        XCTAssertThrowsError(try MarketplaceInstallRequest(url: link(catalog: "https://tools.example/" + String(repeating: "x", count: 9000))))
    }

    func testCatalogURLRequiresHTTPSAndExplicitLoopbackDevelopmentOptIn() throws {
        for catalog in ["http://tools.example/catalog.json", "file:///tmp/catalog.json", "javascript:alert(1)",
                        "https://user:password@tools.example/catalog.json", "https://tools.example/catalog.json#fragment", "https://tools.example/%00catalog.json"] {
            XCTAssertThrowsError(try MarketplaceInstallRequest(url: link(catalog: catalog)))
        }
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let url = link(catalog: "http://" + host + ":8765/catalog.json")
            XCTAssertThrowsError(try MarketplaceInstallRequest(url: url))
            XCTAssertTrue(try MarketplaceInstallRequest(url: url, allowLocalDevelopment: true).allowsLocalDevelopment)
        }
        XCTAssertThrowsError(try MarketplaceInstallRequest(url: link(catalog: "http://192.168.0.1/catalog.json"), allowLocalDevelopment: true))
    }

    func testMarketplaceWebsiteMustBeConfiguredWithoutPlaceholder() throws {
        XCTAssertThrowsError(try MarketplaceConfiguration.websiteURL(info: [:]))
        for url in ["https://market.localaibasetools.example", "https://example.com", "http://tools.example", "file:///tmp/market"] {
            XCTAssertThrowsError(try MarketplaceConfiguration.websiteURL(info: [MarketplaceConfiguration.websiteKey: url]))
        }
        let actual = "https://local-ai-extension.nelson007.com/"
        XCTAssertEqual(try MarketplaceConfiguration.websiteURL(info: [MarketplaceConfiguration.websiteKey: actual]).absoluteString, actual)
    }

    func testReviewDownloadsOnlyCatalogAndVerifiedManifestWithoutInstallingSource() async throws {
        let (entry, files) = try fixture()
        MarketplaceFixtureProtocol.reset(try responses(entry: entry, files: files))
        let root = try temporary()
        let request = try MarketplaceInstallRequest(url: link(catalog: catalogURL.absoluteString))
        let preview = try await MarketplaceReviewLoader.load(request, session: session())
        XCTAssertEqual(preview.entry, entry)
        XCTAssertEqual(preview.manifest.permissions, ["selection.read", "ai.transform", "ui.panel"])
        XCTAssertEqual(MarketplaceFixtureProtocol.requests, [catalogURL, catalogURL.deletingLastPathComponent().appendingPathComponent("Translation/extension.json")])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testReviewedInventoryDownloadsCompleteSourceOnlyWhenMaterialized() async throws {
        let (entry, files) = try fixture()
        MarketplaceFixtureProtocol.reset(try responses(entry: entry, files: files))
        let transport = session()
        let request = try MarketplaceInstallRequest(url: link(catalog: catalogURL.absoluteString))
        let preview = try await MarketplaceReviewLoader.load(request, session: transport)
        let store = SourcePackageStore(directory: try temporary().appendingPathComponent("Extensions"), session: transport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.installedURL(for: identifier).path))
        let installed = try await store.materialize(entry: preview.entry, baseURL: preview.request.catalogURL)
        XCTAssertEqual(installed.fileHashes, Dictionary(uniqueKeysWithValues: entry.files.map { ($0.path, $0.sha256) }))
        XCTAssertEqual(Set(MarketplaceFixtureProtocol.requests.map(\.lastPathComponent)), Set(files.keys.map { URL(fileURLWithPath: $0).lastPathComponent }).union(["catalog.json"]))
        let main = installed.rootURL.appendingPathComponent("main.js")
        try Data("// User's local edit".utf8).write(to: main, options: .atomic)
        MarketplaceFixtureProtocol.reset([:])
        let preserved = try await store.materialize(entry: preview.entry, baseURL: preview.request.catalogURL)
        XCTAssertTrue(preserved.isLocallyModified)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "// User's local edit")
        XCTAssertTrue(MarketplaceFixtureProtocol.requests.isEmpty)
    }

    func testReviewRejectsMissingToolTamperedManifestAndUnsafeSourceURLs() async throws {
        let (entry, files) = try fixture()
        let request = try MarketplaceInstallRequest(url: link(catalog: catalogURL.absoluteString))
        MarketplaceFixtureProtocol.reset([catalogURL.absoluteString: try JSONEncoder().encode(SourceCatalog(extensions: []))])
        do { _ = try await MarketplaceReviewLoader.load(request, session: session()); XCTFail("An unlisted tool cannot be installed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not listed")) }
        var tampered = try responses(entry: entry, files: files)
        tampered[catalogURL.deletingLastPathComponent().appendingPathComponent("Translation/extension.json").absoluteString] = Data("{}".utf8)
        MarketplaceFixtureProtocol.reset(tampered)
        do { _ = try await MarketplaceReviewLoader.load(request, session: session()); XCTFail("Manifest hash must be checked before review") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SHA-256")) }
        let unsafe = SourceCatalogEntry(identifier: entry.identifier, displayName: entry.displayName, version: entry.version, summary: entry.summary,
            files: entry.files.map { SourceCatalogFile(path: $0.path, url: $0.path == "main.js" ? "file:///tmp/private.js" : $0.url, sha256: $0.sha256, size: $0.size) })
        MarketplaceFixtureProtocol.reset(try responses(entry: unsafe, files: files))
        do { _ = try await MarketplaceReviewLoader.load(request, session: session()); XCTFail("A catalog cannot read local source files") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        XCTAssertEqual(MarketplaceFixtureProtocol.requests, [catalogURL], "Unsafe inventories should be rejected before fetching even the manifest")
    }

    func testReviewChecksManifestIdentityAndDeclaredRuntimeFiles() async throws {
        let (entry, files) = try fixture()
        let request = try MarketplaceInstallRequest(url: link(catalog: catalogURL.absoluteString))
        for version in ["9.0.0", "4.1.0"] {
            let broken = SourceCatalogEntry(identifier: entry.identifier, displayName: entry.displayName, version: version, summary: entry.summary,
                files: version == "4.1.0" ? entry.files.filter { $0.path != "main.js" } : entry.files)
            MarketplaceFixtureProtocol.reset(try responses(entry: broken, files: files))
            do { _ = try await MarketplaceReviewLoader.load(request, session: session()); XCTFail("Review must validate metadata and complete runtime inventory") }
            catch { XCTAssertTrue(error.localizedDescription.contains("does not match")) }
        }
    }
}
