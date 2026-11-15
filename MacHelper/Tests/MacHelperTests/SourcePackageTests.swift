import Foundation
import XCTest
@testable import MacHelper

private final class SourceFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let data: Data; var status: Int = 200; var redirect: URL? }
    static let lock = NSLock()
    static var replies: [String: Reply] = [:]
    static var urls: [URL] = []
    static func reset(_ values: [String: Reply]) { lock.lock(); replies = values; urls = []; lock.unlock() }
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.urls.append(request.url!); let reply = Self.replies[request.url!.absoluteString]; Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(reply.data.count)])!
        if let redirect = reply.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SourcePackageTests: XCTestCase {
    private let identity = "com.example.translation"
    private let baseURL = URL(string: "https://source.example/catalog.json")!
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SourceFixtureURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func fixtureFiles(extra: [String: Data] = [:]) throws -> [String: Data] {
        let manifest = SourceExtensionManifest(identifier: identity, displayName: "Translation", version: "1.0.0", summary: "Source fixture",
            permissions: ["selection.read", "ai.transform", "ui.panel"],
            commands: [.init(identifier: "translate", title: "Translate", trigger: "selection")], settingsSchema: "settings.schema.json")
        var files = ["extension.json": try JSONEncoder().encode(manifest),
                     "main.js": Data("MacHelper.define({commands:{translate(input){return input;}}});".utf8),
                     "prompts/translate.txt": Data("Preserve numbers.".utf8),
                     "settings.schema.json": Data(#"{"fields":[]}"#.utf8),
                     "README.md": Data("Editable source fixture.".utf8),
                     "LICENSE": Data("MIT".utf8)]
        files.merge(extra) { _, new in new }; return files
    }
    private func entry(_ files: [String: Data]) -> SourceCatalogEntry {
        .init(identifier: identity, displayName: "Translation", version: "1.0.0", summary: "Source fixture",
              files: files.keys.sorted().map { .init(path: $0, sha256: SourcePackageRules.digest(files[$0]!), size: files[$0]!.count) })
    }
    private func write(_ files: [String: Data], to root: URL) throws {
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
    private func replies(_ files: [String: Data]) -> [String: SourceFixtureURLProtocol.Reply] {
        Dictionary(uniqueKeysWithValues: files.map { (URL(string: $0.key, relativeTo: baseURL)!.absoluteURL.absoluteString, .init(data: $0.value)) })
    }

    func testCatalogListsMetadataWithoutDownloadingAnySource() async throws {
        let files = try fixtureFiles(); let catalog = SourceCatalog(extensions: [entry(files)])
        SourceFixtureURLProtocol.reset([baseURL.absoluteString: .init(data: try JSONEncoder().encode(catalog))])
        let loaded = try await SourceCatalogLoader.load(from: baseURL, session: session())
        XCTAssertEqual(loaded, catalog)
        XCTAssertEqual(SourceFixtureURLProtocol.requests, [baseURL])
    }

    func testEnableDownloadsCompleteSourceOnlyThenActivatesAtomically() async throws {
        let files = try fixtureFiles(); SourceFixtureURLProtocol.reset(replies(files))
        let directory = try temporary().appendingPathComponent("Extensions")
        let store = SourcePackageStore(directory: directory, session: session())
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.installedURL(for: identity).path))
        let result = try await store.materialize(entry: entry(files), baseURL: baseURL)
        XCTAssertEqual(result.fileHashes.count, files.count)
        XCTAssertFalse(result.isLocallyModified)
        XCTAssertEqual(result.resources["prompts/translate.txt"], "Preserve numbers.")
        XCTAssertNotNil(result.resources["settings.schema.json"])
        XCTAssertEqual(try Data(contentsOf: result.rootURL.appendingPathComponent("LICENSE")), files["LICENSE"])
        XCTAssertEqual(Set(SourceFixtureURLProtocol.requests.map(\.absoluteString)), Set(replies(files).keys))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".source-install") }))
    }

    func testReenablePreservesLocalEditsAndDoesNotDownloadUpstreamChanges() async throws {
        let files = try fixtureFiles(); SourceFixtureURLProtocol.reset(replies(files))
        let store = SourcePackageStore(directory: try temporary().appendingPathComponent("Extensions"), session: session())
        let installed = try await store.materialize(entry: entry(files), baseURL: baseURL)
        let edited = "MacHelper.define({commands:{translate(x){return 'USER EDIT';}}});"
        try Data(edited.utf8).write(to: installed.rootURL.appendingPathComponent("main.js"), options: [.atomic])
        SourceFixtureURLProtocol.reset([:])
        let retained = try await store.materialize(entry: entry(files), baseURL: baseURL)
        XCTAssertTrue(retained.isLocallyModified)
        XCTAssertEqual(retained.entrySource, edited)
        XCTAssertTrue(SourceFixtureURLProtocol.requests.isEmpty)
    }

    func testHashMismatchAndPartialFailureNeverInstallAPartialPackage() async throws {
        let files = try fixtureFiles()
        for corrupt in [true, false] {
            var responses = replies(files)
            let main = URL(string: "main.js", relativeTo: baseURL)!.absoluteString
            responses[main] = corrupt ? .init(data: Data("tampered".utf8)) : .init(data: Data(), status: 503)
            SourceFixtureURLProtocol.reset(responses)
            let store = SourcePackageStore(directory: try temporary().appendingPathComponent("Extensions"), session: session())
            do { _ = try await store.materialize(entry: entry(files), baseURL: baseURL); XCTFail("Expected rejection") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.installedURL(for: identity).path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
        }
    }

    func testTraversalDuplicateCaseAndFileDirectoryConflictsAreRejected() throws {
        for paths in [["extension.json", "../outside.js"], ["extension.json", "MAIN.js", "main.js"],
                      ["extension.json", "/tmp/main.js"], ["extension.json", "prompts", "prompts/text.txt"],
                      ["extension.json", "a/./main.js"], ["extension.json", ".hidden/main.js"]] {
            let files = paths.map { SourceCatalogFile(path: $0, sha256: String(repeating: "a", count: 64)) }
            XCTAssertThrowsError(try SourceCatalogEntry(identifier: identity, displayName: "Tool", version: "1.0.0", summary: "Tool", files: files).validate(), paths.description)
        }
    }

    func testManifestRejectsUnsupportedCapabilitiesRuntimeAndMissingSelectionPermission() throws {
        let files = try fixtureFiles(); let original = try JSONSerialization.jsonObject(with: files["extension.json"]!) as! [String: Any]
        for override in [["permissions": ["shell.execute"]], ["runtime": "native"], ["permissions": ["ai.transform"]], ["entryPoint": "../main.js"]] as [[String: Any]] {
            var changed = original; changed.merge(override) { _, new in new }
            let manifest = try JSONDecoder().decode(SourceExtensionManifest.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try manifest.validate())
        }
    }

    func testImportRejectsSymlinkEscapeAndDoesNotReplaceExistingUserSource() throws {
        let parent = try temporary(); let source = parent.appendingPathComponent("source")
        try write(fixtureFiles(), to: source)
        let store = SourcePackageStore(directory: parent.appendingPathComponent("installed"))
        let installed = try store.importSource(from: source)
        XCTAssertFalse(installed.isLocallyModified)
        try Data("USER OWNED EDIT".utf8).write(to: installed.rootURL.appendingPathComponent("prompts/translate.txt"))
        XCTAssertThrowsError(try store.importSource(from: source))
        XCTAssertEqual(try String(contentsOf: installed.rootURL.appendingPathComponent("prompts/translate.txt"), encoding: .utf8), "USER OWNED EDIT")
        let main = source.appendingPathComponent("main.js")
        try FileManager.default.removeItem(at: main)
        let outside = parent.appendingPathComponent("outside.js"); try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: main, withDestinationURL: outside)
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: source))
    }

    func testLocalCatalogCanMaterializeAllSourceWithoutNetwork() async throws {
        let parent = try temporary(); let source = parent.appendingPathComponent("seed")
        let files = try fixtureFiles(); try write(files, to: source)
        let catalogURL = source.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(SourceCatalog(extensions: [entry(files)])).write(to: catalogURL)
        let catalog = try await SourceCatalogLoader.load(from: catalogURL)
        let store = SourcePackageStore(directory: parent.appendingPathComponent("Extensions"))
        let snapshot = try await store.materialize(entry: catalog.extensions[0], baseURL: catalogURL)
        XCTAssertEqual(snapshot.manifest.identifier, identity)
        XCTAssertEqual(snapshot.fileHashes.count, files.count)
    }

    func testRemoteCatalogCannotReadFileURLsOrPlainHTTP() async throws {
        let files = try fixtureFiles()
        for forbidden in ["file:///etc/hosts", "http://insecure.example/main.js"] {
            let catalogFiles = entry(files).files.map { SourceCatalogFile(path: $0.path, url: forbidden, sha256: $0.sha256, size: $0.size) }
            let descriptor = SourceCatalogEntry(identifier: identity, displayName: "Translation", version: "1.0.0", summary: "Source fixture", files: catalogFiles)
            let store = SourcePackageStore(directory: try temporary().appendingPathComponent("Extensions"), session: session())
            SourceFixtureURLProtocol.reset([:])
            do { _ = try await store.materialize(entry: descriptor, baseURL: baseURL); XCTFail("Expected unsafe URL rejection") } catch {}
            XCTAssertTrue(SourceFixtureURLProtocol.requests.isEmpty)
        }
    }

    func testRedirectCannotSwitchSourceAddress() async throws {
        let files = try fixtureFiles()
        SourceFixtureURLProtocol.reset([baseURL.absoluteString: .init(data: Data(), status: 302, redirect: URL(string: "https://other.example/catalog.json"))])
        do { _ = try await SourceCatalogLoader.load(from: baseURL, session: session()); XCTFail("Expected redirect rejection") } catch {}
        XCTAssertEqual(SourceFixtureURLProtocol.requests.count, 1)
        XCTAssertEqual(files.count, 6)
    }

    func testSourceLimitsAndMalformedSettingsSchemaFailBeforeActivation() throws {
        let parent = try temporary()
        for (name, extra) in [("oversized", ["main.js": Data(repeating: 65, count: SourcePackageRules.maximumFileBytes + 1)]),
                              ("schema", ["settings.schema.json": Data("not JSON".utf8)])] {
            let url = parent.appendingPathComponent(name)
            try write(fixtureFiles(extra: extra), to: url)
            XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: url))
        }
    }

    func testIdentifierValidationPreventsDirectoryEscape() throws {
        let store = SourcePackageStore(directory: try temporary())
        for id in ["../outside", "com.example/escape", "tool", "com..tool"] { XCTAssertThrowsError(try store.installedURL(for: id)) }
    }

    func testBrokenPackageDiscoveryKeepsOtherInstalledToolsVisible() throws {
        let parent = try temporary()
        let store = SourcePackageStore(directory: parent.appendingPathComponent("Extensions"))
        let good = try store.installedURL(for: identity)
        try write(fixtureFiles(), to: good)
        let broken = try store.installedURL(for: "com.example.broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{editing".utf8).write(to: broken.appendingPathComponent("extension.json"))
        let discovery = store.discoverInstalled()
        XCTAssertEqual(discovery.packages.map { $0.manifest.identifier }, [identity])
        XCTAssertEqual(discovery.issues.count, 1)
        XCTAssertEqual(discovery.issues[0].identifier, "com.example.broken")
        XCTAssertEqual(discovery.issues[0].rootURL.resolvingSymlinksInPath(), broken.resolvingSymlinksInPath())
    }
}
