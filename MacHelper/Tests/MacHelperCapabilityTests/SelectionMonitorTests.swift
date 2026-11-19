import AppKit
import XCTest
@testable import MacHelperCapabilities

final class SelectionMonitorTests: XCTestCase {
    @MainActor
    func testOrdinaryAndRightClicksNeverRearmSelection() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try mouse(.leftMouseUp), local: false)
        monitor.handle(try mouse(.rightMouseUp, clicks: 2), local: false)
        monitor.handle(try mouse(.rightMouseUp, flags: .shift), local: false)
        XCTAssertEqual(gestures, [false, false, false])
        monitor.stop()
    }

    @MainActor
    func testDragDoubleTripleAndShiftClickAreSelectionGestures() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try mouse(.leftMouseDragged), local: false)
        monitor.handle(try mouse(.leftMouseUp), local: false)
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: false)
        monitor.handle(try mouse(.leftMouseUp, clicks: 3), local: false)
        monitor.handle(try mouse(.leftMouseUp, flags: .shift), local: false)
        XCTAssertEqual(gestures, [true, true, true, true])
        monitor.stop()
    }

    @MainActor
    func testKeyboardSelectionRearmsButTypingAndEscapeDoNot() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        var dismissals = 0
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.onDismiss = { dismissals += 1 }
        monitor.handle(try key(.keyUp, code: 124, flags: .shift), local: false)
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try key(.keyUp, code: 0, flags: .command), local: false)
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        monitor.handle(try key(.keyUp, code: 0), local: false)
        monitor.handle(try key(.keyDown, code: 53), local: false)
        XCTAssertEqual(gestures, [true, true, false])
        XCTAssertEqual(dismissals, 1)
        monitor.stop()
    }

    @MainActor
    func testCommandModifiersRequestOnlyToolbarDismissalInBothEventScopes() async throws {
        for local in [false, true] {
            let monitor = SelectionMonitor()
            var toolbarDismissals = 0, fullDismissals = 0
            var gestures: [Bool] = []
            monitor.onToolbarDismiss = { toolbarDismissals += 1 }
            monitor.onDismiss = { fullDismissals += 1 }
            monitor.onSelectionGesture = { gestures.append($0) }
            monitor.handle(try key(.flagsChanged, code: 56, flags: .shift), local: local)
            XCTAssertEqual(toolbarDismissals, 0, "Shift alone must not hide selection tools")
            monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: local)
            monitor.handle(try key(.flagsChanged, code: 56, flags: [.command, .shift]), local: local)
            XCTAssertEqual(toolbarDismissals, 1, "One press hides the toolbar immediately without repeated modifier noise")
            monitor.handle(try key(.flagsChanged, code: 55), local: local)
            XCTAssertEqual(toolbarDismissals, 1)
            XCTAssertEqual(fullDismissals, 0, "An existing streaming/final result and Apply use a different dismissal path")
            XCTAssertTrue(gestures.isEmpty, "Releasing Command alone must not reopen the dismissed toolbar")
            monitor.stop()
        }
    }

    @MainActor
    func testCommandKeyboardSelectionsRearmOnlyOnRelease() async throws {
        for (code, flags): (UInt16, NSEvent.ModifierFlags) in [(0, .command), (124, [.command, .shift])] {
            let monitor = SelectionMonitor()
            var gestures: [Bool] = []
            monitor.onSelectionGesture = { gestures.append($0) }
            monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
            monitor.handle(try key(.keyDown, code: code, flags: flags), local: false)
            monitor.handle(try key(.keyUp, code: code, flags: flags), local: false)
            XCTAssertTrue(gestures.isEmpty, "Selection can change while its toolbar remains suppressed")
            monitor.handle(try key(.flagsChanged, code: 55), local: false)
            XCTAssertEqual(gestures, [true], "Release preserves the deliberate selection gesture for a fresh read/bootstrap")
            monitor.stop()
        }
    }

    @MainActor
    func testCopyAfterSelectAllCancelsDeferredRearmAndPastePairDoesNotHideResults() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        var toolbarDismissals = 0, fullDismissals = 0
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.onToolbarDismiss = { toolbarDismissals += 1 }
        monitor.onDismiss = { fullDismissals += 1 }
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try key(.keyUp, code: 0, flags: .command), local: false)
        monitor.handle(try key(.keyDown, code: 8, flags: .command), local: false)
        monitor.handle(try key(.keyUp, code: 8, flags: .command), local: false)
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        XCTAssertEqual(gestures, [false], "Cmd+C after Cmd+A should not reopen tools when Command is released")
        XCTAssertEqual(toolbarDismissals, 1)
        // Clipboard-assisted Apply posts this fixed pair, without a physical
        // modifier flagsChanged event. It must not hide its retained result.
        monitor.handle(try key(.keyDown, code: 9, flags: .command), local: false)
        monitor.handle(try key(.keyUp, code: 9, flags: .command), local: false)
        XCTAssertEqual(toolbarDismissals, 1)
        XCTAssertEqual(fullDismissals, 0)
        monitor.stop()
    }

    @MainActor
    func testNewPointerContextCancelsDeferredCommandSelection() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try key(.keyUp, code: 0, flags: .command), local: false)
        monitor.handle(try mouse(.leftMouseDown), local: false)
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        XCTAssertTrue(gestures.isEmpty, "A later click invalidates a keyboard selection waiting for Command release")
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: false)
        XCTAssertEqual(gestures, [true])
        monitor.stop()
    }

    private func key(_ type: NSEvent.EventType, code: UInt16,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }
}
