import XCTest
@testable import MacHelperCapabilities

final class GeometryTests: XCTestCase {
    func testAccessibilityConversionUsesMainScreenTop() {
        let rect = FloatingGeometry.appKitRect(fromAccessibility: CGRect(x: -500, y: 100, width: 90, height: 20), mainScreenTop: 900)
        XCTAssertEqual(rect, CGRect(x: -500, y: 780, width: 90, height: 20))
    }

    func testDisplayAboveMainKeepsNegativeAXCoordinates() {
        let rect = FloatingGeometry.appKitRect(fromAccessibility: CGRect(x: 100, y: -600, width: 200, height: 30), mainScreenTop: 900)
        XCTAssertEqual(rect.minY, 1470)
    }

    func testIconPrefersAboveWhenItFits() {
        let anchor = CGRect(x: 100, y: 200, width: 150, height: 20)
        let frame = FloatingGeometry.frame(size: CGSize(width: 34, height: 34), near: anchor,
                                           in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame.minY, anchor.maxY + 7)
        XCTAssertEqual(frame.minX, anchor.minX)
    }

    func testResultMovesBelowWhenTopHasNoRoom() {
        let anchor = CGRect(x: 100, y: 760, width: 150, height: 20)
        let frame = FloatingGeometry.frame(size: CGSize(width: 380, height: 268), near: anchor,
                                           in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame.maxY, anchor.minY - 7)
    }

    func testPanelClampsInsideNegativeOriginDisplay() {
        let screen = CGRect(x: -1600, y: -200, width: 1600, height: 900)
        let frame = FloatingGeometry.frame(size: CGSize(width: 380, height: 268),
                                           near: CGRect(x: -20, y: 680, width: 10, height: 20), in: screen)
        XCTAssertTrue(screen.insetBy(dx: 6, dy: 6).contains(frame))
        XCTAssertEqual(frame.maxX, -6)
    }

    func testOversizedPanelFitsSmallDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = FloatingGeometry.frame(size: CGSize(width: 380, height: 268),
                                           near: CGRect(x: 500, y: 500, width: 1, height: 1), in: screen)
        XCTAssertEqual(frame, screen.insetBy(dx: 6, dy: 6))
    }

    func testScreenChoosesSecondaryDisplayBySelection() {
        let first = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let second = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        XCTAssertEqual(FloatingGeometry.screen(for: CGRect(x: -500, y: 200, width: 100, height: 20),
                                               visibleFrames: [first, second]), second)
    }

    func testKeyboardSelectionWithEmptyAXBoundsStaysInTheEditorOnAnotherDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let secondary = CGRect(x: 1400, y: 350, width: 1200, height: 800)
        let editor = CGRect(x: 1500, y: 475, width: 800, height: 500)
        let placement = SelectionToolbarAnchor(screens: [primary, secondary],
            pointer: CGPoint(x: 200, y: 200), fromPointerGesture: false)
        let bounds = placement.anchor(range: .zero, editor: editor, window: secondary).bounds
        XCTAssertEqual(bounds.origin, CGPoint(x: editor.midX, y: editor.midY))
        XCTAssertEqual(FloatingGeometry.screen(for: bounds, visibleFrames: [primary, secondary]), secondary)
    }

    func testKeyboardAnchorFallsBackToVisibleWindowWhenEditorIsOffscreen() {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let upper = CGRect(x: 0, y: 800, width: 900, height: 600)
        let window = CGRect(x: 200, y: 1250, width: 1400, height: 400)
        let placement = SelectionToolbarAnchor(screens: [primary, upper], pointer: CGPoint(x: 80, y: 80), fromPointerGesture: false)
        let bounds = placement.anchor(range: CGRect(x: 30, y: 0, width: 170, height: 20), editor: .infinite, window: window).bounds
        let visible = window.intersection(upper)
        XCTAssertEqual(bounds.origin, CGPoint(x: visible.midX, y: visible.midY))
        let good = CGRect(x: 290, y: 1300, width: 130, height: 18)
        XCTAssertEqual(placement.anchor(range: good, editor: nil, window: window).bounds, good)
    }

    func testMouseSelectionDiscardsRemoteOrMisplacedBoundsAndUsesGestureDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = CGRect(x: -900, y: 0, width: 900, height: 700)
        let pointer = CGPoint(x: -60, y: 130)
        let placement = SelectionToolbarAnchor(screens: [primary, secondary], pointer: pointer, fromPointerGesture: true)
        for rect in [CGRect(x: 20, y: 10, width: 60, height: 20), CGRect(x: -300, y: 500, width: 60, height: 20)] {
            XCTAssertEqual(placement.anchor(range: rect, editor: nil, window: secondary).bounds.origin, pointer)
        }
        let acrossDisplays = CGRect(x: -75, y: 127, width: 120, height: 18)
        XCTAssertEqual(placement.anchor(range: acrossDisplays, editor: nil, window: nil).bounds, acrossDisplays.intersection(secondary))
    }

    func testMouseToolbarClearsEstimatedRowsInEitherDragDirection() {
        let screen = CGRect(x: -800, y: 0, width: 800, height: 600)
        let size = CGSize(width: 84, height: 46)
        let high = CGPoint(x: -180, y: 320)
        let low = CGPoint(x: -40, y: 296)
        for (start, end) in [(high, low), (low, high)] {
            let placement = SelectionToolbarAnchor(screens: [screen], pointer: end, fromPointerGesture: true)
            let anchor = placement.anchor(range: nil, editor: nil, window: screen, dragStart: start)
            let baseline = FloatingGeometry.frame(size: size, near: anchor.bounds, in: screen)
            let toolbar = FloatingGeometry.toolbarFrame(size: size, near: anchor.bounds, in: screen,
                                                        adjustment: anchor.adjustment)
            XCTAssertEqual(toolbar.minX, baseline.minX)
            XCTAssertEqual(toolbar.size, baseline.size)
            if end == low { XCTAssertEqual(toolbar.maxY, 280) }
            else { XCTAssertEqual(toolbar.minY, 336) }
        }
    }

    func testMouseToolbarUsesNearbySideOfReportedTallSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let range = CGRect(x: 90, y: 200, width: 500, height: 360)
        let placement = SelectionToolbarAnchor(screens: [screen], pointer: CGPoint(x: 350, y: 205), fromPointerGesture: true)
        let anchor = placement.anchor(range: range, editor: nil, window: screen)
        XCTAssertEqual(anchor.bounds, range)
        let toolbar = FloatingGeometry.toolbarFrame(size: CGSize(width: 84, height: 46), near: range,
                                                    in: screen, adjustment: anchor.adjustment)
        XCTAssertEqual(toolbar.minX, range.minX)
        XCTAssertEqual(toolbar.maxY, range.minY - 7)
        XCTAssertFalse(toolbar.intersects(range))
    }

    func testMouseToolbarFindsClearSideAtTopAndBottomOfScreen() throws {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 84, height: 46)
        for (start, end) in [(562.0, 580.0), (40.0, 20.0)] {
            let placement = SelectionToolbarAnchor(screens: [screen], pointer: CGPoint(x: 420, y: end), fromPointerGesture: true)
            let anchor = placement.anchor(range: nil, editor: nil, window: screen, dragStart: CGPoint(x: 190, y: start))
            let adjustment = try XCTUnwrap(anchor.adjustment)
            let toolbar = FloatingGeometry.toolbarFrame(size: size, near: anchor.bounds, in: screen,
                                                        adjustment: adjustment)
            XCTAssertEqual(toolbar.minX, 420)
            XCTAssertTrue(screen.insetBy(dx: 6, dy: 6).contains(toolbar))
            if start < end {
                XCTAssertLessThanOrEqual(toolbar.maxY, adjustment.occupiedY.lowerBound)
                XCTAssertLessThanOrEqual(end - toolbar.maxY, 32)
            } else {
                XCTAssertGreaterThanOrEqual(toolbar.minY, adjustment.occupiedY.upperBound)
                XCTAssertLessThanOrEqual(toolbar.minY - end, 32)
            }
        }
    }

    func testMouseToolbarUsesLeastOverlapWhenClearPlacementWouldBeTooFar() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 84, height: 46)
        let range = CGRect(x: 90, y: 200, width: 500, height: 300)
        let placement = SelectionToolbarAnchor(screens: [screen], pointer: CGPoint(x: 140, y: 240), fromPointerGesture: true)
        let anchor = placement.anchor(range: range, editor: nil, window: screen)
        let toolbar = FloatingGeometry.toolbarFrame(size: size, near: range, in: screen, adjustment: anchor.adjustment)
        XCTAssertEqual(toolbar.minX, range.minX)
        XCTAssertEqual(toolbar.maxY, 208)
        XCTAssertEqual(toolbar.intersection(range).height, 8)
    }

    func testToolbarKeepsExistingPositionWithoutCredibleGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = CGRect(x: 100, y: 100, width: 620, height: 400)
        let mouse = SelectionToolbarAnchor(screens: [screen], pointer: CGPoint(x: 300, y: 200), fromPointerGesture: true)
        XCTAssertNil(mouse.anchor(range: nil, editor: nil, window: window, dragStart: CGPoint(x: 200, y: 205)).adjustment)
        XCTAssertNil(mouse.anchor(range: nil, editor: nil, window: window, dragStart: CGPoint(x: 200, y: 510)).adjustment)
        XCTAssertNil(mouse.anchor(range: nil, editor: nil, window: nil, dragStart: CGPoint(x: 200, y: 230)).adjustment)

        let singleLine = CGRect(x: 270, y: 192, width: 60, height: 18)
        let anchor = mouse.anchor(range: singleLine, editor: nil, window: window)
        let size = CGSize(width: 84, height: 46)
        XCTAssertEqual(FloatingGeometry.toolbarFrame(size: size, near: anchor.bounds, in: screen, adjustment: anchor.adjustment),
                       FloatingGeometry.frame(size: size, near: anchor.bounds, in: screen))
        let keyboard = SelectionToolbarAnchor(screens: [screen], pointer: mouse.pointer, fromPointerGesture: false)
        XCTAssertNil(keyboard.anchor(range: singleLine, editor: nil, window: window, dragStart: CGPoint(x: 200, y: 230)).adjustment)
    }

    func testNoScreensProducesNoPlacement() {
        XCTAssertNil(FloatingGeometry.screen(for: .zero, visibleFrames: []))
    }
}
