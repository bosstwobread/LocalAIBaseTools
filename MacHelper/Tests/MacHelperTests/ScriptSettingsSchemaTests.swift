import Foundation
import XCTest
@testable import MacHelper

final class ScriptSettingsSchemaTests: XCTestCase {
    func testDefaultsAndNormalizationPreserveOnlyDeclaredValidSettings() throws {
        let schema = try makeSchema(fields: standardFields)
        XCTAssertEqual(schema.fields.map(\.key), ["targetLanguage", "guidance", "showIcon"])
        XCTAssertEqual(schema.fields[0].options.map(\.value), ["zh-CN", "en"])
        XCTAssertEqual(schema.defaults["targetLanguage"] as? String, "zh-CN")
        XCTAssertEqual(schema.defaults["guidance"] as? String, "Preserve names and prices.")
        XCTAssertEqual(schema.defaults["showIcon"] as? Bool, true)

        let normalized = schema.normalized([
            "targetLanguage": "en", "guidance": "Use plain language.\nKeep paragraphs.",
            "showIcon": false, "undeclared": "Never forward this value"
        ])
        XCTAssertEqual(normalized.count, 3)
        XCTAssertNil(normalized["undeclared"])
        XCTAssertEqual(normalized["targetLanguage"] as? String, "en")
        XCTAssertEqual(normalized["guidance"] as? String, "Use plain language.\nKeep paragraphs.")
        XCTAssertEqual(normalized["showIcon"] as? Bool, false)

        let fallback = schema.normalized(["targetLanguage": "unknown", "guidance": NSNull(), "showIcon": 1])
        XCTAssertEqual(fallback["targetLanguage"] as? String, "zh-CN")
        XCTAssertEqual(fallback["guidance"] as? String, "Preserve names and prices.")
        XCTAssertEqual(fallback["showIcon"] as? Bool, true)
        XCTAssertEqual(schema.normalized([:]).count, 3)
    }

    func testInteractiveValidationRejectsUnknownKeysAndWrongValueTypes() throws {
        let schema = try makeSchema(fields: standardFields)
        XCTAssertNoThrow(try schema.validate("en", for: "targetLanguage"))
        XCTAssertNoThrow(try schema.validate("", for: "guidance"))
        XCTAssertNoThrow(try schema.validate(false, for: "showIcon"))
        for invalid in ["unknown", "English", "", "zh-CN\0"] {
            XCTAssertThrowsError(try schema.validate(invalid, for: "targetLanguage"))
        }
        for invalid: Any in [0, 1, "true", NSNull()] {
            XCTAssertThrowsError(try schema.validate(invalid, for: "showIcon"))
        }
        XCTAssertThrowsError(try schema.validate(true, for: "guidance"))
        XCTAssertThrowsError(try schema.validate("anything", for: "undeclared"))
    }

    func testBooleanDefaultMustBeJSONBooleanRatherThanNumericOne() throws {
        XCTAssertNoThrow(try makeSchema(fields: [["key": "enabled", "label": "Enabled", "type": "boolean", "default": false]]))
        for invalid: Any in [0, 1, "false", NSNull()] {
            XCTAssertThrowsError(try makeSchema(fields: [["key": "enabled", "label": "Enabled", "type": "boolean", "default": invalid]]))
        }
    }

    func testTextLengthAndNullBoundsApplyToDefaultsAndUpdates() throws {
        let maximum = String(repeating: "文", count: 12_000)
        let schema = try makeSchema(fields: [["key": "guidance", "label": "Guidance", "type": "text", "default": maximum]])
        XCTAssertNoThrow(try schema.validate(maximum, for: "guidance"))
        for invalid in [maximum + "字", "Text\0with null"] {
            XCTAssertThrowsError(try schema.validate(invalid, for: "guidance"))
            XCTAssertThrowsError(try makeSchema(fields: [["key": "guidance", "label": "Guidance", "type": "text", "default": invalid]]))
            XCTAssertEqual(schema.normalized(["guidance": invalid])["guidance"] as? String, maximum)
        }
    }

