import AppKit
import Foundation
import XCTest
@testable import MacHelper

@MainActor
final class ExtensionRegistryTests: XCTestCase {
    func testManifestRejectsUnsupportedVersionsUnsafePathsAndBadMetadata() {
        for identifier in ["../outside", "UPPERCASE.plugin", "single", "com.example/escape", "com.example.\u{0}plugin"] {
            XCTAssertThrowsError(try manifest(id: identifier).validate())
        }
        for path in ["/tmp/plugin", "Contents/MacOS/../../outside", "Contents/MacOS/..", "Contents/MacOS/name\n", "Contents/Resources/plugin"] {
            XCTAssertThrowsError(try manifest(entryPoint: path).validate())
        }
        XCTAssertThrowsError(try ExtensionManifest(schemaVersion: 2, identifier: "com.example.fixture", displayName: "Fixture", version: "1.0.0", summary: "Example", entryPoint: "Contents/MacOS/Fixture").validate())
        XCTAssertThrowsError(try ExtensionManifest(identifier: "com.example.fixture", displayName: "bad\nname", version: "1.0.0", summary: "Example", entryPoint: "Contents/MacOS/Fixture").validate())
        XCTAssertNoThrow(try manifest().validate())
    }

    func testDiscoveryDoesNotLoadCodeAndOnlyBundledTranslationDefaultsOn() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.bundle(id: "com.localaibasetools.translation", in: fixture.bundled)
        _ = try fixture.bundle(id: "com.example.external", in: fixture.external)
        _ = try fixture.bundle(id: "com.example.another-bundled", in: fixture.bundled)
        let registry = fixture.registry()
        registry.refresh()
        XCTAssertEqual(registry.extensions.count, 3)
        XCTAssertTrue(registry.issues.isEmpty)
        XCTAssertTrue(registry.isEnabled("com.localaibasetools.translation"))
        XCTAssertFalse(registry.isEnabled("com.example.external"))
        XCTAssertFalse(registry.isEnabled("com.example.another-bundled"))
        XCTAssertFalse(registry.isRunning("com.localaibasetools.translation"))
        XCTAssertTrue(registry.runtimeErrors.isEmpty)
    }

    func testManifestSymlinkCannotReadOutsideBundle() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bundle = try fixture.bundle()
        let file = bundle.appendingPathComponent("Contents/Resources/extension.json")
        let outside = fixture.root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: file, to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let registry = fixture.registry(); registry.refresh()
        XCTAssertTrue(registry.extensions.isEmpty)
        XCTAssertEqual(registry.issues.count, 1)
        XCTAssertTrue(registry.issues[0].message.contains("escapes"))
    }

    func testExecutableSymlinkCannotEscapeBundle() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bundle = try fixture.bundle()
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        let outside = fixture.root.appendingPathComponent("outside-executable")
        try FileManager.default.moveItem(at: executable, to: outside)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
        let registry = fixture.registry(); registry.refresh()
        XCTAssertTrue(registry.extensions.isEmpty)
        XCTAssertEqual(registry.issues.count, 1)
    }

    func testBundleAndManifestIdentityMustMatch() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bundle = try fixture.bundle()
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        var values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        values["CFBundleIdentifier"] = "com.example.different"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
        let registry = fixture.registry(); registry.refresh()
        XCTAssertTrue(registry.extensions.isEmpty)
        XCTAssertEqual(registry.issues.count, 1)
    }

    func testBundledIdentityCannotBeShadowedByExternalBundle() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bundled = try fixture.bundle(id: "com.localaibasetools.translation", in: fixture.bundled)
        _ = try fixture.bundle(id: "com.localaibasetools.translation", in: fixture.external)
        let registry = fixture.registry(); registry.refresh()
        XCTAssertEqual(registry.extensions.count, 1)
        XCTAssertEqual(registry.extensions[0].bundleURL, bundled)
        XCTAssertTrue(registry.extensions[0].isBundled)
        XCTAssertEqual(registry.issues.count, 1)
    }

    func testImportOutsideRepositoryCopiesBundleWithoutExecutingOrEnabling() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let source = try fixture.bundle(in: fixture.root.appendingPathComponent("independently-authored"))
        let registry = fixture.registry(); registry.refresh()
        let installed = try registry.importExtension(from: source)
        XCTAssertEqual(installed.bundleURL.deletingLastPathComponent(), fixture.external)
        XCTAssertFalse(registry.isEnabled(installed.id))
        XCTAssertFalse(registry.isRunning(installed.id))
        XCTAssertTrue(registry.runtimeErrors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertThrowsError(try registry.settingsViewController(for: installed.id))
    }

    func testCorruptEnablementFailsClosedWithoutLoadingAnyExtension() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.bundle(id: "com.localaibasetools.translation", in: fixture.bundled)
        try Data("{bad".utf8).write(to: fixture.state)
        let registry = fixture.registry(); registry.refresh(); registry.startEnabled()
        XCTAssertFalse(registry.isEnabled("com.localaibasetools.translation"))
        XCTAssertFalse(registry.isRunning("com.localaibasetools.translation"))
        XCTAssertEqual(registry.issues.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.state), Data("{bad".utf8))
    }

    func testChangedExecutableBetweenDiscoveryAndEnablementIsRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bundle = try fixture.bundle()
        let registry = fixture.registry(); registry.refresh()
        try Data("replaced executable".utf8).write(to: bundle.appendingPathComponent("Contents/MacOS/Fixture"))
        XCTAssertThrowsError(try registry.setEnabled(true, for: "com.example.fixture")) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed since discovery"))
        }
        XCTAssertFalse(registry.isRunning("com.example.fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
    }

    func testExternalObjCBundleLoadsLifecycleSettingsAndTypedHostCallbacks() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.bundle(compile: true)
        var opened = 0
        var hidden = 0
        let registry = fixture.registry(openAISettings: { opened += 1 }, hideSettings: { hidden += 1 })
        registry.refresh(); registry.startEnabled()
        XCTAssertFalse(registry.isRunning("com.example.fixture"))
        try registry.setEnabled(true, for: "com.example.fixture")
        XCTAssertTrue(registry.isEnabled("com.example.fixture"))
        XCTAssertTrue(registry.isRunning("com.example.fixture"))
        XCTAssertEqual(opened, 1); XCTAssertEqual(hidden, 1)
        let view = try registry.settingsViewController(for: "com.example.fixture")
        XCTAssertEqual(view.title, "External fixture settings")
        let settings = fixture.root.appendingPathComponent("ExtensionSettings/com.example.fixture/lifecycle.txt")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "start")
        try registry.setEnabled(false, for: "com.example.fixture")
        XCTAssertFalse(registry.isRunning("com.example.fixture"))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "stop")
        try registry.setEnabled(true, for: "com.example.fixture")
        XCTAssertEqual(opened, 2)
        registry.stopAll()
        XCTAssertFalse(registry.isRunning("com.example.fixture"))
        let reloaded = fixture.registry(); reloaded.refresh()
        XCTAssertTrue(reloaded.isEnabled("com.example.fixture"))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.state.path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testIncompleteObjCPluginReportsErrorInsteadOfSendingMissingSelector() throws {
        for omitted in ["factory", "lifecycle"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            _ = try fixture.bundle(compile: true, omittedMethod: omitted)
            let registry = fixture.registry(); registry.refresh()
            XCTAssertThrowsError(try registry.setEnabled(true, for: "com.example.fixture"))
            XCTAssertFalse(registry.isRunning("com.example.fixture"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        }
    }

    func testReplacingPreviouslyApprovedExternalCodeRequiresNewEnablement() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bundle = try fixture.bundle(compile: true)
        let registry = fixture.registry(); registry.refresh()
        try registry.setEnabled(true, for: "com.example.fixture")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        var modified = try Data(contentsOf: executable); modified.append(0)
        try modified.write(to: executable)
        let nextLaunch = fixture.registry(); nextLaunch.refresh()
        XCTAssertFalse(nextLaunch.isEnabled("com.example.fixture"))
        registry.refresh()
        XCTAssertFalse(registry.isRunning("com.example.fixture"))
        XCTAssertNotNil(registry.runtimeErrors["com.example.fixture"])
        XCTAssertThrowsError(try registry.setEnabled(true, for: "com.example.fixture")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Restart"))
        }
    }

    private func manifest(id: String = "com.example.fixture", entryPoint: String = "Contents/MacOS/Fixture") -> ExtensionManifest {
        ExtensionManifest(identifier: id, displayName: "Fixture", version: "1.0.0", summary: "Independently authored test extension", entryPoint: entryPoint)
    }

    private struct Fixture {
        let root: URL
        let bundled: URL
        let external: URL
        let state: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MacHelperExtensionTests-" + UUID().uuidString)
            bundled = root.appendingPathComponent("Bundled", isDirectory: true)
            external = root.appendingPathComponent("External", isDirectory: true)
            state = root.appendingPathComponent("extensions.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func registry(openAISettings: @escaping () -> Void = {}, hideSettings: @escaping () -> Void = {}) -> ExtensionRegistry {
            ExtensionRegistry(bundledDirectory: bundled, userDirectory: external, stateFileURL: state,
                              helperExecutableURL: root.appendingPathComponent("mac-helper-host"),
                              openAISettings: openAISettings, hideSettings: hideSettings)
        }

        func bundle(id: String = "com.example.fixture", in parent: URL? = nil, compile: Bool = false, omittedMethod: String? = nil) throws -> URL {
            let bundle = (parent ?? external).appendingPathComponent(id + ".machextension", isDirectory: true)
            let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
            let binaries = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
            let className = "ExtensionFixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "BNDL", "NSPrincipalClass": className]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let manifest = ExtensionManifest(identifier: id, displayName: "Fixture", version: "1.0.0", summary: "Independent test extension", entryPoint: "Contents/MacOS/Fixture")
            try JSONEncoder().encode(manifest).write(to: resources.appendingPathComponent("extension.json"))
            let executable = binaries.appendingPathComponent("Fixture")
            guard compile else { try Data("not loaded during discovery".utf8).write(to: executable); return bundle }
            let source = root.appendingPathComponent(className + ".m")
            var code = """
            #import "MacHelperExtensionSDK.h"
            @interface \(className) : NSObject <MacHelperExtension>
            @property(nonatomic,strong) id<MacHelperExtensionContext> context;
            @end
            @implementation \(className)
            + (id<MacHelperExtension>)makeExtension { return [self new]; }
            - (void)startWithContext:(id<MacHelperExtensionContext>)context {
                self.context = context;
                [@"start" writeToFile:[context.settingsDirectory stringByAppendingPathComponent:@"lifecycle.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [context openAISettings]; [context hideSettings];
            }
            - (void)stop { [@"stop" writeToFile:[self.context.settingsDirectory stringByAppendingPathComponent:@"lifecycle.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
            - (NSViewController *)makeSettingsViewController { NSViewController *view = [NSViewController new]; view.title = @"External fixture settings"; return view; }
            @end
            """
            if omittedMethod == "factory" {
                code = code.replacingOccurrences(of: "+ (id<MacHelperExtension>)makeExtension { return [self new]; }", with: "")
            } else if omittedMethod == "lifecycle" {
                code = code.replacingOccurrences(of: "- (void)stop {", with: "- (void)notTheRequiredStopMethod {")
            }
            try code.write(to: source, atomically: true, encoding: .utf8)
            let include = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("ExtensionSDK/Sources/MacHelperExtensionSDK/include")
            let process = Process(); let diagnostics = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["clang", "-bundle", "-fobjc-arc", "-framework", "Foundation", "-framework", "AppKit", "-I", include.path, source.path, "-o", executable.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = diagnostics
            try process.run()
            let output = diagnostics.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ExtensionRegistryError.invalid(String(decoding: output, as: UTF8.self)) }
            return bundle
        }
    }
}
