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
        for (code, flags): (UInt16, NSEvent.ModifierFlags) in [(124, .shift), (0, .command), (0, []), (53, [])] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: code == 53 ? .keyDown : .keyUp,
                location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            monitor.handle(event, local: false)
        }
        XCTAssertEqual(gestures, [true, true, false])
        XCTAssertEqual(dismissals, 1)
        monitor.stop()
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }
}
