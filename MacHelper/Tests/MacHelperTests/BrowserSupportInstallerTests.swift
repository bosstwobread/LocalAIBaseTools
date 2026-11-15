import Foundation
import XCTest
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
        XCTAssertEqual(installed.extensionIDs, [customID, BrowserSupportInstaller.defaultExtensionID].sorted())
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
        XCTAssertEqual(updated.extensionIDs, [customID, BrowserSupportInstaller.defaultExtensionID].sorted())
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
        XCTAssertEqual(Set(result.extensionIDs), [customID, legacyID, BrowserSupportInstaller.defaultExtensionID])
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
}
