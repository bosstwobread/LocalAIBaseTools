import Foundation
import XCTest
@testable import MacHelper

final class HelperSettingsTests: XCTestCase {
    func testDefaultsUseSignedInChatGPTWithoutAnAPIAddress() throws {
        let settings = try HelperSettings().validated()
        XCTAssertEqual(settings.provider, .chatGPT)
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.baseURL, "")
    }

    func testEachLocalProviderHasItsOwnDefaultAddress() throws {
        XCTAssertEqual(try HelperSettings(provider: .ollama).validated().baseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(try HelperSettings(provider: .lmStudio).validated().baseURL, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(try HelperSettings(provider: .ollama, baseURL: " \n ").validated().baseURL,
                       "http://127.0.0.1:11434")
    }

    func testValidationNormalizesUserInputAndRetainsAPIPath() throws {
        let settings = try HelperSettings(provider: .lmStudio, model: " qwen3:8b \n",
                                          baseURL: " http://localhost:1234/v1/// \n").validated()
        XCTAssertEqual(settings.model, "qwen3:8b")
        XCTAssertEqual(settings.baseURL, "http://localhost:1234/v1")
    }

    func testLocalProvidersAcceptIPv6Loopback() throws {
        XCTAssertEqual(try HelperSettings(provider: .ollama, baseURL: "http://[::1]:11434").validated().baseURL,
                       "http://[::1]:11434")
    }

    func testLocalProviderRejectsRemoteOrCredentialBearingAddresses() {
        for address in ["https://example.com/v1", "http://192.168.1.10:11434", "file:///tmp/model",
                        "http://user:secret@localhost:11434", "http://localhost:11434?key=secret",
                        "http://localhost:11434#fragment", "http://localhost:0", "http://localhost:65536",
                        "http://localhost:11434/\nsecret"] {
            XCTAssertThrowsError(try HelperSettings(provider: .ollama, baseURL: address).validated(), address) {
                XCTAssertEqual($0 as? HelperSettingsError, .invalidBaseURL)
            }
        }
    }

    func testChatGPTDoesNotUseAnOldLocalProviderAddress() throws {
        let settings = try HelperSettings(provider: .chatGPT, baseURL: "http://localhost:11434").validated()
        XCTAssertEqual(settings.baseURL, "")
    }

    func testModelValidationRejectsControlCharactersAndOversizedIDs() {
        for model in ["model\u{0}name", "model\tname", String(repeating: "m", count: 201)] {
            XCTAssertThrowsError(try HelperSettings(model: model).validated()) {
                XCTAssertEqual($0 as? HelperSettingsError, .invalidModel)
            }
        }
    }

    func testPartialSettingsUseDefaultsButUnknownProviderIsRejected() throws {
        let partial = try JSONDecoder().decode(HelperSettings.self, from: Data(#"{"provider":"lmstudio"}"#.utf8))
        XCTAssertEqual(partial, HelperSettings(provider: .lmStudio))
        let empty = try JSONDecoder().decode(HelperSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, HelperSettings())
        XCTAssertThrowsError(try JSONDecoder().decode(HelperSettings.self,
                                                      from: Data(#"{"provider":"unknown"}"#.utf8)))
    }

    func testMissingSettingsDoesNotCreateFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HelperSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        XCTAssertEqual(try store.load(), HelperSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSavedSettingsRoundTripWithPrivatePermissionsAndOnlyPreferences() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HelperSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let settings = HelperSettings(provider: .ollama, model: "qwen3:8b")
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["provider", "model", "baseURL"]))
    }

    func testInvalidSaveDoesNotReplaceWorkingSettings() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HelperSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let valid = HelperSettings(provider: .lmStudio, model: "local-model")
        try store.save(valid)
        XCTAssertThrowsError(try store.save(HelperSettings(provider: .ollama, baseURL: "http://remote.example")))
        XCTAssertEqual(try store.load(), valid)
    }

    func testCorruptSettingsAreReportedInsteadOfSilentlyReplacingThem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HelperSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        let broken = Data("{ broken".utf8)
        try broken.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacHelperSettingsTests-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }
}
