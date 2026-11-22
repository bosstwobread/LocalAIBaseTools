import AppKit

@MainActor
final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, event.clickCount == 2,
              !styleMask.contains(.fullScreen), let visibleFrame = screen?.visibleFrame,
              isTitleBarBackground(at: event.locationInWindow) else {
            super.sendEvent(event)
            return
        }
        if frame != visibleFrame {
            setFrame(visibleFrame, display: true, animate: true)
        }
    }

    private func isTitleBarBackground(at point: NSPoint) -> Bool {
        guard point.x >= 0, point.x < frame.width,
              point.y >= contentLayoutRect.maxY, point.y < frame.height else { return false }
        let controls: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        return !controls.compactMap { standardWindowButton($0) }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains($0.convert(point, from: nil))
        }
    }
}
