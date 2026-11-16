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
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        func withinBudget() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        func readAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            guard withinBudget() else { return nil }
            return attribute(name, of: element)
        }
        func readRange(of element: AXUIElement) -> NSRange? {
            guard withinBudget() else { return nil }
            return selectedRange(of: element)
        }
        let app = AXUIElementCreateApplication(selection.sourcePID)
        AXUIElementSetMessagingTimeout(app, 0.18)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: app),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var element = focused as! AXUIElement
        var ancestors: [AXUIElement] = []
        // Stay on the focused element's short ancestor chain. A browser may
        // expose selected text on one node and document markers on its WebArea.
        for _ in 0..<8 {
            guard withinBudget(), !ancestors.contains(where: { CFEqual($0, element) }) else { break }
            AXUIElementSetMessagingTimeout(element, 0.18)
            guard !isProtected(element, continuing: withinBudget) else { return nil }
            ancestors.append(element)
            if CFEqual(element, app) { break }
            guard let parent = readAttribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        // Prove the same source selection that the normal reader observed.
        // Its numeric offsets belong to this node, never to an ancestor.
        var origin: (index: Int, range: NSRange?)?
        for (index, candidate) in ancestors.prefix(4).enumerated() {
            guard withinBudget() else { return nil }
            if let text = readAttribute(kAXSelectedTextAttribute, of: candidate) as? String {
                guard text == selection.text else { return nil }
                let range = readRange(of: candidate)
                if selection.rangeLocation >= 0,
                   range != NSRange(location: selection.rangeLocation, length: selection.rangeLength) { return nil }
                origin = (index, range)
                break
            }
        }
        guard let origin else { return nil }
        let source = ancestors[origin.index]
        func currentSelection() -> Bool {
            guard withinBudget(), AXIsProcessTrusted(),
                  ancestors.allSatisfy({ !isProtected($0, continuing: withinBudget) }), withinBudget(),
                  (readAttribute(kAXSelectedTextAttribute, of: source) as? String) == selection.text,
                  readRange(of: source) == origin.range,
                  let currentFocus = readAttribute(kAXFocusedUIElementAttribute, of: app),
                  CFEqual(focused, currentFocus) else { return false }
            return withinBudget()
        }
        for candidate in ancestors.dropFirst(origin.index) {
            guard withinBudget() else { return nil }
            var result: String?
            let role = readAttribute(kAXRoleAttribute, of: candidate) as? String
            // Numeric ranges describe the whole text control in editors. A
            // browser's static inline node may describe only a sentence fragment.
            if [kAXTextAreaRole, kAXTextFieldRole].contains(role ?? ""),
               (readAttribute(kAXSelectedTextAttribute, of: candidate) as? String) == selection.text,
               let range = readRange(of: candidate),
               let count = readAttribute(kAXNumberOfCharactersAttribute, of: candidate) as? Int,
               let window = SelectionSentenceContext.window(selection: range, documentUTF16Length: count),
               currentSelection(), let text = string(for: window, in: candidate),
               withinBudget(), (readAttribute(kAXNumberOfCharactersAttribute, of: candidate) as? Int) == count,
               readRange(of: candidate) == range {
                result = SelectionSentenceContext.sentence(selected: selection.text, selection: range,
                    windowText: text, windowRange: window, documentUTF16Length: count)
            }
            if result == nil {
                result = markerSentence(selected: selection.text, in: candidate,
                                        withinBudget: withinBudget, canReadText: currentSelection)
            }
            if let result { return currentSelection() ? result : nil }
            // Unsupported context on a child must not hide a capable WebArea.
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
                let rangeValue = attribute(kAXSelectedTextRangeAttribute, of: element)
                var numericRange: NSRange?
                if let rangeValue {
                    var range = CFRange(location: -1, length: 0)
                    guard CFGetTypeID(rangeValue) == AXValueGetTypeID(),
                          AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return .unavailable }
                    numericRange = NSRange(location: range.location, length: range.length)
                }
                // AXSelectedText can be cached after a browser clears its
                // selection. A caret (zero-length range) is not selected text.
                // Read-only web text may instead expose opaque text markers.
                let marker = numericRange == nil ? markerSelection(text: text, from: element) : nil
                guard SelectionEvidence.isSelected(text: text, numericRange: numericRange,
                                                    markerLength: marker?.length, markerText: marker?.text) else { return .empty }
                if let numericRange, selectedRange(of: element) != numericRange { return .unavailable }
                guard (attribute(kAXSelectedTextAttribute, of: element) as? String)?.utf16.elementsEqual(text.utf16) == true,
                      let currentFocus = attribute(kAXFocusedUIElementAttribute, of: app),
                      CFEqual(focused, currentFocus) else { return .unavailable }
                var bounds = CGRect(x: fallbackPoint.x, y: fallbackPoint.y, width: 1, height: 1)
                if let rangeValue, let axBounds = boundsForRange(rangeValue, in: element) {
                    bounds = FloatingGeometry.appKitRect(fromAccessibility: axBounds, mainScreenTop: mainScreenTop)
                }
                return .selection(TextSelection(text: text, sourcePID: sourcePID,
                                                rangeLocation: numericRange?.location ?? -1,
                                                rangeLength: numericRange?.length ?? text.utf16.count,
                                                bounds: bounds))
            }
            guard let parent = attribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unavailable }
            element = parent as! AXUIElement
        }
        return .unavailable
    }

    /// Verify the selected range only, never an enclosing document. Chromium
    /// may expose markers on a focused static node's short ancestor chain.
    private func markerSelection(text: String, from origin: AXUIElement) -> (length: Int, text: String)? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var element = origin
        var visited: [AXUIElement] = []
        for _ in 0..<4 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  !visited.contains(where: { CFEqual($0, element) }) else { return nil }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.12)
            guard !isProtected(element) else { return nil }
            if let value = attribute("AXSelectedTextMarkerRange", of: element),
               CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() {
                let selected = value as! AXTextMarkerRange
                let start = AXTextMarkerRangeCopyStartMarker(selected)
                let end = AXTextMarkerRangeCopyEndMarker(selected)
                guard !CFEqual(start, end),
                      let orderedValue = parameter("AXTextMarkerRangeForUnorderedTextMarkers", value: [start, end] as CFArray, in: element),
                      CFGetTypeID(orderedValue) == AXTextMarkerRangeGetTypeID(),
                      let length = parameter("AXLengthForTextMarkerRange", value: orderedValue, in: element) as? Int,
                      length > 0, length == text.utf16.count,
                      ProcessInfo.processInfo.systemUptime < deadline,
                      let actual = parameter("AXStringForTextMarkerRange", value: orderedValue, in: element) as? String,
                      let current = attribute("AXSelectedTextMarkerRange", of: element), CFEqual(value, current),
                      ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                return (length, actual)
            }
            guard let parent = attribute(kAXParentAttribute, of: element),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
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

    private func markerSentence(selected: String, in element: AXUIElement,
                                withinBudget: @escaping () -> Bool,
                                canReadText: @escaping () -> Bool) -> String? {
        func query(_ name: String, _ value: CFTypeRef) -> CFTypeRef? {
            guard withinBudget() else { return nil }
            return parameter(name, value: value, in: element)
        }
        func range(_ value: CFTypeRef?) -> AXTextMarkerRange? {
            guard let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
            return (value as! AXTextMarkerRange)
        }
        func marker(_ value: CFTypeRef?) -> AXTextMarker? {
            guard let value, CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
            return (value as! AXTextMarker)
        }
        return TextMarkerSentenceReader<AXTextMarkerRange, AXTextMarker>(
            selectedRange: {
                guard withinBudget(), let selectedRange = range(attribute("AXSelectedTextMarkerRange", of: element)) else { return nil }
                // Marker ranges can follow a backwards drag. Ask the provider
                // to order the opaque endpoints; never infer document offsets.
                let endpoints = [AXTextMarkerRangeCopyStartMarker(selectedRange), AXTextMarkerRangeCopyEndMarker(selectedRange)] as CFArray
                return range(query("AXTextMarkerRangeForUnorderedTextMarkers", endpoints))
            },
            equalsRange: { CFEqual($0, $1) },
            startMarker: { AXTextMarkerRangeCopyStartMarker($0) },
            endMarker: { AXTextMarkerRangeCopyEndMarker($0) },
            makeRange: { AXTextMarkerRangeCreate(nil, $0, $1) },
            paragraphRange: { selectedRange in
                // Chromium's built-in sentence/paragraph expansion can stop at
                // inline links/bold text. Explicit navigation crosses anchors.
                // Opposite endpoints also handle first/last words in a paragraph.
                let start = AXTextMarkerRangeCopyStartMarker(selectedRange)
                let end = AXTextMarkerRangeCopyEndMarker(selectedRange)
                guard let paragraphStart = marker(query("AXPreviousParagraphStartTextMarkerForTextMarker", end)),
                      let paragraphEnd = marker(query("AXNextParagraphEndTextMarkerForTextMarker", start)) else { return nil }
                return AXTextMarkerRangeCreate(nil, paragraphStart, paragraphEnd)
            },
            length: { query("AXLengthForTextMarkerRange", $0) as? Int },
            string: {
                guard canReadText() else { return nil }
                return query("AXStringForTextMarkerRange", $0) as? String
            },
            canRead: withinBudget
        ).read(selected: selected)
    }

    private func isProtected(_ element: AXUIElement, continuing: () -> Bool = { true }) -> Bool {
        guard continuing() else { return true }
        if (attribute(kAXSubroleAttribute, of: element) as? String) == kAXSecureTextFieldSubrole { return true }
        guard continuing() else { return true }
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
    var isInteractingWithOverlay: (() -> Bool)?
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

    // Internal so synthetic event-policy tests can exercise dismissal/rearm
    // without installing monitors or posting events into any application.
    func handle(_ event: NSEvent, local: Bool) {
        // AppKit captures a header drag even after the cursor leaves its panel.
        // Ignore that entire pointer sequence; Esc and app changes still dismiss.
        if isInteractingWithOverlay?() == true,
           [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp].contains(event.type) { return }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let point = CapabilityDragPointer.screenPoint(for: event, window: event.window,
                primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
            if shouldIgnoreOutsideClick?(point) == true { return }
            context &+= 1
            onDismiss?()
        case .leftMouseDragged:
            if !local { dragging = true; debounce?.cancel() }
        case .leftMouseUp, .rightMouseUp:
            let selectedByDragging = dragging
            dragging = false
            if local { return }
            selectionPoint = CapabilityDragPointer.screenPoint(for: event, window: event.window,
                primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
            let selecting = event.type == .leftMouseUp &&
                (selectedByDragging || event.clickCount >= 2 || event.modifierFlags.contains(.shift))
            onSelectionGesture?(selecting)
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
        guard trusted, !reading, !dragging, isInteractingWithOverlay?() != true,
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
                      self.isInteractingWithOverlay?() != true,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.onRead?(result)
            }
        }
    }
}