    func testSchemaVersionAndTopLevelShapeAreValidated() throws {
        for object: Any in [
            ["schemaVersion": 2, "fields": []],
            ["schemaVersion": true, "fields": []],
            ["schemaVersion": "1", "fields": []],
            ["fields": []],
            ["schemaVersion": 1],
            ["schemaVersion": 1, "fields": ["wrong shape"]],
            []
        ] {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ScriptSettingsSchema(data: data), "Accepted invalid schema: \(object)")
        }
        XCTAssertThrowsError(try ScriptSettingsSchema(data: Data("{broken".utf8)))
        XCTAssertNoThrow(try makeSchema(fields: []))
    }

    func testSchemaSizeAndFieldCountAreBounded() throws {
        let fields: [[String: Any]] = (0..<32).map { ["key": "field\($0)", "label": "Field \($0)", "type": "text", "default": ""] }
        XCTAssertNoThrow(try makeSchema(fields: fields))
        XCTAssertThrowsError(try makeSchema(fields: fields + [["key": "extra", "label": "Extra", "type": "text", "default": ""]]))
        var maximum = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fields": []] as [String: Any])
        maximum.append(Data(repeating: 0x20, count: 64 * 1024 - maximum.count))
        XCTAssertNoThrow(try ScriptSettingsSchema(data: maximum))
        maximum.append(0x20)
        XCTAssertThrowsError(try ScriptSettingsSchema(data: maximum))
    }

    func testFieldIdentifiersLabelsTypesAndDefaultsAreValidated() throws {
        let valid: [String: Any] = ["key": "field", "label": "Label", "type": "text", "default": ""]
        for key in ["", "with space", "../outside", "0start", "dash-key", String(repeating: "a", count: 65)] {
            var field = valid; field["key"] = key
            XCTAssertThrowsError(try makeSchema(fields: [field]))
        }
        var maximumKey = valid; maximumKey["key"] = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try makeSchema(fields: [maximumKey]))
        XCTAssertThrowsError(try makeSchema(fields: [valid, valid]))
        for replacement: Any in ["", String(repeating: "a", count: 121), 10, NSNull()] {
            var field = valid; field["label"] = replacement
            XCTAssertThrowsError(try makeSchema(fields: [field]))
        }
        for type in ["number", "file", "", "TEXT"] {
            var field = valid; field["type"] = type
            XCTAssertThrowsError(try makeSchema(fields: [field]))
        }
        var missingDefault = valid; missingDefault.removeValue(forKey: "default")
        XCTAssertThrowsError(try makeSchema(fields: [missingDefault]))
    }

    func testSelectChoicesAreBoundedUniqueAndContainTheDefault() throws {
        func select(_ options: Any, default value: Any = "v0") -> [String: Any] {
            ["key": "choice", "label": "Choice", "type": "select", "default": value, "options": options]
        }
        let maximum = (0..<100).map { ["value": "v\($0)", "label": "Choice \($0)"] }
        XCTAssertNoThrow(try makeSchema(fields: [select(maximum)]))
        let invalidOptions: [Any] = [
            [], maximum + [["value": "extra", "label": "Extra"]],
            [["value": "v0", "label": "First"], ["value": "v0", "label": "Duplicate value"]],
            [["value": "", "label": "Empty ID"]], [["value": "v0", "label": ""]],
            [["value": String(repeating: "a", count: 201), "label": "Too long"]],
            [["value": "v0", "label": String(repeating: "a", count: 201)]],
            [["label": "Missing value"]], [["value": "v0", "label": 1]]
        ]
        for options in invalidOptions { XCTAssertThrowsError(try makeSchema(fields: [select(options)])) }
        XCTAssertThrowsError(try makeSchema(fields: [select(maximum, default: "unknown")]))
        XCTAssertThrowsError(try makeSchema(fields: [select(maximum, default: false)]))
    }

    func testPromptFieldsUseSourcePathsAndNeverBecomeOrdinarySettings() throws {
        let schema = try makeSchema(fields: standardFields + [promptField])
        XCTAssertEqual(try schema.promptPath(for: "instruction"), "prompts/instruction.txt")
        XCTAssertEqual(schema.fields.last?.path, "prompts/instruction.txt")
        XCTAssertNil(schema.defaults["instruction"])
        let values = schema.normalized(["instruction": "Must not persist", "targetLanguage": "en"])
        XCTAssertEqual(values.count, 3)
        XCTAssertNil(values["instruction"])
        XCTAssertThrowsError(try schema.validate("Must not persist", for: "instruction"))
        XCTAssertThrowsError(try schema.promptPath(for: "targetLanguage"))
    }

    func testPromptPathsRejectTraversalWrongTypesDuplicatesAndDuplicateDefaults() throws {
        for path: Any in ["../outside.txt", "/tmp/outside.txt", "prompts/../outside.txt", "prompts\\outside.txt",
                          "prompts/instruction.js", "prompts//instruction.txt", "", 10, NSNull()] {
            var field = promptField; field["path"] = path
            XCTAssertThrowsError(try makeSchema(fields: [field]))
        }
        var duplicateDefault = promptField; duplicateDefault["default"] = "Do not duplicate source"
        XCTAssertThrowsError(try makeSchema(fields: [duplicateDefault]))
        var missing = promptField; missing.removeValue(forKey: "path")
        XCTAssertThrowsError(try makeSchema(fields: [missing]))
        var other = promptField; other["key"] = "another"; other["path"] = "prompts/INSTRUCTION.txt"
        XCTAssertThrowsError(try makeSchema(fields: [promptField, other]))
        var ordinary = standardFields[1]; ordinary["path"] = "prompts/instruction.txt"
        XCTAssertThrowsError(try makeSchema(fields: [ordinary]))
    }

    func testPromptValidationPreservesWhitespaceAndBoundsCharactersBytesAndNulls() throws {
        for accepted in ["  A prompt.\r\n\tKeep whitespace.\n\n", String(repeating: "文", count: 12_000), String(repeating: "😀", count: 12_000)] {
            XCTAssertNoThrow(try ScriptPromptResource.validate(accepted))
        }
        for invalid in ["", " \t\r\n", "before\0after", String(repeating: "x", count: 12_001),
                        String(repeating: "e\u{301}", count: 12_000) + String(repeating: "\u{301}", count: 12_001)] {
            XCTAssertThrowsError(try ScriptPromptResource.validate(invalid))
        }
    }

    func testAllDeclaredPromptResourcesMustExistAndBeBoundedUTF8() throws {
        let root = try promptFixture()
        let schema = try makeSchema(fields: [promptField])
        let snapshot = try SourcePackageInspector.snapshot(at: root)
        XCTAssertNoThrow(try schema.validatePromptResources(in: snapshot))
        try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("prompts/instruction.txt"))
        XCTAssertThrowsError(try schema.validatePromptResources(in: SourcePackageInspector.snapshot(at: root)))
        try FileManager.default.removeItem(at: root.appendingPathComponent("prompts/instruction.txt"))
        XCTAssertThrowsError(try schema.validatePromptResources(in: SourcePackageInspector.snapshot(at: root)))
    }

    func testPromptReplacementPreservesExactBytesAndUnrelatedSource() throws {
        let root = try promptFixture()
        let before = try SourcePackageInspector.snapshot(at: root)
        let exact = "  User instructions.\r\n\tKeep this indentation.\n\n"
        let result = try ScriptPromptResource.replace(in: before, key: "instruction", value: exact, expectedValue: "Original prompt.\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("prompts/instruction.txt")), Data(exact.utf8))
        XCTAssertEqual(result.resources["prompts/instruction.txt"].map { Data($0.utf8) }, Data(exact.utf8))
        XCTAssertEqual(result.fileHashes.filter { $0.key != "prompts/instruction.txt" }, before.fileHashes.filter { $0.key != "prompts/instruction.txt" })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".prompt-") })
    }

    func testPromptReplacementRejectsStaleEditorAndCanonicallyEqualDifferentBytes() throws {
        let root = try promptFixture()
        let promptURL = root.appendingPathComponent("prompts/instruction.txt")
        let original = try SourcePackageInspector.snapshot(at: root)
        try Data("External edit.\n".utf8).write(to: promptURL, options: .atomic)
        XCTAssertThrowsError(try ScriptPromptResource.replace(in: original, key: "instruction", value: "User draft", expectedValue: "Original prompt.\n"))
        XCTAssertEqual(try Data(contentsOf: promptURL), Data("External edit.\n".utf8))
        try Data("caf\u{e9}\n".utf8).write(to: promptURL, options: .atomic)
        let unicode = try SourcePackageInspector.snapshot(at: root)
        XCTAssertEqual("caf\u{e9}\n", "cafe\u{301}\n") // Swift String equality normalizes.
        XCTAssertThrowsError(try ScriptPromptResource.replace(in: unicode, key: "instruction", value: "User draft", expectedValue: "cafe\u{301}\n"))
        XCTAssertEqual(try Data(contentsOf: promptURL), Data("caf\u{e9}\n".utf8))
    }

    func testPromptReplacementRejectsSymlinkAndInvalidCandidateWithoutWriting() throws {
        let root = try promptFixture()
        let before = try SourcePackageInspector.snapshot(at: root)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("Outside must survive".utf8).write(to: outside)
        let target = root.appendingPathComponent("prompts/instruction.txt")
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertThrowsError(try ScriptPromptResource.replace(in: before, key: "instruction", value: "New prompt", expectedValue: "Original prompt.\n"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("Outside must survive".utf8))
        try FileManager.default.removeItem(at: target)
        try Data("Original prompt.\n".utf8).write(to: target)
        let restored = try SourcePackageInspector.snapshot(at: root)
        for invalid in ["", "  \n", "NUL\0", String(repeating: "x", count: 12_001)] {
            XCTAssertThrowsError(try ScriptPromptResource.replace(in: restored, key: "instruction", value: invalid, expectedValue: "Original prompt.\n"))
            XCTAssertEqual(try Data(contentsOf: target), Data("Original prompt.\n".utf8))
        }
    }

    func testPromptReplacementValidatesWholeCandidateResourceBudgetBeforeWriting() throws {
        let root = try promptFixture()
        try Data(repeating: 0x61, count: 80 * 1024).write(to: root.appendingPathComponent("additional.txt"))
        let snapshot = try SourcePackageInspector.snapshot(at: root)
        let replacement = String(repeating: "文", count: 12_000)
        XCTAssertNoThrow(try ScriptPromptResource.validate(replacement))
        XCTAssertThrowsError(try ScriptPromptResource.replace(in: snapshot, key: "instruction", value: replacement, expectedValue: "Original prompt.\n"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("prompts/instruction.txt")), Data("Original prompt.\n".utf8))
        XCTAssertEqual(try SourcePackageInspector.snapshot(at: root).fileHashes, snapshot.fileHashes)
    }

    private var promptField: [String: Any] {
        ["key": "instruction", "label": "Instructions", "type": "prompt", "path": "prompts/instruction.txt"]
    }

    private func promptFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-schema-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manifest = SourceExtensionManifest(identifier: "com.example.prompt-fixture", displayName: "Prompt Fixture", version: "1.0.0",
            summary: "Public schema fixture", permissions: [], commands: [.init(identifier: "test", title: "Test", trigger: "manual")], settingsSchema: "settings.schema.json")
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("extension.json"))
        try Data("MacHelper.define({commands:{test(){return {text:'fixture'};}}});".utf8).write(to: root.appendingPathComponent("main.js"))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fields": [promptField]]).write(to: root.appendingPathComponent("settings.schema.json"))
        try Data("Original prompt.\n".utf8).write(to: root.appendingPathComponent("prompts/instruction.txt"))
        return root
    }

    private var standardFields: [[String: Any]] {
        [
            ["key": "targetLanguage", "label": "Translate into", "type": "select", "default": "zh-CN",
             "options": [["value": "zh-CN", "label": "Simplified Chinese"], ["value": "en", "label": "English"]]],
            ["key": "guidance", "label": "Style", "type": "text", "default": "Preserve names and prices."],
            ["key": "showIcon", "label": "Show selection icon", "type": "boolean", "default": true]
        ]
    }

    private func makeSchema(fields: [[String: Any]]) throws -> ScriptSettingsSchema {
        try ScriptSettingsSchema(data: JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fields": fields] as [String: Any]))
    }
}
