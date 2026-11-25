import Foundation
import XCTest
import Darwin
@testable import MacHelper

final class BrowserSupportInstallerTests: XCTestCase {
    private let helper = "Library/Application Support/LocalAIBaseTools/MacHelper"
    private let chrome = "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    private let edge = "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    private let customID = String(repeating: "a", count: 32)
    private let legacyID = String(repeating: "b", count: 32)

    private func fixture() throws -> (URL, URL, BrowserSupportInstaller) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserSupportInstallerTests-" + UUID().uuidString)
        let app = home.appendingPathComponent("Applications/LocalAIBaseTools/MacHelper.app")
        try write(Data("embedded helper fixture".utf8), to: app.appendingPathComponent("Contents/MacOS/mac-helper-host"), mode: 0o700)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, app, BrowserSupportInstaller(homeDirectory: home))
    }

    private func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func permissions(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    private func manifest(_ url: URL) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }

    func testFreshInstalledAppRegistersBothBrowsersAndAliasesWithPrivateFiles() throws {
        let (home, app, installer) = try fixture()
        let installed = try installer.install(from: app, additionalExtensionIDs: [customID])
        XCTAssertEqual(installed.binaryURL, home.appendingPathComponent(helper + "/mac-helper-host"))
        XCTAssertEqual(try Data(contentsOf: installed.binaryURL), Data("embedded helper fixture".utf8))
        XCTAssertEqual(installed.extensionIDs, (BrowserSupportInstaller.defaultExtensionIDs + [customID]).sorted())
        XCTAssertEqual(installed.manifestURLs.count, 4)
        for folder in [chrome, edge] {
            for name in [BrowserSupportInstaller.hostName, BrowserSupportInstaller.legacyHostName] {
                let url = home.appendingPathComponent(folder + "/" + name + ".json")
                let value = try manifest(url)
                XCTAssertEqual(value["name"] as? String, name)
                XCTAssertEqual(value["path"] as? String, installed.binaryURL.path)
                XCTAssertEqual(value["type"] as? String, "stdio")
                XCTAssertEqual(value["allowed_origins"] as? [String], installed.extensionIDs.map { "chrome-extension://" + $0 + "/" })
                XCTAssertEqual(try permissions(url), 0o600)
            }
        }
        XCTAssertEqual(try permissions(installed.binaryURL), 0o700)
        XCTAssertEqual(try permissions(home.appendingPathComponent(helper)), 0o700)
        XCTAssertEqual(try permissions(home.appendingPathComponent(helper + "/allowed-extension-ids.json")), 0o600)
        let remaining = try FileManager.default.subpathsOfDirectory(atPath: home.path)
        XCTAssertFalse(remaining.contains { $0.contains(".mac-helper-install-") })
    }

    func testUpgradePreservesCurrentAuthorizationAndSettingsWithoutResurrectingLegacyIDs() throws {
        let (home, app, installer) = try fixture()
        let first = try installer.install(from: app, additionalExtensionIDs: [legacyID])
        let settings = home.appendingPathComponent(helper + "/settings.json")
        let sourceState = home.appendingPathComponent(helper + "/source-extensions.json")
        let originalSettings = Data(#"{"provider":"ollama","model":"my-model","baseURL":"http://127.0.0.1:11434"}"#.utf8)
        try write(originalSettings, to: settings)
        try write(Data("retained source state".utf8), to: sourceState)
        try write(try json([customID]), to: home.appendingPathComponent(helper + "/allowed-extension-ids.json"))
        try write(try json([legacyID]), to: home.appendingPathComponent("Library/Application Support/MessageHelper/allowed-extension-ids.json"))
        let unrelated = home.appendingPathComponent(chrome + "/org.example.other-host.json")
        try write(Data("unrelated registration".utf8), to: unrelated)
        let before = try FileHandle(forReadingFrom: first.binaryURL)
        defer { try? before.close() }
        try write(Data("new embedded helper fixture".utf8), to: app.appendingPathComponent("Contents/MacOS/mac-helper-host"), mode: 0o700)
        let updated = try installer.install(from: app)
        XCTAssertEqual(updated.extensionIDs, (BrowserSupportInstaller.defaultExtensionIDs + [customID]).sorted())
        XCTAssertEqual(try before.readToEnd(), Data("embedded helper fixture".utf8), "An existing native-host connection keeps its old inode during an atomic upgrade")
        XCTAssertEqual(try Data(contentsOf: updated.binaryURL), Data("new embedded helper fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: settings), originalSettings)
        XCTAssertEqual(try String(contentsOf: sourceState, encoding: .utf8), "retained source state")
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated registration")
        XCTAssertFalse((try manifest(updated.manifestURLs[0])["allowed_origins"] as? [String] ?? []).contains("chrome-extension://" + legacyID + "/"))
    }

    func testFirstMigrationKeepsValidatedLegacyAllowlist() throws {
        let (home, app, installer) = try fixture()
        let legacy = home.appendingPathComponent("Library/Application Support/MessageHelper/allowed-extension-ids.json")
        let legacyData = try json([customID, legacyID])
        try write(legacyData, to: legacy)
        let result = try installer.install(from: app)
        XCTAssertEqual(Set(result.extensionIDs), Set(BrowserSupportInstaller.defaultExtensionIDs + [customID, legacyID]))
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData)
    }

    func testInvalidAllowlistFailsBeforeChangingBinaryOrRegistrations() throws {
        let (home, app, installer) = try fixture()
        let result = try installer.install(from: app)
        let oldBinary = try Data(contentsOf: result.binaryURL)
        let oldManifest = try Data(contentsOf: result.manifestURLs[0])
        let config = home.appendingPathComponent(helper + "/allowed-extension-ids.json")
        for invalid in [try json(["*"]), Data("not json".utf8), try json(["extension": customID])] {
            try write(invalid, to: config)
            XCTAssertThrowsError(try installer.install(from: app))
            XCTAssertEqual(try Data(contentsOf: config), invalid)
            XCTAssertEqual(try Data(contentsOf: result.binaryURL), oldBinary)
            XCTAssertEqual(try Data(contentsOf: result.manifestURLs[0]), oldManifest)
        }
        XCTAssertThrowsError(try installer.install(from: app, additionalExtensionIDs: [String(repeating: "z", count: 32)]))
    }

    func testPublicDiscoverySeedsAreInstalledAtomicallyWithoutReplacingUserSettingsOrCache() throws {
        let (home, app, installer) = try fixture()
        let sourceConfig = app.appendingPathComponent("Contents/MacOS/discovery-config.json")
        let sourceIndex = app.appendingPathComponent("Contents/Resources/Discovery/discovery-index.json")
        let sourceManifest = app.appendingPathComponent("Contents/Resources/Discovery/discovery-manifest.json")
        let config = try json(["schemaVersion": 1, "websiteURL": "https://local-ai-extension.nelson007.com/"])
        let index = try json(["schemaVersion": 1, "extensions": []])
        let manifest = try json(["schemaVersion": 1, "revision": "original"])
        for (url, data) in [(sourceConfig, config), (sourceIndex, index), (sourceManifest, manifest)] { try write(data, to: url) }
        _ = try installer.install(from: app)
        let settings = home.appendingPathComponent(helper + "/settings.json")
        let cache = home.appendingPathComponent(helper + "/discovery-cache.json")
        try write(Data("user settings fixture".utf8), to: settings)
        try write(Data("cached public metadata fixture".utf8), to: cache)
        let installedIndex = home.appendingPathComponent(helper + "/discovery-index.json")
        let previous = try FileHandle(forReadingFrom: installedIndex)
        defer { try? previous.close() }
        let updatedIndex = try json(["schemaVersion": 1, "extensions": [["id": "new"]]])
        try write(updatedIndex, to: sourceIndex)
        _ = try installer.install(from: app)
        XCTAssertEqual(try previous.readToEnd(), index, "An existing reader retains the complete old inode")
        for (name, data) in [("discovery-config.json", config), ("discovery-index.json", updatedIndex), ("discovery-manifest.json", manifest)] {
            let installed = home.appendingPathComponent(helper + "/" + name)
            XCTAssertEqual(try Data(contentsOf: installed), data)
            XCTAssertEqual(try permissions(installed), 0o600)
        }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "user settings fixture")
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "cached public metadata fixture")
    }

    func testDiscoveryPromptResourcesAreCopiedVerbatim() throws {
        let (home, app, installer) = try fixture()
        let original = Data("  Owned prompt\n中文  ".utf8)
        for name in ["rank.txt", "expand.txt"] { try write(original, to: app.appendingPathComponent("Contents/Resources/DiscoveryPrompts/" + name)) }
        _ = try installer.install(from: app)
        for name in ["rank.txt", "expand.txt"] {
            let copied = home.appendingPathComponent(helper + "/DiscoveryPrompts/" + name)
            XCTAssertEqual(try Data(contentsOf: copied), original)
            XCTAssertEqual(try permissions(copied), 0o600)
        }
    }

    func testInvalidDiscoveryJSONOrOversizedConfigPreservesExistingInstallation() throws {
        let (home, app, installer) = try fixture()
        let installed = try installer.install(from: app)
        let previousBinary = try Data(contentsOf: installed.binaryURL)
        let previousRegistration = try Data(contentsOf: installed.manifestURLs[0])
        let source = app.appendingPathComponent("Contents/MacOS/discovery-config.json")
        try write(Data("updated helper fixture".utf8), to: app.appendingPathComponent("Contents/MacOS/mac-helper-host"), mode: 0o700)
        for invalid in [Data("invalid".utf8), Data("[]".utf8), Data(repeating: 32, count: 64 * 1024 + 1)] {
            try write(invalid, to: source)
            XCTAssertThrowsError(try installer.install(from: app))
            XCTAssertEqual(try Data(contentsOf: installed.binaryURL), previousBinary)
            XCTAssertEqual(try Data(contentsOf: installed.manifestURLs[0]), previousRegistration)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(helper + "/discovery-config.json").path))
    }

    func testDiscoverySourceAndDestinationSymlinksAreRejectedBeforeUpgrade() throws {
        for embedded in [true, false] {
            let (home, app, installer) = try fixture()
            let installed = try installer.install(from: app)
            let outside = home.appendingPathComponent("outside.json")
            let outsideData = Data(#"{"private":"must remain unchanged"}"#.utf8)
            try write(outsideData, to: outside)
            let link = embedded ? app.appendingPathComponent("Contents/Resources/Discovery/discovery-index.json")
                : home.appendingPathComponent(helper + "/discovery-index.json")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try write(Data("updated helper fixture".utf8), to: app.appendingPathComponent("Contents/MacOS/mac-helper-host"), mode: 0o700)
            XCTAssertThrowsError(try installer.install(from: app))
            XCTAssertEqual(try Data(contentsOf: outside), outsideData)
            XCTAssertEqual(try Data(contentsOf: installed.binaryURL), Data("embedded helper fixture".utf8))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        }
    }

    func testCustomOrInvalidOwnedNameRegistrationIsPreservedBeforeAnyUpgrade() throws {
        let (home, app, installer) = try fixture()
        let installed = try installer.install(from: app)
        let host = home.appendingPathComponent(edge + "/" + BrowserSupportInstaller.hostName + ".json")
        var custom = try manifest(host)
        custom["path"] = "/usr/local/bin/user-custom-helper"
        let data = try json(custom)
        try write(data, to: host)
        try write(Data("updated bundle fixture".utf8), to: app.appendingPathComponent("Contents/MacOS/mac-helper-host"), mode: 0o700)
        XCTAssertThrowsError(try installer.install(from: app))
        XCTAssertEqual(try Data(contentsOf: host), data)
        XCTAssertEqual(try Data(contentsOf: installed.binaryURL), Data("embedded helper fixture".utf8))
        custom["path"] = installed.binaryURL.path
        custom["allowed_origins"] = ["chrome-extension://*/"]
        try write(try json(custom), to: host)
        XCTAssertThrowsError(try installer.install(from: app))
        XCTAssertEqual(try Data(contentsOf: installed.binaryURL), Data("embedded helper fixture".utf8))
    }

    func testDirectoryAndFinalFileSymlinksCannotRedirectInstallerWrites() throws {
        for target in ["Library/Application Support/Google/Chrome", helper + "/allowed-extension-ids.json", helper + "/mac-helper-host"] {
            let (home, app, installer) = try fixture()
            let outside = home.appendingPathComponent("outside")
            let link = home.appendingPathComponent(target)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if target.hasSuffix("Chrome") { try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true) }
            else { try write(Data("untouched outside file".utf8), to: outside) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try installer.install(from: app), target)
            XCTAssertTrue((try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
            if target.hasSuffix("Chrome") { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty) }
            else { XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched outside file") }
        }
    }

    func testUninstalledOrSymlinkedApplicationDoesNotInstallSupport() throws {
        let (home, app, installer) = try fixture()
        let downloads = home.appendingPathComponent("Downloads/MacHelper.app")
        try FileManager.default.createDirectory(at: downloads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: downloads)
        XCTAssertThrowsError(try installer.install(from: downloads)) { XCTAssertEqual($0 as? BrowserSupportError, .notInstalled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(helper).path))
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: downloads)
        XCTAssertThrowsError(try installer.install(from: app))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(helper).path))
    }

    func testInstalledLocationPolicyIncludesBothStandardAndLocalAIBaseToolsFolders() throws {
        let (home, _, _) = try fixture()
        for path in [home.appendingPathComponent("Applications/MacHelper.app"), home.appendingPathComponent("Applications/LocalAIBaseTools/MacHelper.app"),
                     URL(fileURLWithPath: "/Applications/MacHelper.app"), URL(fileURLWithPath: "/Applications/LocalAIBaseTools/MacHelper.app")] {
            XCTAssertTrue(BrowserSupportInstaller.isInstalledApplication(path, homeDirectory: home), path.path)
        }
        for path in [home.appendingPathComponent("Downloads/MacHelper.app"), home.appendingPathComponent("Applications/OtherFolder/MacHelper.app"),
                     home.appendingPathComponent("Applications/not-an-app")] {
            XCTAssertFalse(BrowserSupportInstaller.isInstalledApplication(path, homeDirectory: home))
        }
    }

    func testDeniedDirectoryReportsExactOperationPathAndPOSIXError() throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX permission denial cannot be simulated as root") }
        let (home, app, installer) = try fixture()
        let denied = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        XCTAssertThrowsError(try installer.install(from: app)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("open directory for search without following links"), message)
            XCTAssertTrue(message.contains(denied.path), message)
            XCTAssertTrue(message.contains("macOS error \(EACCES)"), message)
            XCTAssertTrue(message.contains("Translation can continue"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(helper + "/mac-helper-host").path))
    }

    func testSemanticFileRejectionDoesNotReportAnUnrelatedStaleErrno() throws {
        let (home, app, installer) = try fixture()
        let config = home.appendingPathComponent(helper + "/allowed-extension-ids.json")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertThrowsError(try installer.install(from: app)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("validate file type"), message)
            XCTAssertTrue(message.contains(config.path), message)
            XCTAssertTrue(message.contains("Only a regular file"), message)
            XCTAssertFalse(message.contains("macOS error"), message)
        }
    }

    func testBrowserProfileTraversalRequiresSearchPermissionWithoutReadingProfileDirectory() throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX permission denial cannot be simulated as root") }
        let (home, app, installer) = try fixture()
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        let nativeHosts = profile.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createDirectory(at: nativeHosts, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: profile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path) }
        let readHandle = Darwin.open(profile.path, O_RDONLY | O_DIRECTORY)
        if readHandle >= 0 { Darwin.close(readHandle) }
        XCTAssertEqual(readHandle, -1, "The fixture must forbid reading/enumerating the browser profile directory")
        let installed = try installer.install(from: app)
        XCTAssertEqual(installed.manifestURLs.count, 4)
        XCTAssertEqual(try manifest(nativeHosts.appendingPathComponent(BrowserSupportInstaller.hostName + ".json"))["path"] as? String,
                       installed.binaryURL.path)
    }

    func testManagedRegistrationKeepsExactBrowserIdentitiesAndSeparateHosts() throws {
        let (home, app, legacy) = try fixture()
        let binary = Data("managed bridge fixture".utf8)
        try write(binary, to: app.appendingPathComponent("Contents/MacOS/mac-helper-companion"), mode: 0o700)
        let original = try legacy.install(from: app)
        let oldManifests = try original.manifestURLs.map { try Data(contentsOf: $0) }
        let installer = ManagedCompanionInstaller(homeDirectory: home)
        let firefox = "Library/Application Support/Mozilla/NativeMessagingHosts"
        for (browser, identity, folder) in [
            (SourceCompanionBrowser.chrome, customID, chrome), (.edge, customID, edge), (.firefox, "sample@example.com", firefox),
        ] {
            try installer.register(browser, identifiers: [identity], from: app)
            let url = home.appendingPathComponent(folder + "/" + ManagedCompanionInstaller.hostName + ".json")
            let value = try manifest(url)
            let executable = URL(fileURLWithPath: try XCTUnwrap(value["path"] as? String))
            XCTAssertEqual(executable.lastPathComponent, "mac-helper-companion-" + browser.rawValue)
            XCTAssertEqual(try Data(contentsOf: executable), binary)
            XCTAssertEqual(try permissions(executable), 0o700)
            XCTAssertEqual(try permissions(url), 0o600)
            XCTAssertEqual(value[browser == .firefox ? "allowed_extensions" : "allowed_origins"] as? [String],
                           [browser == .firefox ? identity : "chrome-extension://" + identity + "/"])
            XCTAssertNil(value[browser == .firefox ? "allowed_origins" : "allowed_extensions"])
        }
        XCTAssertThrowsError(try installer.register(.safari, identifiers: ["org.example.safari"], from: app))
        XCTAssertEqual(try original.manifestURLs.map { try Data(contentsOf: $0) }, oldManifests)
        let external = home.appendingPathComponent(chrome + "/" + ManagedCompanionInstaller.hostName + ".json")
        var custom = try manifest(external)
        custom["path"] = "/usr/local/bin/another-helper"
        let contents = try json(custom)
        try write(contents, to: external)
        XCTAssertThrowsError(try installer.register(.chrome, identifiers: [customID], from: app))
        XCTAssertEqual(try Data(contentsOf: external), contents)
    }

    func testManagedBrowserPackagePinsIdentityHashAndPathsBeforeStaging() throws {
        let (home, _, _) = try fixture()
        let installer = ManagedCompanionInstaller(homeDirectory: home)
        let testKey = Data("public key for an isolated fixture".utf8)
        let digits = Array("abcdefghijklmnop")
        let id = String(SourcePackageRules.digest(testKey).prefix(32).map { digits[$0.hexDigitValue!] })
        let manifest = try json(["manifest_version": 3, "key": testKey.base64EncodedString(), "permissions": ["nativeMessaging"]])
        func archive(_ files: [String: Data]) throws -> Data {
            try json(["schemaVersion": 1, "files": files.mapValues { $0.base64EncodedString() }])
        }
        let data = try archive(["manifest.json": manifest, "background.js": Data("/* fixture */".utf8)])
        let path = "https://raw.githubusercontent.com/example/tools/" + String(repeating: "a", count: 40) + "/browser.json"
        func companion(_ data: Data, identifier: String) -> SourceBrowserCompanion {
            .init(browser: .chrome, identifier: identifier, packageURL: path, packageSHA256: SourcePackageRules.digest(data))
        }
        let toolID = "org.example.test"
        let accepted = companion(data, identifier: id)
        XCTAssertThrowsError(try installer.stageDevelopmentPackage(Data("tampered".utf8), for: accepted, toolID: toolID))
        XCTAssertThrowsError(try installer.stageDevelopmentPackage(data, for: companion(data, identifier: customID), toolID: toolID))
        let traversal = try archive(["manifest.json": manifest, "../outside.js": Data()])
        XCTAssertThrowsError(try installer.stageDevelopmentPackage(traversal, for: companion(traversal, identifier: id), toolID: toolID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(
            "Library/Application Support/LocalAIBaseTools/BrowserCompanions").path))
        let folder = try installer.stageDevelopmentPackage(data, for: accepted, toolID: toolID)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(folder.appendingPathComponent("background.js")), 0o600)
    }
}
