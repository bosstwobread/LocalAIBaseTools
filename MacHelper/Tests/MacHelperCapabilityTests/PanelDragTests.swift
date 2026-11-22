import Foundation
import AppKit
import XCTest
@testable import MacHelperCapabilities

final class PanelDragTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 24, width: 1200, height: 760)
    private let size = CGSize(width: 380, height: 268)

    func testResultSharesToolbarEdgeOnEitherSide() throws {
        let anchor = CGRect(x: 100, y: 380, width: 40, height: 20)
        for above in [true, false] {
            var placement = CapabilityPanelPlacement()
            let toolbar = CGRect(x: 104, y: above ? 411 : 331, width: 76, height: 38)
            placement.alignWithToolbar(toolbar, occupiedY: anchor.minY...anchor.maxY, size: size,
                                       near: anchor, visibleFrames: [screen])
            let result = try XCTUnwrap(placement.frame(size: size, near: anchor, visibleFrames: [screen]))
            XCTAssertEqual(result.minX, anchor.minX)
            if above { XCTAssertEqual(result.minY, toolbar.minY) }
            else { XCTAssertEqual(result.maxY, toolbar.maxY) }
            XCTAssertFalse(result.intersects(anchor))
        }
    }

    func testResultStaysOnSameSideWhenItCanFitCloserToSelection() throws {
        let anchor = CGRect(x: 100, y: 470, width: 40, height: 30)
        let toolbar = CGRect(x: 104, y: 520, width: 76, height: 38)
        var placement = CapabilityPanelPlacement()
        placement.alignWithToolbar(toolbar, occupiedY: 470...500, size: size, near: anchor, visibleFrames: [screen])
        let result = try XCTUnwrap(placement.frame(size: size, near: anchor, visibleFrames: [screen]))
        XCTAssertEqual(result.minY, 507)
        XCTAssertTrue(screen.insetBy(dx: 6, dy: 6).contains(result))
    }

    func testResultChangesSidesWhenItCannotFitOnToolbarSide() throws {
        for above in [true, false] {
            let anchor = CGRect(x: 100, y: above ? 650 : 90, width: 40, height: 20)
            let toolbar = CGRect(x: 104, y: above ? 681 : 41, width: 76, height: 38)
            var placement = CapabilityPanelPlacement()
            placement.alignWithToolbar(toolbar, occupiedY: anchor.minY...anchor.maxY, size: size,
                                       near: anchor, visibleFrames: [screen])
            let result = try XCTUnwrap(placement.frame(size: size, near: anchor, visibleFrames: [screen]))
            if above { XCTAssertEqual(result.maxY, anchor.minY - 7) }
            else { XCTAssertEqual(result.minY, anchor.maxY + 7) }
            XCTAssertTrue(screen.insetBy(dx: 6, dy: 6).contains(result))
        }
    }

    func testToolbarAlignmentSurvivesAnchorChangesUntilManualDragOrDismissal() throws {
        let left = CGRect(x: -1000, y: -100, width: 1000, height: 900)
        let screens = [left, screen]
        let anchor = CGRect(x: -85, y: 365, width: 12, height: 20)
        let toolbar = CGRect(x: -82, y: 395, width: 76, height: 38)
        let changedAnchor = CGRect(x: 180, y: 140, width: 60, height: 35)
        var placement = CapabilityPanelPlacement()
        placement.alignWithToolbar(toolbar, occupiedY: 350...385, size: size, near: anchor, visibleFrames: screens)
        let first = try XCTUnwrap(placement.frame(size: size, near: anchor, visibleFrames: screens))
        XCTAssertEqual(first.minY, toolbar.minY)
        XCTAssertEqual(first.maxX, left.maxX - 6)
        XCTAssertEqual(placement.frame(size: size, near: changedAnchor, visibleFrames: screens), first)

        let pointer = CGPoint(x: first.midX, y: first.maxY - 10)
        XCTAssertTrue(placement.beginDrag(frame: first, pointer: pointer))
        let moved = try XCTUnwrap(placement.drag(to: CGPoint(x: pointer.x - 80, y: pointer.y - 40), visibleFrames: screens))
        placement.endDrag()
        XCTAssertEqual(placement.frame(size: size, near: changedAnchor, visibleFrames: screens), moved)
        placement.reset()
        XCTAssertEqual(placement.frame(size: size, near: changedAnchor, visibleFrames: screens),
                       FloatingGeometry.frame(size: size, near: changedAnchor, in: screen))
    }

    func testUserPositionSurvivesProgressCompletionRetryAndChangedAnchor() throws {
        var placement = CapabilityPanelPlacement()
        let anchor = CGRect(x: 100, y: 350, width: 40, height: 20)
        let initial = try XCTUnwrap(placement.frame(size: size, near: anchor, visibleFrames: [screen]))
        let mouse = CGPoint(x: initial.minX + 60, y: initial.maxY - 20)
        XCTAssertTrue(placement.beginDrag(frame: initial, pointer: mouse))
        let moved = try XCTUnwrap(placement.drag(to: CGPoint(x: mouse.x + 260, y: mouse.y - 80), visibleFrames: [screen]))
        placement.endDrag()
        XCTAssertFalse(placement.isDragging)
        for incomingAnchor in [anchor, CGRect(x: 900, y: 80, width: 1, height: 20), anchor] {
            XCTAssertEqual(placement.frame(size: size, near: incomingAnchor, visibleFrames: [screen]), moved,
                           "Streaming, completion, errors and retry must retain the explicit user position")
        }
    }

    func testDismissalInterruptsDragAndNewSelectionReturnsToItsOwnAnchor() throws {
        var placement = CapabilityPanelPlacement()
        let initial = CGRect(x: 100, y: 200, width: 380, height: 268)
        XCTAssertTrue(placement.beginDrag(frame: initial, pointer: CGPoint(x: 130, y: 450)))
        XCTAssertNotNil(placement.drag(to: CGPoint(x: 500, y: 400), visibleFrames: [screen]))
        placement.reset() // Esc, outside dismissal, app change or new selection.
        XCTAssertFalse(placement.isDragging)
        XCTAssertNil(placement.userFrame)
        XCTAssertNil(placement.drag(to: CGPoint(x: 600, y: 420), visibleFrames: [screen]), "Late mouse events cannot revive a dismissed result")
        let next = CGRect(x: 850, y: 150, width: 60, height: 18)
        XCTAssertEqual(placement.frame(size: size, near: next, visibleFrames: [screen]),
                       FloatingGeometry.frame(size: size, near: next, in: screen))
    }

    func testPointerChoosesNegativeOriginDisplayAndWholePanelStaysVisible() throws {
        let left = CGRect(x: -1000, y: -200, width: 1000, height: 780)
        var placement = CapabilityPanelPlacement()
        XCTAssertTrue(placement.beginDrag(frame: CGRect(origin: CGPoint(x: 10, y: 300), size: size), pointer: CGPoint(x: 30, y: 550)))
        let moved = try XCTUnwrap(placement.drag(to: CGPoint(x: -980, y: -190), visibleFrames: [left, screen]))
        XCTAssertTrue(left.insetBy(dx: 6, dy: 6).contains(moved))
        XCTAssertEqual(moved.minX, left.minX + 6)
        XCTAssertEqual(moved.minY, left.minY + 6)
    }

    func testPointerCanMovePanelOntoVerticallyArrangedDisplay() throws {
        let upper = CGRect(x: 0, y: 824, width: 1400, height: 900)
        var placement = CapabilityPanelPlacement()
        XCTAssertTrue(placement.beginDrag(frame: CGRect(origin: CGPoint(x: 200, y: 450), size: size), pointer: CGPoint(x: 240, y: 700)))
        let moved = try XCTUnwrap(placement.drag(to: CGPoint(x: 640, y: 1000), visibleFrames: [screen, upper]))
        XCTAssertTrue(upper.insetBy(dx: 6, dy: 6).contains(moved))
    }

    func testRemovedMonitorRecoversToNearestRemainingVisibleDisplay() throws {
        let removed = CGRect(x: -1600, y: 0, width: 1500, height: 1000)
        let remaining = CGRect(x: 200, y: 100, width: 1000, height: 700)
        var placement = CapabilityPanelPlacement()
        XCTAssertTrue(placement.beginDrag(frame: CGRect(origin: CGPoint(x: -1400, y: 300), size: size), pointer: CGPoint(x: -1380, y: 550)))
        XCTAssertNotNil(placement.drag(to: CGPoint(x: -1200, y: 500), visibleFrames: [removed]))
        placement.endDrag()
        let recovered = try XCTUnwrap(placement.frame(size: size, near: .zero, visibleFrames: [remaining]))
        XCTAssertTrue(remaining.insetBy(dx: 6, dy: 6).contains(recovered))
    }

    func testTinyDisplayFitsPanelAndInvalidGeometryCannotMoveIt() throws {
        let tiny = CGRect(x: -200, y: -100, width: 220, height: 180)
        let frame = try XCTUnwrap(CapabilityPanelPlacement.clamped(CGRect(x: 500, y: 500, width: 380, height: 268), visibleFrames: [tiny]))
        XCTAssertTrue(tiny.insetBy(dx: 6, dy: 6).contains(frame))
        var placement = CapabilityPanelPlacement()
        XCTAssertFalse(placement.beginDrag(frame: CGRect(x: CGFloat.nan, y: 0, width: 380, height: 268), pointer: .zero))
        XCTAssertNil(CapabilityPanelPlacement.clamped(frame, visibleFrames: []))
        XCTAssertNil(placement.drag(to: .zero, visibleFrames: [screen]))
    }

    @MainActor
    func testDragUsesEachRecordedEventPositionInsteadOfPollingTheCurrentCursor() async throws {
        let locations = [CGPoint(x: 100, y: 200), CGPoint(x: 420, y: 350), CGPoint(x: 500, y: 410)]
        let events = try locations.enumerated().map { index, point in
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: index == 0 ? .leftMouseDown : .leftMouseDragged,
                                             mouseCursorPosition: point, mouseButton: .left))
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        // All three event records exist before they are processed; no events
        // are posted, and the real mouse can remain anywhere on the desktop.
        let points = events.map { CapabilityDragPointer.screenPoint(for: $0, window: nil, primaryScreenTop: 900) }
        XCTAssertEqual(points, [CGPoint(x: 100, y: 700), CGPoint(x: 420, y: 550), CGPoint(x: 500, y: 490)])
        var placement = CapabilityPanelPlacement()
        XCTAssertTrue(placement.beginDrag(frame: CGRect(x: 100, y: 300, width: 380, height: 268), pointer: points[0]))
        let moved = try XCTUnwrap(placement.drag(to: points[1], visibleFrames: [screen]))
        XCTAssertEqual(moved.origin, CGPoint(x: 420, y: 150))
    }

    @MainActor
    func testHeaderDragDoesNotDismissOrRearmSelectionButEscapeStillDismisses() async throws {
        let monitor = SelectionMonitor()
        var dismissals = 0
        var gestures = 0
        monitor.isInteractingWithOverlay = { true }
        monitor.onDismiss = { dismissals += 1 }
        monitor.onSelectionGesture = { _ in gestures += 1 }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
            monitor.handle(event, local: false)
            monitor.handle(event, local: true)
        }
        XCTAssertEqual(dismissals, 0, "The pointer leaving a captured header must not become an outside click")
        XCTAssertEqual(gestures, 0, "Moving the result must not create a text-selection gesture")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        monitor.handle(escape, local: true)
        XCTAssertEqual(dismissals, 1, "Header capture must preserve Escape dismissal")
    }

    @MainActor
    func testQueuedHeaderMouseDownChecksItsRecordedPositionBeforeCaptureBegins() async throws {
        let monitor = SelectionMonitor()
        let pointer = CGPoint(x: 37, y: 49)
        let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                          mouseCursorPosition: pointer, mouseButton: .left))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        let expected = CGPoint(x: pointer.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - pointer.y)
        var observed: CGPoint?
        var dismissals = 0
        monitor.onDismiss = { dismissals += 1 }
        monitor.shouldIgnoreOutsideClick = { observed = $0; return $0 == expected }
        monitor.handle(event, local: true)
        XCTAssertEqual(observed, expected)
        XCTAssertEqual(dismissals, 0, "A queued header click must not become an outside click at the live cursor's later position")
        monitor.stop()
    }
}
