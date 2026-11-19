import XCTest
import ApplicationServices
@testable import MacHelperCapabilities

final class SelectionMenuPasteTests: XCTestCase {
    func testOnlyStandardCutAndPasteCommandsWithExactMenuLabelsAreEligible() {
        for title in ["Cut", "剪切", "Ausschneiden", " couper "] {
            XCTAssertEqual(SelectionEditMenuCommand(title: title), .cut)
        }
        for title in ["粘贴", "貼上", " PASTE ", "Pegar", "Вставить"] {
            XCTAssertEqual(SelectionEditMenuCommand(title: title), .paste)
        }
        for title in [nil, "", "Paste as Text", "Paste and Match Style", "Copy", "Paste Link", "剪切图片"] {
            XCTAssertNil(SelectionEditMenuCommand(title: title))
        }
        let paste = SelectionEditMenuCommand.paste
        XCTAssertTrue(paste.acceptsShortcut(status: .success, character: "V", modifiers: 0))
        XCTAssertTrue(paste.acceptsShortcut(status: .attributeUnsupported, character: nil, modifiers: nil))
        XCTAssertTrue(paste.acceptsShortcut(status: .success, character: "", modifiers: nil))
        XCTAssertFalse(paste.acceptsShortcut(status: .cannotComplete, character: nil, modifiers: nil))
        XCTAssertFalse(paste.acceptsShortcut(status: .success, character: "V", modifiers: 1))
        XCTAssertFalse(paste.acceptsShortcut(status: .success, character: "X", modifiers: 0))
        XCTAssertFalse(SelectionEditMenuCommand.cut.acceptsShortcut(status: .success, character: "V", modifiers: 0))
    }

    func testCaretReadOnlyAndMissingMenuSignalsCannotPaste() {
        typealias Menu = SelectionMenuPasteTransaction
        for staged in [false, true] {
            for disabled in [nil, false] {
                XCTAssertFalse(Menu.commandsAvailable(cutEnabled: disabled, pasteEnabled: true, afterStagingText: staged))
            }
            XCTAssertFalse(Menu.commandsAvailable(cutEnabled: true, pasteEnabled: nil, afterStagingText: staged))
            XCTAssertTrue(Menu.commandsAvailable(cutEnabled: true, pasteEnabled: true, afterStagingText: staged))
        }
        XCTAssertTrue(Menu.commandsAvailable(cutEnabled: true, pasteEnabled: false, afterStagingText: false))
        XCTAssertFalse(Menu.commandsAvailable(cutEnabled: true, pasteEnabled: false, afterStagingText: true))
    }

    func testWordAndParagraphKeepOriginalEdgeSeparators() {
        let result = "I have finished the update."
        for (prefix, suffix) in [("", ""), ("", " "), ("", "\r\n"), ("\t", "\r"), ("　", "\u{2029}")] {
            XCTAssertEqual(SelectionMenuPasteTransaction.preservingSelectionEdges("\n" + result + "  ",
                original: prefix + "I has finished the update." + suffix), prefix + result + suffix)
        }
        XCTAssertNil(SelectionMenuPasteTransaction.preservingSelectionEdges(" ", original: "draft"))
        XCTAssertNil(SelectionMenuPasteTransaction.preservingSelectionEdges("result", original: "\n"))
    }

    @MainActor
    private final class Board: SelectionPasteboardAccess {
        var result: String?
        var owner = ""
        var ownerChecks = 0
        var maxOwnedChecks: Int?
        func writeOwnedResult(_ text: String, ownerStamp: String) -> Int? {
            result = text; owner = ownerStamp
            return 1
        }
        func owns(changeCount: Int, ownerStamp: String) -> Bool {
            ownerChecks += 1
            return changeCount == 1 && owner == ownerStamp && ownerChecks <= (maxOwnedChecks ?? Int.max)
        }
    }

    @MainActor
    func testExplicitMenuPasteStagesTextRevalidatesThenDispatchesOnce() async throws {
        let board = Board(), transaction = SelectionMenuPasteTransaction(pasteboard: board)
        var phases: [Bool] = []
        var requests = 0
        let outcome = try transaction.perform("new", original: "old\r", validate: { staged in
            phases.append(staged)
            XCTAssertEqual(board.result, staged ? "new\r" : nil)
            return true
        }, requestPaste: {
            requests += 1
            XCTAssertEqual(board.ownerChecks, 2)
            return true
        })
        XCTAssertEqual(phases, [false, true])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(outcome, .pasteRequested)
    }

    @MainActor
    func testStaleContextOrDisabledMenuAfterStagingAbortsWithoutDispatchOrRestore() async {
        for staleAfterStaging in [false, true] {
            let board = Board()
            XCTAssertThrowsError(try SelectionMenuPasteTransaction(pasteboard: board).perform("new", original: "old",
                validate: { $0 != staleAfterStaging }, requestPaste: { XCTFail("Unexpected menu press"); return true })) {
                XCTAssertEqual($0 as? SelectionPasteFailure, .changedTarget)
            }
            XCTAssertEqual(board.result, staleAfterStaging ? "new" : nil)
        }
    }

    @MainActor
    func testLostClipboardOwnershipAtEitherCheckNeverPressesPaste() async {
        for allowedChecks in [0, 1] {
            let board = Board()
            board.maxOwnedChecks = allowedChecks
            XCTAssertThrowsError(try SelectionMenuPasteTransaction(pasteboard: board).perform("new", original: "old",
                validate: { _ in true }, requestPaste: { XCTFail("Unexpected menu press"); return true })) {
                XCTAssertEqual($0 as? SelectionPasteFailure, .clipboardChanged)
            }
        }
    }

    @MainActor
    func testInvalidResultDoesNotTouchClipboardOrDispatchAndDispatchFailureIsNeverRetried() async {
        let board = Board(), transaction = SelectionMenuPasteTransaction(pasteboard: board)
        for value in ["", "\0", String(repeating: "x", count: 96_001)] {
            XCTAssertThrowsError(try transaction.perform(value, original: "old",
                validate: { _ in XCTFail("Invalid result validated"); return true },
                requestPaste: { XCTFail("Unexpected menu press"); return true })) {
                XCTAssertEqual($0 as? SelectionPasteFailure, .invalidResult)
            }
            XCTAssertNil(board.result)
        }
        var count = 0
        XCTAssertThrowsError(try transaction.perform("new", original: "old",
            validate: { _ in true }, requestPaste: { count += 1; return false })) {
            XCTAssertEqual($0 as? SelectionPasteFailure, .eventUnavailable)
        }
        XCTAssertEqual(count, 1)
    }
}
