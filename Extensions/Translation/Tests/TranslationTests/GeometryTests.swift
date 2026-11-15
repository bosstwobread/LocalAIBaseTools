import XCTest
@testable import Translation

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

    func testNoScreensProducesNoPlacement() {
        XCTAssertNil(FloatingGeometry.screen(for: .zero, visibleFrames: []))
    }
}
