import AppKit
import XCTest
@testable import MacHelperCapabilities

/// Exercises actual offscreen AppKit controls, without selection reads, AI,
/// clipboard access, event posting, or ordering a window onto the desktop.
@MainActor
final class SelectionToolbarTests: XCTestCase {
    private func buttons() -> [NSButton] {
        func visit(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(visit)
        }
        return NSApplication.shared.windows.flatMap { window in
            window.contentView.map(visit) ?? []
        }
    }

    func testIconCellsHaveDistinctTargetsAndDoNotOverlapIncludingOverflow() throws {
        _ = NSApplication.shared
        for count in [1, 2, 5, 6, 20] {
            let panels = FloatingCapabilityPanels(toolTitle: "Offscreen toolbar fixture", systemSymbolName: "pencil")
            let prefix = "icon-fixture-\(UUID().uuidString)/"
            let actions = (0..<count).map { (identifier: prefix + "\($0)", title: "Localized action \($0)", systemSymbolName: $0 == 0 ? "not.a.real.symbol" : "character.bubble") }
            panels.setActions(actions)
            let window = try XCTUnwrap(buttons().first { $0.accessibilityIdentifier().hasPrefix(prefix) }?.window)
            let controls = buttons().filter { $0.window === window }
            XCTAssertEqual(controls.count, min(count, 5))
            defer { window.close() }
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isVisible)
            XCTAssertLessThanOrEqual(window.frame.width, 198)
            let frames = controls.map { $0.convert($0.bounds, to: nil) }
            for (index, frame) in frames.enumerated() {
                XCTAssertGreaterThanOrEqual(frame.width, 34)
                XCTAssertGreaterThanOrEqual(frame.height, 34)
                for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
            }
            var selected: String?
            panels.onPerformAction = { selected = $0 }
            for (index, action) in actions.prefix(count > 5 ? 4 : count).enumerated() {
                let button = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == action.identifier })
                XCTAssertEqual(button.title, "")
                XCTAssertNotNil(button.image, "Unknown symbols must retain a visible fallback icon")
                XCTAssertEqual(button.accessibilityLabel(), action.title)
                XCTAssertTrue(button.toolTip?.contains(action.title) == true)
                button.performClick(nil)
                XCTAssertEqual(selected, actions[index].identifier)
            }
            if count > 5 {
                let more = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == "selection-toolbar-more" })
                XCTAssertNotNil(more.image)
                XCTAssertEqual(more.title, "")
                XCTAssertEqual(more.menu?.items.compactMap { $0.representedObject as? String }, actions.dropFirst(4).map(\.identifier))
                for item in [more.menu?.items.first, more.menu?.items.last].compactMap({ $0 }) {
                    let action = try XCTUnwrap(item.action)
                    XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
                    XCTAssertEqual(selected, item.representedObject as? String)
                }
            }
            func mirror(_ view: NSView) {
                view.userInterfaceLayoutDirection = .rightToLeft
                view.needsLayout = true
                view.subviews.forEach(mirror)
            }
            if let content = window.contentView { mirror(content); content.layoutSubtreeIfNeeded() }
            let mirroredFrames = controls.map { $0.convert($0.bounds, to: nil) }
            for (index, frame) in mirroredFrames.enumerated() {
                for other in mirroredFrames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
            }
        }
    }
}
