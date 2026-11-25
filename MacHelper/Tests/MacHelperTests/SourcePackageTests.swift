import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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
    func testBrowserGrantsKeepLegacyChromeAndBindEveryManagedDescriptor() throws {
        let chromeID = String(repeating: "a", count: 32)
        let legacy = try JSONDecoder().decode(SourceCompanionGrant.self,
            from: Data(#"{"chromeExtensionID":"\#(chromeID)","commands":["translate"],"allowsAI":false}"#.utf8))
        let legacyManifest = makeBrowserManifest(.init(chromeExtensionID: chromeID))
        XCTAssertNoThrow(try legacyManifest.validate())
        XCTAssertEqual(legacyManifest.companionGrant, legacy)
        XCTAssertEqual(legacy.browserCompanions, [.init(browser: .chrome, identifier: chromeID)])

        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        let chrome = SourceBrowserCompanion(browser: .chrome, identifier: chromeID,
            storeURL: "https://chromewebstore.google.com/detail/example/" + chromeID,
            packageURL: "https://raw.githubusercontent.com/example/tool/\(revision)/browser/chrome.json", packageSHA256: digest,
            sourceURL: "https://github.com/example/tool/tree/\(revision)/Chrome")
        let edge = SourceBrowserCompanion(browser: .edge, identifier: chromeID,
            storeURL: "https://microsoftedge.microsoft.com/addons/detail/example/" + chromeID)
        let firefox = SourceBrowserCompanion(browser: .firefox, identifier: "tool@example.com",
            storeURL: "https://addons.mozilla.org/en-US/firefox/addon/example/")
        let safari = SourceBrowserCompanion(browser: .safari, identifier: "com.example.tool.safari",
            storeURL: "https://apps.apple.com/us/app/example/id12345")
        let manifest = makeBrowserManifest(.init(browsers: [safari, edge, firefox, chrome]))
        XCTAssertNoThrow(try manifest.validate())
        let grant = try XCTUnwrap(manifest.companionGrant)
        XCTAssertEqual(grant.browserCompanions, [chrome, edge, firefox, safari])
        XCTAssertEqual(try JSONDecoder().decode(SourceCompanionGrant.self, from: JSONEncoder().encode(grant)), grant)
        XCTAssertEqual(makeBrowserManifest(.init(browsers: [chrome, edge, firefox, safari])).companionGrant, grant)
        XCTAssertNotEqual(makeBrowserManifest(.init(browsers: [chrome, edge, firefox])).companionGrant, grant)
        let differentPackage = SourceBrowserCompanion(browser: .chrome, identifier: chromeID, storeURL: chrome.storeURL,
            packageURL: chrome.packageURL, packageSHA256: String(repeating: "c", count: 64), sourceURL: chrome.sourceURL)
        XCTAssertNotEqual(makeBrowserManifest(.init(browsers: [differentPackage, edge, firefox, safari])).companionGrant, grant)
    }

    func testBrowserDeclarationsRejectUnsafeSetupMetadata() throws {
        let identity = String(repeating: "a", count: 32)
        let revision = String(repeating: "f", count: 40)
        let digest = String(repeating: "d", count: 64)
        let url = "https://raw.githubusercontent.com/example/tool/\(revision)/browser/chrome.json"
        for companion: SourceBrowserCompanion in [
            .init(browser: .edge, identifier: "not-the-edge-id"),
            .init(browser: .firefox, identifier: "bad\n@example.com"),
            .init(browser: .safari, identifier: "com..example.tool"),
            .init(browser: .chrome, identifier: identity, storeURL: "https://chromewebstore.google.com.example.net/detail/" + identity),
            .init(browser: .chrome, identifier: identity, storeURL: "https://chromewebstore.google.com/detail/" + String(repeating: "b", count: 32)),
            .init(browser: .chrome, identifier: identity, storeURL: "https://chromewebstore.google.com/detail/" + identity + "?redirect=whatever"),
            .init(browser: .chrome, identifier: identity, packageURL: url),
            .init(browser: .chrome, identifier: identity, packageURL: url, packageSHA256: digest.uppercased()),
            .init(browser: .chrome, identifier: identity, packageURL: "https://raw.githubusercontent.com/example/tool/main/chrome.json", packageSHA256: digest),
            .init(browser: .chrome, identifier: identity, packageURL: "https://raw.githubusercontent.com/example/tool/\(revision)/browser/../chrome.json", packageSHA256: digest),
            .init(browser: .safari, identifier: "com.example.tool.safari", packageURL: url, packageSHA256: digest),
            .init(browser: .chrome, identifier: identity, sourceURL: "https://github.com/example/tool/tree/main/Chrome"),
            .init(browser: .chrome, identifier: identity, sourceURL: "https://github.com/example/tool/tree/\(revision)/%2e%2e/Chrome")
        ] {
            XCTAssertThrowsError(try makeBrowserManifest(.init(browsers: [companion])).validate(), String(describing: companion))
        }
        let duplicate = SourceBrowserCompanion(browser: .chrome, identifier: identity)
        XCTAssertThrowsError(try makeBrowserManifest(.init(browsers: [duplicate, duplicate])).validate())
        XCTAssertThrowsError(try makeBrowserManifest(.init(browsers: [])).validate())
        let mixed = try JSONDecoder().decode(SourceCompanion.self, from: Data(#"{"chromeExtensionID":"\#(identity)","browsers":[{"browser":"chrome","identifier":"\#(identity)"}]}"#.utf8))
        XCTAssertThrowsError(try makeBrowserManifest(mixed).validate())
    }

    private func makeBrowserManifest(_ companion: SourceCompanion) -> SourceExtensionManifest {
        SourceExtensionManifest(identifier: "com.example.browser-tool", displayName: "Browser tool", version: "1.0.0",
            summary: "Browser fixture", permissions: [SourceCompanionGrant.permission],
            commands: [.init(identifier: "translate", title: "Translate", trigger: "companion")], companion: companion)
    }

    func testCommandIconsRemainOptionalAndRoundTripThroughSourceMetadata() throws {
        let old = try JSONDecoder().decode(SourceExtensionCommand.self,
            from: Data(#"{"identifier":"translate","title":"Translate","trigger":"selection"}"#.utf8))
        XCTAssertNil(old.systemSymbolName)
        let command = SourceExtensionCommand(identifier: "translate", title: "Translate", trigger: "selection", systemSymbolName: "character.bubble")
        XCTAssertEqual(try JSONDecoder().decode(SourceExtensionCommand.self, from: JSONEncoder().encode(command)), command)
        for symbol in ["character.bubble", "future.valid-symbol.123"] {
            let manifest = SourceExtensionManifest(identifier: "com.example.icons", displayName: "Icons", version: "1.0.0", summary: "Icon fixture",
                permissions: ["selection.read"], commands: [.init(identifier: "action", title: "Action", trigger: "selection", systemSymbolName: symbol)])
            XCTAssertNoThrow(try manifest.validate())
        }
        for symbol in ["", "pencil\n", "two words", "../icon", "https://example.com/icon", String(repeating: "a", count: 101)] {
            let manifest = SourceExtensionManifest(identifier: "com.example.icons", displayName: "Icons", version: "1.0.0", summary: "Icon fixture",
                permissions: ["selection.read"], commands: [.init(identifier: "action", title: "Action", trigger: "selection", systemSymbolName: symbol)])
            XCTAssertThrowsError(try manifest.validate(), symbol)
        }
    }
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
    private func fixtureFiles(extra: [String: Data] = [:], icon: String? = nil, version: String = "1.0.0") throws -> [String: Data] {
        let manifest = SourceExtensionManifest(identifier: identity, displayName: "Translation", version: version, summary: "Source fixture",
            permissions: ["selection.read", "ai.transform", "ui.panel"],
            commands: [.init(identifier: "translate", title: "Translate", trigger: "selection")], settingsSchema: "settings.schema.json", icon: icon)
        var files = ["extension.json": try JSONEncoder().encode(manifest),
                     "main.js": Data("MacHelper.define({commands:{translate(input){return input;}}});".utf8),
                     "prompts/translate.txt": Data("Preserve numbers.".utf8),
                     "settings.schema.json": Data(#"{"fields":[]}"#.utf8),
                     "README.md": Data("Editable source fixture.".utf8),
                     "LICENSE": Data("MIT".utf8)]
        files.merge(extra) { _, new in new }; return files
    }
    private func entry(_ files: [String: Data], version: String = "1.0.0") -> SourceCatalogEntry {
        .init(identifier: identity, displayName: "Translation", version: version, summary: "Source fixture",
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

    private func iconPNG(width: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testSourceIconIsOptionalAndDownloadedAsVerifiedPresentationData() async throws {
        let parent = try temporary()
        let old = parent.appendingPathComponent("old")
        try write(fixtureFiles(), to: old)
        XCTAssertNil(try SourcePackageInspector.snapshot(at: old).iconData)

        let path = "artwork/tool.png"
        let artwork = try iconPNG()
        let files = try fixtureFiles(extra: [path: artwork], icon: path)
        SourceFixtureURLProtocol.reset(replies(files))
        let store = SourcePackageStore(directory: parent.appendingPathComponent("installed"), session: session())
        let snapshot = try await store.materialize(entry: entry(files), baseURL: baseURL)
        XCTAssertEqual(snapshot.manifest.icon, path)
        XCTAssertEqual(snapshot.iconData, artwork)
        XCTAssertNil(snapshot.resources[path])
        XCTAssertEqual(snapshot.fileHashes[path], SourcePackageRules.digest(artwork))
        XCTAssertEqual(SourcePackageInspector.iconData(at: snapshot.rootURL, matchingIdentifier: identity), artwork)
        XCTAssertNil(SourcePackageInspector.iconData(at: snapshot.rootURL, matchingIdentifier: "com.example.other"))
    }

    func testMissingOrInvalidArtworkFallsBackWithoutBreakingJavaScriptSource() throws {
        let root = try temporary()
        let path = "artwork/tool.png"
        try write(fixtureFiles(icon: path), to: root)
        XCTAssertNil(try SourcePackageInspector.snapshot(at: root).iconData)
        let png = try iconPNG()
        for artwork in [Data(png.prefix(24)), try iconPNG(width: 513), png + Data(repeating: 0, count: 128 * 1024)] {
            try write([path: artwork], to: root)
            let snapshot = try SourcePackageInspector.snapshot(at: root)
            XCTAssertNil(snapshot.iconData)
            XCTAssertNil(snapshot.resources[path])
            XCTAssertEqual(snapshot.fileHashes[path], SourcePackageRules.digest(artwork))
            XCTAssertNil(SourcePackageInspector.iconData(at: root, matchingIdentifier: identity))
        }
        for invalid in ["../tool.png", "https://example.com/tool.png", "artwork/tool.svg"] {
            try write(fixtureFiles(icon: invalid), to: root)
            XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: root))
        }
    }

    func testNativeSourceOnlyAllowsTheDeclaredValidatedBinaryIcon() throws {
        let root = try temporary()
        let path = "artwork/tool.png"
        let artwork = try iconPNG()
        let manifest = SourceExtensionManifest(runtime: "native", identifier: identity, displayName: "Native tool",
            version: "1.0.0", summary: "Native fixture", entryPoint: "Main.swift", permissions: ["native.execute"],
            commands: [.init(identifier: "greet", title: "Greet", trigger: "manual")], icon: path)
        try write(["extension.json": JSONEncoder().encode(manifest), "Main.swift": Data("import Foundation\n".utf8),
                   path: artwork], to: root)
        let snapshot = try SourcePackageInspector.snapshot(at: root)
        XCTAssertEqual(snapshot.iconData, artwork)
        XCTAssertNil(snapshot.resources[path])
        try write(["other.png": artwork], to: root)
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: root), "Other native binary assets remain unsupported")
        try FileManager.default.removeItem(at: root.appendingPathComponent("other.png"))
        try write([path: Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0])], to: root)
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: root), "A PNG path cannot exempt an arbitrary binary")
        XCTAssertEqual(snapshot.iconData, artwork, "The earlier snapshot retains the validated PNG bytes")
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

    func testExplicitUpdateInstallsNewSourceAndRetainsTheEntirePreviousFolder() async throws {
        let (store, installed) = try installUpdateFixture()
        let edited = Data("Keep this local prompt.".utf8)
        let privateNote = Data("A note outside the published inventory.".utf8)
        try edited.write(to: installed.rootURL.appendingPathComponent("prompts/translate.txt"))
        try privateNote.write(to: installed.rootURL.appendingPathComponent(".notes"))
        let expected = try store.snapshot(for: identity)
        XCTAssertTrue(expected.isLocallyModified)

        let newer = try fixtureFiles(extra: ["prompts/translate.txt": Data("A new published prompt.".utf8)], version: "1.1.0")
        SourceFixtureURLProtocol.reset(replies(newer))
        let stage = try await store.stageUpdate(entry: entry(newer, version: "1.1.0"), baseURL: baseURL)
        XCTAssertEqual(try store.snapshot(for: identity).fingerprint, expected.fingerprint)
        let result = try store.commitUpdate(stage, replacing: expected) {
            XCTAssertEqual(try store.snapshot(for: identity).manifest.version, "1.1.0")
        }
        store.discardStagedUpdate(stage)

        XCTAssertEqual(result.snapshot.rootURL.path, installed.rootURL.path)
        XCTAssertEqual(result.snapshot.manifest.version, "1.1.0")
        XCTAssertFalse(result.snapshot.isLocallyModified)
        XCTAssertEqual(result.snapshot.resources["prompts/translate.txt"], "A new published prompt.")
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("prompts/translate.txt")), edited)
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent(".notes")), privateNote)
        XCTAssertEqual(store.discoverInstalled().packages.count, 1)
    }

    func testExplicitUpdateRejectsAnEditMadeAfterTheUpdateWasReviewed() async throws {
        let (store, installed) = try installUpdateFixture()
        let newer = try fixtureFiles(version: "1.1.0")
        SourceFixtureURLProtocol.reset(replies(newer))
        let stage = try await store.stageUpdate(entry: entry(newer, version: "1.1.0"), baseURL: baseURL)
        defer { store.discardStagedUpdate(stage) }

        let edited = "Saved after the download started."
        try Data(edited.utf8).write(to: installed.rootURL.appendingPathComponent("prompts/translate.txt"))
        XCTAssertThrowsError(try store.commitUpdate(stage, replacing: installed) {
            XCTFail("Approvals must not be written for a stale update.")
        })
        XCTAssertEqual(try store.snapshot(for: identity).resources["prompts/translate.txt"], edited)
    }

    func testExplicitUpdateRejectsAStagedPackageChangedAfterVerification() async throws {
        let (store, installed) = try installUpdateFixture()
        let newer = try fixtureFiles(version: "1.1.0")
        SourceFixtureURLProtocol.reset(replies(newer))
        let stage = try await store.stageUpdate(entry: entry(newer, version: "1.1.0"), baseURL: baseURL)
        defer { store.discardStagedUpdate(stage) }

        try Data("Changed staged data.".utf8).write(to: stage.rootURL.appendingPathComponent("prompts/translate.txt"))
        XCTAssertThrowsError(try store.commitUpdate(stage, replacing: installed) {
            XCTFail("Approvals must not be written for a changed staged update.")
        })
        XCTAssertEqual(try store.snapshot(for: identity).fingerprint, installed.fingerprint)
    }

    func testExplicitUpdateRestoresInstalledSourceIfApprovalsCannotBeWritten() async throws {
        let (store, installed) = try installUpdateFixture()
        let newer = try fixtureFiles(version: "1.1.0")
        SourceFixtureURLProtocol.reset(replies(newer))
        let stage = try await store.stageUpdate(entry: entry(newer, version: "1.1.0"), baseURL: baseURL)
        defer { store.discardStagedUpdate(stage) }

        XCTAssertThrowsError(try store.commitUpdate(stage, replacing: installed) {
            XCTAssertEqual(try store.snapshot(for: identity).manifest.version, "1.1.0")
            throw CocoaError(.fileWriteNoPermission)
        }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(try store.snapshot(for: identity).fingerprint, installed.fingerprint)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [identity + ".macsource"])
    }

    func testExplicitUpdateRejectsCorruptDownloadWithoutTouchingInstalledSource() async throws {
        let (store, installed) = try installUpdateFixture()
        let newer = try fixtureFiles(version: "1.1.0")
        var corrupt = newer
        corrupt["main.js"] = Data("Incomplete script".utf8)
        SourceFixtureURLProtocol.reset(replies(corrupt))
        do {
            _ = try await store.stageUpdate(entry: entry(newer, version: "1.1.0"), baseURL: baseURL)
            XCTFail("The corrupt update package must be rejected.")
        } catch {
            XCTAssertEqual(try store.snapshot(for: identity).fingerprint, installed.fingerprint)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [identity + ".macsource"])
        }
    }

    private func installUpdateFixture() throws -> (SourcePackageStore, SourcePackageSnapshot) {
        let parent = try temporary()
        let fixture = parent.appendingPathComponent("release")
        try write(fixtureFiles(), to: fixture)
        let store = SourcePackageStore(directory: parent.appendingPathComponent("Extensions"), session: session())
        return (store, try store.importSource(from: fixture))
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

    func testNativeManifestRequiresExplicitExecutionPermissionAndSwiftEntry() throws {
        let commands = [SourceExtensionCommand(identifier: "greet", title: "Greet", trigger: "manual")]
        let valid = SourceExtensionManifest(runtime: "native", identifier: identity, displayName: "Native tool",
            version: "1.0.0", summary: "Native fixture", entryPoint: "Main.swift", permissions: ["native.execute"], commands: commands)
        XCTAssertNoThrow(try valid.validate())
        for (runtime, entry, permissions) in [
            ("native", "Main.swift", [String]()), ("native", "main.js", ["native.execute"]),
            ("javascript", "main.js", ["native.execute"]), ("shell", "Main.swift", ["native.execute"])
        ] {
            let value = SourceExtensionManifest(runtime: runtime, identifier: identity, displayName: "Tool",
                version: "1.0.0", summary: "Fixture", entryPoint: entry, permissions: permissions, commands: commands)
            XCTAssertThrowsError(try value.validate(), runtime + ":" + entry)
        }
    }

    func testSelectionReplacementRequiresReadAndIsSupportedByBothAdapters() throws {
        for runtime in ["javascript", "native"] {
            let native = runtime == "native"
            let extra = native ? ["native.execute"] : []
            let valid = SourceExtensionManifest(runtime: runtime, identifier: "com.example.polish", displayName: "Polish", version: "1.0.0", summary: "Polish a selection",
                entryPoint: native ? "main.swift" : "main.js",
                permissions: ["selection.read", "selection.replace", "ai.transform", "ui.panel"] + extra,
                commands: [.init(identifier: "polish", title: "Polish", trigger: "selection")])
            XCTAssertNoThrow(try valid.validate())
            let invalid = SourceExtensionManifest(runtime: runtime, identifier: "com.example.polish", displayName: "Polish", version: "1.0.0", summary: "Polish a selection",
                entryPoint: native ? "main.swift" : "main.js", permissions: ["selection.replace"] + extra,
                commands: [.init(identifier: "polish", title: "Polish", trigger: "manual")])
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testSelectionPasteRequiresReadAndReplaceForBothSourceAdapters() throws {
        for runtime in ["javascript", "native"] {
            let extra = runtime == "native" ? ["native.execute"] : []
            for permissions in [["selection.paste"], ["selection.read", "selection.paste"],
                                ["selection.replace", "selection.paste"], ["selection.read", "selection.replace", "selection.paste"]] {
                let value = SourceExtensionManifest(runtime: runtime, identifier: "com.example.paste", displayName: "Paste", version: "1.0.0", summary: "Paste a preview",
                    entryPoint: runtime == "native" ? "main.swift" : "main.js", permissions: permissions + extra,
                    commands: [.init(identifier: "paste", title: "Paste", trigger: "manual")])
                if permissions.count == 3 { XCTAssertNoThrow(try value.validate()) }
                else { XCTAssertThrowsError(try value.validate()) }
            }
        }
    }

    func testPasteApprovalIsExplicitAndDoesNotRepeatAlreadyApprovedReplacement() {
        let replacement = ["selection.read", "selection.replace", "ai.transform", "ui.panel"]
        let paste = replacement + ["selection.paste"]
        XCTAssertEqual(SourceSelectionPermissionReview.required(requested: paste, approved: replacement), .paste)
        XCTAssertEqual(SourceSelectionPermissionReview.required(requested: paste, approved: []), .paste)
        XCTAssertNil(SourceSelectionPermissionReview.required(requested: paste, approved: paste))
        XCTAssertEqual(SourceSelectionPermissionReview.required(requested: replacement, approved: ["selection.read"]), .replacement)
        XCTAssertNil(SourceSelectionPermissionReview.required(requested: replacement, approved: paste))
    }

    func testNativeSourceIsFrozenAndRejectsPrebuiltBinaryInventory() throws {
        let root = try temporary()
        let manifest = SourceExtensionManifest(runtime: "native", identifier: identity, displayName: "Native tool",
            version: "1.0.0", summary: "Native fixture", entryPoint: "Main.swift", permissions: ["native.execute"],
            commands: [.init(identifier: "greet", title: "Greet", trigger: "manual")])
        try write(["extension.json": JSONEncoder().encode(manifest), "Main.swift": Data("import Foundation\n".utf8),
                   "prompts/greet.txt": Data("Original prompt\n".utf8)], to: root)
        let snapshot = try SourcePackageInspector.snapshot(at: root)
        XCTAssertEqual(snapshot.entrySource, "import Foundation\n")
        XCTAssertEqual(snapshot.resources["Main.swift"], snapshot.entrySource)
        XCTAssertEqual(snapshot.resources["prompts/greet.txt"], "Original prompt\n")
        try Data("import Foundation\n".utf8).write(to: root.appendingPathComponent("Extra.swift"))
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: root), "Additional Swift files must not be silently ignored")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Extra.swift"))
        try Data("changed".utf8).write(to: root.appendingPathComponent("Main.swift"))
        XCTAssertEqual(snapshot.entrySource, "import Foundation\n", "Native builds use the frozen generation rather than rereading a mutable file")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0]).write(to: root.appendingPathComponent("prebuilt"))
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: root))
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
