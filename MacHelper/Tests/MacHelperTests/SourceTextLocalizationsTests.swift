import Foundation
import XCTest
@testable import MacHelper

final class SourceTextLocalizationsTests: XCTestCase {
    func testExtensionLabelsUseRegionalFallbackAndKeepUnknownTextUnchanged() throws {
        let table = SourceTextLocalizations(translations: ["en": ["Target": "Target language"],
            "zh-Hant": ["Target": "目標語言"], "fr": ["Target": "Langue cible"]])
        try table.validate()
        XCTAssertEqual(table.text("Target", language: "zh-TW"), "目標語言")
        XCTAssertEqual(table.text("Target", language: "fr-CA"), "Langue cible")
        XCTAssertEqual(table.text("Target", language: "ja"), "Target language")
        XCTAssertEqual(table.text("User's unchanged prompt", language: "fr"), "User's unchanged prompt")
    }

    func testInvalidCatalogsAreRejected() {
        XCTAssertThrowsError(try SourceTextLocalizations(schemaVersion: 2, translations: [:]).validate())
        XCTAssertThrowsError(try SourceTextLocalizations(translations: ["../en": ["a": "b"]]).validate())
        XCTAssertThrowsError(try SourceTextLocalizations(translations: ["en": ["a": "\0"]]).validate())
    }

    func testInspectorLoadsDeclaredCatalogAndRejectsMissingOrInvalidResource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = SourceExtensionManifest(identifier: "com.example.localized", displayName: "Example", version: "1.0.0",
            summary: "Example tool", permissions: [], commands: [.init(identifier: "run", title: "Run", trigger: "manual")],
            localizations: "ui.json")
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("extension.json"))
        try Data("MacHelper.define({commands:{run(){return {text:'ok'};}}});".utf8).write(to: folder.appendingPathComponent("main.js"))
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: folder))
        try JSONEncoder().encode(SourceTextLocalizations(translations: ["es": ["Example tool": "Herramienta de ejemplo"]]))
            .write(to: folder.appendingPathComponent("ui.json"))
        let snapshot = try SourcePackageInspector.snapshot(at: folder)
        XCTAssertEqual(snapshot.localizations?.text("Example tool", language: "es"), "Herramienta de ejemplo")
        XCTAssertNotNil(snapshot.resources["ui.json"])
        try Data("{broken".utf8).write(to: folder.appendingPathComponent("ui.json"))
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: folder))
    }
}
