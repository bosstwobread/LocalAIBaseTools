import AppKit
import ApplicationServices

enum SelectionReadResult {
    case selection(TextSelection)
    case empty
    case unavailable
}

/// Uses read-only Accessibility attributes. It never performs AX actions or sets
/// attributes, synthesizes keystrokes, reads a whole document, or touches pasteboard.
struct AccessibilitySelectionReader {
    func read(sourcePID: Int32, mainScreenTop: CGFloat, fallbackPoint: CGPoint) -> SelectionReadResult {
        let app = AXUIElementCreateApplication(sourcePID)
        AXUIElementSetMessagingTimeout(app, 0.18)
        // A read-only role query lets Chromium activate native accessibility.
        // Chromium's -accessibilityRole implements this bootstrap; it does not
        // guarantee an Electron app exposes web contents. No AX attributes are set.
        // https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm
        _ = attribute(kAXRoleAttribute, of: app)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unavailable }
        var element = focused as! AXUIElement

        // Some editors expose the selection on their immediate text container.
        // Do not crawl arbitrary descendants or read an entire AXValue as fallback.
        for _ in 0..<4 {
            AXUIElementSetMessagingTimeout(element, 0.18)
            if isProtected(element) { return .unavailable }
            if let text = attribute(kAXSelectedTextAttribute, of: element) as? String {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
                guard text.count <= 24_000, text.utf8.count <= 96_000 else { return .unavailable }
                var range = CFRange(location: -1, length: 0)
                let rangeValue = attribute(kAXSelectedTextRangeAttribute, of: element)
                if let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                    _ = AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
                }
                var bounds = CGRect(x: fallbackPoint.x, y: fallbackPoint.y, width: 1, height: 1)
                if let rangeValue, let axBounds = boundsForRange(rangeValue, in: element) {
                    bounds = FloatingGeometry.appKitRect(fromAccessibility: axBounds, mainScreenTop: mainScreenTop)
                }
                return .selection(TextSelection(text: text, sourcePID: sourcePID,
                                                rangeLocation: range.location, rangeLength: range.length,
                                                bounds: bounds))
            }
            guard let parent = attribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unavailable }
            element = parent as! AXUIElement
        }
        return .unavailable
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func isProtected(_ element: AXUIElement) -> Bool {
        if (attribute(kAXSubroleAttribute, of: element) as? String) == kAXSecureTextFieldSubrole { return true }
        return (attribute("AXProtectedContent", of: element) as? Bool) == true
    }

    private func boundsForRange(_ range: CFTypeRef, in element: AXUIElement) -> CGRect? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        range, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect),
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.height > 0, rect.width >= 0 else { return nil }
        return rect
    }
}

@MainActor
final class SelectionMonitor {
    var onRead: ((SelectionReadResult) -> Void)?
    var onDismiss: (() -> Void)?
    var onFrontApplicationChange: (() -> Void)?
    var onPermissionChange: ((Bool) -> Void)?
    var onSelectionGesture: ((Bool) -> Void)?
    var shouldIgnoreOutsideClick: ((CGPoint) -> Bool)?
    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var debounce: DispatchWorkItem?
    private let readQueue = DispatchQueue(label: "org.localaibasetools.capabilities.selection", qos: .userInitiated)
    private var reading = false
    private var dragging = false
    private var trusted = false
    private var context: UInt64 = 0
    private var selectionPoint = NSEvent.mouseLocation
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard timer == nil else { return }
        trusted = AXIsProcessTrusted()
        installEventMonitors()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != self.ownPID else { return }
                self.context &+= 1
                self.onFrontApplicationChange?()
                self.scheduleRead()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onPermissionChange?(trusted)
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver); self.workspaceObserver = nil }
        context &+= 1
    }

    private func installEventMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        // Inspect only event type/key code/modifier flags. Typed text is not collected.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseDragged,
                                          .leftMouseUp, .rightMouseUp, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event, local: false)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event, local: true)
            return event
        }
    }

    private func handle(_ event: NSEvent, local: Bool) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let point = NSEvent.mouseLocation
            if shouldIgnoreOutsideClick?(point) == true { return }
            context &+= 1
            onDismiss?()
        case .leftMouseDragged:
            if !local { dragging = true; debounce?.cancel() }
        case .leftMouseUp, .rightMouseUp:
            let selectedByDragging = dragging
            dragging = false
            if local { return }
            selectionPoint = NSEvent.mouseLocation
            onSelectionGesture?(selectedByDragging || event.clickCount >= 2)
            scheduleRead()
        case .keyDown:
            if event.keyCode == 53 { context &+= 1; onDismiss?() }
            else if !local {
                // An older AX query must not publish the selection that existed
                // before this key changed it. Never inspect event.characters.
                context &+= 1
            }
        case .keyUp:
            if !local, event.keyCode != 53 {
                context &+= 1
                let shiftSelection = event.modifierFlags.contains(.shift) && [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode)
                let selectAll = event.keyCode == 0 && event.modifierFlags.contains(.command)
                onSelectionGesture?(shiftSelection || selectAll)
                scheduleRead()
            }
        default: break
        }
    }

    private func tick() {
        let permission = AXIsProcessTrusted()
        if permission != trusted {
            trusted = permission
            context &+= 1
            installEventMonitors()
            onPermissionChange?(permission)
            if !permission { onDismiss?() }
        }
        readSelection()
    }

    private func scheduleRead() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readSelection() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func readSelection() {
        guard trusted, !reading, !dragging,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ownPID else { return }
        reading = true
        let capturedContext = context
        let point = selectionPoint
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        readQueue.async { [weak self] in
            let result = AccessibilitySelectionReader().read(sourcePID: pid, mainScreenTop: mainTop, fallbackPoint: point)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.context == capturedContext,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.onRead?(result)
            }
        }
    }
}
