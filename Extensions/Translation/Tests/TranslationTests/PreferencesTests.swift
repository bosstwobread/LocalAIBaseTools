import XCTest
@testable import Translation

final class PreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "TranslationTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testMigrationPersistsOnlyLanguageToHostProvidedDirectory() throws {
        defaults.set("ja", forKey: "Translation.targetLanguage")
        let store = TranslationPreferencesStore(legacyDefaults: defaults, previousApplicationDefaults: nil)
        try store.configure(directory: directory)
        XCTAssertEqual(store.targetLanguage, "ja")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json"))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "targetLanguage"])
        XCTAssertEqual(json["targetLanguage"] as? String, "ja")
    }

    func testHostedPreferencesSurviveReloadAndOverrideLegacyDefaults() throws {
        let store = TranslationPreferencesStore(legacyDefaults: defaults, previousApplicationDefaults: nil)
        try store.configure(directory: directory)
        try store.setTargetLanguage("fr")
        defaults.set("de", forKey: "Translation.targetLanguage")
        let reloaded = TranslationPreferencesStore(legacyDefaults: defaults, previousApplicationDefaults: nil)
        try reloaded.configure(directory: directory)
        XCTAssertEqual(reloaded.targetLanguage, "fr")
    }

    func testInvalidLegacyLanguageFallsBackToChinese() {
        defaults.set("unrecognized", forKey: "Translation.targetLanguage")
        let store = TranslationPreferencesStore(legacyDefaults: defaults, previousApplicationDefaults: nil)
        XCTAssertEqual(store.targetLanguage, "zh-CN")
    }

    func testMalformedSettingsAreNotOverwrittenOnLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let malformed = Data("not json".utf8)
        try malformed.write(to: url)
        let store = TranslationPreferencesStore(legacyDefaults: defaults, previousApplicationDefaults: nil)
        XCTAssertThrowsError(try store.configure(directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }
}
