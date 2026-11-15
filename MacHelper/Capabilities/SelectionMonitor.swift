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
    /// This separate read runs only after an explicit translation click. Normal
    /// polling never reads surrounding text, even for a selected word.
    func sentence(for selection: TextSelection) -> String? {
        guard SelectionSentenceContext.isSingleWord(selection.text) else { return nil }
        let app = AXUIElementCreateApplication(selection.sourcePID)
        AXUIElementSetMessagingTimeout(app, 0.18)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var element = focused as! AXUIElement
        for _ in 0..<4 {
            AXUIElementSetMessagingTimeout(element, 0.18)
            guard !isProtected(element) else { return nil }
            if let selected = attribute(kAXSelectedTextAttribute, of: element) as? String {
                guard selected == selection.text else { return nil }
                let expected = NSRange(location: selection.rangeLocation, length: selection.rangeLength)
                let originalRange = selectedRange(of: element)
                if let originalRange, selection.rangeLocation >= 0,
                   originalRange != expected { return nil }
                var result: String?
                if let originalRange, let count = attribute(kAXNumberOfCharactersAttribute, of: element) as? Int,
                   let window = SelectionSentenceContext.window(selection: originalRange, documentUTF16Length: count),
                   !isProtected(element),
                   let text = string(for: window, in: element),
                   (attribute(kAXNumberOfCharactersAttribute, of: element) as? Int) == count {
                    result = SelectionSentenceContext.sentence(selected: selected, selection: originalRange,
                        windowText: text, windowRange: window, documentUTF16Length: count)
                }
                if result == nil { result = markerSentence(selected: selected, in: element) }
                guard !isProtected(element), (attribute(kAXSelectedTextAttribute, of: element) as? String) == selected,
                      selectedRange(of: element) == originalRange,
                      let currentFocus = attribute(kAXFocusedUIElementAttribute, of: app), CFEqual(focused, currentFocus) else { return nil }
                return result
            }
            guard let parent = attribute(kAXParentAttribute, of: element), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

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

    private func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: -1, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func parameter(_ name: String, value: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
        return result
    }

    private func string(for range: NSRange, in element: AXUIElement) -> String? {
        guard range.length > 0, range.length <= SelectionSentenceContext.maximumUTF16 else { return nil }
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        return self.parameter(kAXStringForRangeParameterizedAttribute, value: parameter, in: element) as? String
    }

    private func markerSentence(selected: String, in element: AXUIElement) -> String? {
        // Browser engines may expose opaque text markers instead of numeric
        // character ranges. All text reads still have a verified length bound.
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let supported = names as? [String],
              Set(["AXSentenceTextMarkerRangeForTextMarker", "AXLengthForTextMarkerRange", "AXStringForTextMarkerRange"]).isSubset(of: Set(supported)),
              let selectedMarker = attribute("AXSelectedTextMarkerRange", of: element),
              let selectedLength = parameter("AXLengthForTextMarkerRange", value: selectedMarker, in: element) as? Int,
              selectedLength == selected.utf16.count,
              // Some WebKit versions implement this metadata-only parameter
              // without advertising it. A failed query returns nil; sentence
              // text still waits for the advertised API and verified length.
              let start = parameter("AXStartTextMarkerForTextMarkerRange", value: selectedMarker, in: element),
              let sentenceRange = parameter("AXSentenceTextMarkerRangeForTextMarker", value: start, in: element),
              let length = parameter("AXLengthForTextMarkerRange", value: sentenceRange, in: element) as? Int,
              !isProtected(element) else { return nil }
        let result = SelectionSentenceContext.readBoundedSentence(selected: selected, reportedUTF16Length: length) {
            parameter("AXStringForTextMarkerRange", value: sentenceRange, in: element) as? String
        }
        guard
              let currentMarker = attribute("AXSelectedTextMarkerRange", of: element), CFEqual(selectedMarker, currentMarker) else { return nil }
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

    func input(for selection: TextSelection) async -> CapabilitySelectionInput {
        guard SelectionSentenceContext.isSingleWord(selection.text), selection.sourcePID != ownPID,
              trusted, !dragging, NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.sourcePID else {
            return CapabilitySelectionInput(text: selection.text)
        }
        let capturedContext = context
        return await withCheckedContinuation { continuation in
            readQueue.async { [weak self] in
                let sentence = AccessibilitySelectionReader().sentence(for: selection)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.timer != nil, self.trusted, self.context == capturedContext,
                          !self.dragging, NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.sourcePID else {
                        continuation.resume(returning: CapabilitySelectionInput(text: selection.text)); return
                    }
                    continuation.resume(returning: CapabilitySelectionInput(text: selection.text, sentence: sentence))
                }
            }
        }
    }

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
