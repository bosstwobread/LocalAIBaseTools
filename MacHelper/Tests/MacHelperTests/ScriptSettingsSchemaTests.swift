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
