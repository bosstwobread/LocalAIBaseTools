import AppKit
import XCTest
@testable import MacHelperCapabilities

final class SelectionMonitorTests: XCTestCase {
    @MainActor
    func testPointerSelectionRecoversFromMissedCommandRelease() async throws {
        let monitor = SelectionMonitor()
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try mouse(.leftMouseDown), local: false)
        monitor.handle(try mouse(.leftMouseUp), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture(), "A plain click can reconcile Command without selecting")
        for clicks in [2, 3] {
            monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
            monitor.handle(try mouse(.leftMouseDown, clicks: clicks), local: false)
            monitor.handle(try mouse(.leftMouseUp), local: false)
            XCTAssertTrue(monitor.consumeCopyGesture())
            XCTAssertFalse(monitor.consumeCopyGesture())
        }
        monitor.stop()
    }

    @MainActor
    func testMultiClickDeliveredToSourceWhenAnotherPanelCoversTheSamePoint() async throws {
        let monitor = SelectionMonitor()
        monitor.shouldIgnoreOutsideClick = { _ in true }
        monitor.handle(try mouse(.leftMouseDown, clicks: 2), local: false)
        monitor.handle(try mouse(.leftMouseUp), local: false)
        XCTAssertTrue(monitor.consumeCopyGesture())
        monitor.handle(try mouse(.leftMouseDown, clicks: 2), local: true)
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: true)
        XCTAssertFalse(monitor.consumeCopyGesture(), "Clicking MacHelper itself must not schedule Copy")
        monitor.stop()
    }

    @MainActor
    func testPollingCannotBypassMultiClickSettlingDelay() async throws {
        let monitor = SelectionMonitor()
        monitor.handle(try mouse(.leftMouseDown, clicks: 2), local: false)
        monitor.handle(try mouse(.leftMouseUp, clicks: 1), local: false)
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(monitor.isReadDeferred(at: now))
        XCTAssertTrue(monitor.isReadDeferred(at: now + 0.05))
        XCTAssertFalse(monitor.isReadDeferred(at: now + 0.14), "An AX-visible word need not wait for Copy eligibility")
        monitor.handle(try mouse(.leftMouseDown), local: false)
        XCTAssertFalse(monitor.isReadDeferred(at: now + 0.1), "New input cancels the old settling context")
        monitor.stop()
    }
    @MainActor
    func testMultiClickIntentSurvivesMouseUpWithResetClickCount() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        for clicks in [2, 3] {
            monitor.handle(try mouse(.leftMouseDown, clicks: clicks), local: false)
            monitor.handle(try mouse(.leftMouseUp, clicks: 1), local: false)
        }
        XCTAssertEqual(gestures, [true, true])
        monitor.handle(try mouse(.leftMouseDown), local: false)
        monitor.handle(try mouse(.leftMouseUp), local: false)
        XCTAssertEqual(gestures, [true, true, false], "A later ordinary click cannot reuse the multi-click latch")
        monitor.stop()
    }

    @MainActor
    func testShiftClickIntentSurvivesShiftReleaseBeforeMouseUp() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try mouse(.leftMouseDown, flags: .shift), local: false)
        monitor.handle(try mouse(.leftMouseUp), local: false)
        XCTAssertEqual(gestures, [true])
        monitor.stop()
    }
    @MainActor
    func testSelectAllRecognizedWithEitherReleaseOrder() async throws {
        for (code, flags): (UInt16, NSEvent.ModifierFlags) in [(0, .command), (124, [.command, .shift])] {
          for commandReleasedFirst in [false, true] {
            let monitor = SelectionMonitor()
            var gestures: [Bool] = []
            monitor.onSelectionGesture = { gestures.append($0) }
            monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
            monitor.handle(try key(.keyDown, code: code, flags: flags), local: false)
            XCTAssertFalse(monitor.consumeCopyGesture(), "Command still suppresses the toolbar")
            if commandReleasedFirst {
                monitor.handle(try key(.flagsChanged, code: 55), local: false)
                monitor.handle(try key(.keyUp, code: code), local: false)
            } else {
                monitor.handle(try key(.keyUp, code: code, flags: flags), local: false)
                monitor.handle(try key(.flagsChanged, code: 55), local: false)
            }
            XCTAssertEqual(gestures, [true])
            XCTAssertTrue(monitor.consumeCopyGesture(), "The matching A release cannot cancel the rearmed context")
            XCTAssertFalse(monitor.consumeCopyGesture(), "One chord permits at most one Copy attempt")
            monitor.stop()
          }
        }
    }

    @MainActor
    func testSelectAllRecoversWhenModifierNotificationsAreMissing() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try key(.keyDown, code: 0, flags: .command), local: false)
        XCTAssertTrue(gestures.isEmpty)
        monitor.handle(try key(.keyUp, code: 0), local: false)
        XCTAssertEqual(gestures, [true], "The latched shortcut survives loss of Command on keyUp")
        XCTAssertTrue(monitor.consumeCopyGesture())
        monitor.stop()
    }

    @MainActor
    func testShiftNavigationSurvivesShiftReleaseBeforeArrowRelease() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try key(.keyDown, code: 124, flags: .shift), local: false)
        monitor.handle(try key(.keyDown, code: 124, flags: .shift, repeated: true), local: false)
        XCTAssertTrue(gestures.isEmpty, "Wait for navigation key release before arming capture")
        monitor.handle(try key(.flagsChanged, code: 56), local: false)
        monitor.handle(try key(.keyUp, code: 124), local: false)
        XCTAssertEqual(gestures, [true])
        XCTAssertTrue(monitor.consumeCopyGesture())
        monitor.stop()
    }

    @MainActor
    func testRepeatingSelectAllDoesNotArmAdditionalCopyAttempts() async throws {
        let monitor = SelectionMonitor()
        var gestures: [Bool] = []
        monitor.onSelectionGesture = { gestures.append($0) }
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try key(.keyDown, code: 0, flags: .command), local: false)
        for _ in 0..<3 {
            monitor.handle(try key(.keyDown, code: 0, flags: .command, repeated: true), local: false)
        }
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        XCTAssertTrue(monitor.consumeCopyGesture())
        monitor.handle(try key(.keyUp, code: 0), local: false)
        XCTAssertEqual(gestures, [true])
        XCTAssertFalse(monitor.consumeCopyGesture(), "The late key release must not arm a second Copy")
        monitor.stop()
    }

    @MainActor
    func testCopyCutAndTypingCancelLatchedSelectAllEvenWithLateKeyUpAndRepeat() async throws {
        for cancellationKey: UInt16 in [7, 8, 11] {
            let monitor = SelectionMonitor()
            var gestures: [Bool] = []
            monitor.onSelectionGesture = { gestures.append($0) }
            monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
            monitor.handle(try key(.keyDown, code: 0, flags: .command), local: false)
            monitor.handle(try key(.keyDown, code: cancellationKey, flags: .command), local: false)
            monitor.handle(try key(.keyUp, code: cancellationKey, flags: .command), local: false)
            monitor.handle(try key(.keyDown, code: 0, flags: .command, repeated: true), local: false)
            monitor.handle(try key(.keyUp, code: 0, flags: .command), local: false)
            monitor.handle(try key(.flagsChanged, code: 55), local: false)
            XCTAssertFalse(gestures.contains(true), "A cancelled chord must not rearm on its later A release")
            XCTAssertFalse(monitor.consumeCopyGesture())
            monitor.stop()
        }
    }

    @MainActor
    func testCancelledLateKeyUpCannotCancelANewerMouseGesture() async throws {
        let monitor = SelectionMonitor()
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try key(.keyDown, code: 0, flags: .command), local: false)
        monitor.handle(try mouse(.leftMouseDown), local: false)
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: false)
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        monitor.handle(try key(.keyUp, code: 0), local: false)
        XCTAssertTrue(monitor.consumeCopyGesture(), "Old key releases cannot invalidate a new explicit selection")
        monitor.stop()
    }

    @MainActor
    func testCopyFallbackIsArmedOnlyOncePerSelectionGesture() async throws {
        let monitor = SelectionMonitor()
        XCTAssertFalse(monitor.consumeCopyGesture())
        monitor.handle(try mouse(.leftMouseUp), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture(), "Ordinary clicks must not copy")
        monitor.handle(try mouse(.rightMouseUp, clicks: 2), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture(), "Right clicks must not copy")
        monitor.handle(try mouse(.leftMouseDragged), local: false)
        monitor.handle(try mouse(.leftMouseUp), local: false)
        XCTAssertTrue(monitor.consumeCopyGesture())
        XCTAssertFalse(monitor.consumeCopyGesture(), "A timer or subsequent read cannot copy again")
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: false)
        monitor.handle(try key(.keyDown, code: 8, flags: .command), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture(), "User Copy invalidates the fallback gesture")
        monitor.stop()
    }

    @MainActor
    func testTaggedCopyEventsPreservePendingGestureButOtherEventsDoNot() async throws {
        let monitor = SelectionMonitor()
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: false)
        for down in [true, false] {
            let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: down))
            cg.flags = .maskCommand
            cg.setIntegerValueField(.eventSourceUserData, value: SelectionCopyEvents.tag)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertTrue(SelectionCopyEvents.isInternal(event))
            monitor.handle(event, local: false)
        }
        XCTAssertTrue(monitor.consumeCopyGesture())
        monitor.handle(try mouse(.leftMouseUp, clicks: 2), local: false)
        monitor.handle(try key(.keyDown, code: 7, flags: .command), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture())
        monitor.stop()
    }

    @MainActor
    func testCommandReleaseRearmsCopyOnlyForDeliberateKeyboardSelection() async throws {
        let monitor = SelectionMonitor()
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture())
        monitor.handle(try key(.keyUp, code: 0, flags: .command), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture(), "Wait for the physical Command release")
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        XCTAssertTrue(monitor.consumeCopyGesture())
        monitor.handle(try key(.flagsChanged, code: 55, flags: .command), local: false)
        monitor.handle(try key(.flagsChanged, code: 55), local: false)
        XCTAssertFalse(monitor.consumeCopyGesture(), "Command alone must not trigger Copy")
        monitor.stop()
    }
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
                     flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeated, keyCode: code))
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }
}
