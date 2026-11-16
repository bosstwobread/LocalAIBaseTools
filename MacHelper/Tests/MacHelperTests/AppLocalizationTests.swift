import Foundation
import XCTest
@testable import MacHelper

final class AppLocalizationTests: XCTestCase {
    private func localizer(preferred: [String] = ["en"], directory: URL? = nil) -> (AppLocalization, UserDefaults) {
        let name = "localization-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (AppLocalization(defaults: defaults, catalogDirectoryURL: directory, preferredLanguages: { preferred }), defaults)
    }

    func testPreferredLanguagesMatchRegionsScriptsAndFallbacks() {
        XCTAssertEqual(AppLocalization.resolve(["nl-NL", "fr-CA"]), "fr")
        XCTAssertEqual(AppLocalization.resolve(["zh-TW"]), "zh-Hant")
        XCTAssertEqual(AppLocalization.resolve(["zh-HK"]), "zh-Hant")
        XCTAssertEqual(AppLocalization.resolve(["zh_CN"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolve(["zh-Hans-TW"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.resolve(["pt-BR"]), "pt")
        XCTAssertEqual(AppLocalization.resolve(["ar-SA"]), "ar")
        XCTAssertEqual(AppLocalization.resolve(["unsupported"]), "en")
    }

    func testExplicitChoicePersistsAndSystemChoiceRestoresDetection() {
        let (service, defaults) = localizer(preferred: ["ja-JP"])
        XCTAssertEqual(service.language, "system")
        XCTAssertEqual(service.resolvedLanguage, "ja")
        service.language = "zh-TW"
        XCTAssertEqual(service.resolvedLanguage, "zh-Hant")
        XCTAssertEqual(AppLocalization(defaults: defaults, preferredLanguages: { ["en"] }).resolvedLanguage, "zh-Hant")
        service.language = "ar"
        XCTAssertTrue(service.isRightToLeft)
        service.language = "system"
        XCTAssertEqual(service.resolvedLanguage, "ja")
        XCTAssertFalse(service.isRightToLeft)
        service.language = "unavailable"
        XCTAssertEqual(service.language, "system")
    }

    func testCatalogFormatsRemainSafeAndUnknownTextFallsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(["Hello %@": "Bonjour %@", "Bad %@": "Incorrect %ld"])
            .write(to: directory.appendingPathComponent("fr.json"))
        let (service, _) = localizer(preferred: ["fr"], directory: directory)
        XCTAssertEqual(service.text("Hello %@", "Nelson"), "Bonjour Nelson")
        XCTAssertEqual(service.text("Bad %@", "data"), "Bad data")
        XCTAssertEqual(service.localized("Original source"), "Original source")
        XCTAssertEqual(service.localized("100% local"), "100% local")
    }

    func testDevelopmentOverrideDoesNotRewriteStoredChoice() {
        let (_, defaults) = localizer()
        let stored = AppLocalization(defaults: defaults, preferredLanguages: { ["fr"] }, environmentLanguage: nil)
        stored.language = "ja"
        let overridden = AppLocalization(defaults: defaults, preferredLanguages: { ["fr"] }, environmentLanguage: "en")
        XCTAssertEqual(overridden.resolvedLanguage, "en")
        XCTAssertEqual(overridden.language, "ja")
        XCTAssertEqual(stored.resolvedLanguage, "ja")
    }

    func testEveryShippedCatalogHasIdenticalKeysAndSafePlaceholders() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runtime/Localization")
        let english = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent("en.json")))
        XCTAssertGreaterThan(english.count, 60)
        for language in AppLocalization.supportedLanguages {
            let table = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: folder.appendingPathComponent(language.code + ".json")))
            XCTAssertEqual(Set(table.keys), Set(english.keys), language.code)
            for (key, value) in table {
                XCTAssertFalse(value.isEmpty, language.code + ": " + key)
                XCTAssertEqual(AppLocalization.formatSpecifiers(key), AppLocalization.formatSpecifiers(value), language.code + ": " + key)
            }
        }
    }
}
