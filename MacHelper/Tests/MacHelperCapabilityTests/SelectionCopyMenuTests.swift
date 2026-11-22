import XCTest
import ApplicationServices
@testable import MacHelperCapabilities

final class SelectionCopyMenuTests: XCTestCase {
    func testFindsEditBeforeDescendingIntoFileOrServicesMenus() {
        let menus = ["Application", "File", "Edit", "View", "Help"]
        var inspected: [String] = []
        let index = SelectionCopyMenuIdentity.editMenuIndex(in: menus) {
            inspected.append($0)
            return $0
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(inspected, ["Application", "File", "Edit"])
    }

    func testEditMenuPriorityUsesExactLocalizedNamesAndIgnoresMissingTitles() {
        for name in ["Edit", " 编辑 ", "編輯", "Édition", "Bearbeiten", "編集", "편집", "Правка"] {
            let titles = [nil, "Editing Tools", "编辑器", name]
            XCTAssertEqual(SelectionCopyMenuIdentity.editMenuIndex(in: titles) { $0 }, 3, name)
        }
        let titles = [nil, "File", "Edit Links", "Edit…", "Help"]
        XCTAssertNil(SelectionCopyMenuIdentity.editMenuIndex(in: titles) { $0 })
    }

    func testUncertainMenuAcknowledgementStillObservesAndRestoresChangedClipboard() {
        for status in [AXError.success, .cannotComplete, .failure] {
            XCTAssertTrue(SelectionCopyMenuIdentity.observeDispatch(status))
        }
        for status in [AXError.actionUnsupported, .invalidUIElement, .apiDisabled, .illegalArgument, .notImplemented] {
            XCTAssertFalse(SelectionCopyMenuIdentity.observeDispatch(status))
        }
    }
    func testOnlyUnmodifiedStandardCommandCopyShortcutMatches() {
        XCTAssertTrue(SelectionCopyMenuIdentity.standardShortcut(character: "c", modifiers: 0))
        XCTAssertTrue(SelectionCopyMenuIdentity.standardShortcut(character: "C", modifiers: 0))
        for modifiers in [1, 2, 4, 8, 15] {
            XCTAssertFalse(SelectionCopyMenuIdentity.standardShortcut(character: "c", modifiers: modifiers))
        }
        XCTAssertFalse(SelectionCopyMenuIdentity.standardShortcut(character: "v", modifiers: 0))
        XCTAssertFalse(SelectionCopyMenuIdentity.standardShortcut(character: nil, modifiers: 0))
        XCTAssertFalse(SelectionCopyMenuIdentity.standardShortcut(character: "c", modifiers: nil))
    }

    func testLocalizedExactCopyTitlesAndWhitespaceAreAccepted() {
        for title in ["Copy", "复制", "拷貝", "Copier", "Kopieren", "コピー", "복사", "نسخ", "कॉपी", "Копировать", "Copia", " Copiar\n"] {
            XCTAssertTrue(SelectionCopyMenuIdentity.exactTitle(title), title)
        }
    }

    func testDirectEditCopyCannotAssumeMissingShortcutOnTimeoutOrMalformedReply() {
        XCTAssertTrue(SelectionCopyMenuIdentity.reportsNoShortcut(status: .success, character: ""))
        XCTAssertTrue(SelectionCopyMenuIdentity.reportsNoShortcut(status: .noValue, character: nil))
        XCTAssertTrue(SelectionCopyMenuIdentity.reportsNoShortcut(status: .attributeUnsupported, character: nil))
        XCTAssertFalse(SelectionCopyMenuIdentity.reportsNoShortcut(status: .cannotComplete, character: nil))
        XCTAssertFalse(SelectionCopyMenuIdentity.reportsNoShortcut(status: .success, character: nil))
        XCTAssertFalse(SelectionCopyMenuIdentity.reportsNoShortcut(status: .success, character: "v"))
    }

    func testOtherClipboardCommandsAndPartialCopyLabelsAreExcluded() {
        for title in ["Cut", "Paste", "Copy Link", "Copy Image", "Copy Style", "Copying", "复制链接", "", "c"] {
            XCTAssertFalse(SelectionCopyMenuIdentity.exactTitle(title), title)
        }
    }

    func testReadOnlyFallbackRequiresStandardCopyTitleAndCompatibleShortcut() {
        func matches(_ title: String, _ status: AXError, _ character: String?, _ modifiers: Int?) -> Bool {
            SelectionCopyMenuIdentity.matchesDirectCopy(title: title, shortcutStatus: status,
                                                        character: character, modifiers: modifiers)
        }
        XCTAssertTrue(matches("Copy", .success, "c", 0))
        XCTAssertTrue(matches("复制", .attributeUnsupported, nil, nil))
        XCTAssertFalse(matches("Copy Link", .success, "c", 0))
        XCTAssertFalse(matches("Copy", .success, "c", 2))
        XCTAssertFalse(matches("Copy", .cannotComplete, nil, nil))
        XCTAssertFalse(matches("Copy", .success, "v", 0))
    }
}
