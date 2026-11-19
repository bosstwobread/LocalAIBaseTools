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
            return AccessibilitySelectedText.numericRange(of: element, continuing: withinBudget)
        }
        let app = AXUIElementCreateApplication(selection.sourcePID)
        AXUIElementSetMessagingTimeout(app, 0.18)
        let capturedOrigin = selection.accessibilityOrigin
        let focus = capturedOrigin == nil ? AccessibilityFocusResolver.read(application: app) : nil
        func sameOrigin() -> Bool {
            guard withinBudget() else { return false }
            if let capturedOrigin { return capturedOrigin.isCurrent(continuing: withinBudget) }
            return focus.map { AccessibilityFocusResolver.matches($0, application: app) } ?? false
        }
        guard sameOrigin(), let initial = capturedOrigin?.source ?? focus?.leaf else { return nil }
        var element = initial
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
            if case .selected(let span) = AccessibilitySelectedText.read(candidate, continuing: withinBudget) {
                guard span.text.utf16.elementsEqual(selection.text.utf16) else { return nil }
                let range = span.range
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
                  case .selected(let span) = AccessibilitySelectedText.read(source, continuing: withinBudget),
                  span.text.utf16.elementsEqual(selection.text.utf16), span.range == origin.range,
                  sameOrigin() else { return false }
            return withinBudget()
        }
        for candidate in ancestors.dropFirst(origin.index) {
            guard withinBudget() else { return nil }
            var result: String?
            let role = readAttribute(kAXRoleAttribute, of: candidate) as? String
            // Numeric ranges describe the whole text control in editors. A
            // browser's static inline node may describe only a sentence fragment.
            if [kAXTextAreaRole, kAXTextFieldRole].contains(role ?? ""),
               case .selected(let span) = AccessibilitySelectedText.read(candidate, continuing: withinBudget),
               span.text.utf16.elementsEqual(selection.text.utf16),
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

    func read(sourcePID: Int32, mainScreenTop: CGFloat, fallbackPoint: CGPoint,
              hitPoint: CGPoint? = nil, continuing: @escaping () -> Bool = { true }) -> SelectionReadResult {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.4
        var routeDeadline = deadline
        guard let process = SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication),
              process.processIdentifier == sourcePID else { return .unavailable }
        func withinBudget() -> Bool {
            continuing() && ProcessInfo.processInfo.systemUptime < min(deadline, routeDeadline) &&
                process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
        }
        let app = AXUIElementCreateApplication(sourcePID)
        AXUIElementSetMessagingTimeout(app, 0.18)
        // A read-only role query lets Chromium activate native accessibility.
        // Chromium's -accessibilityRole implements this bootstrap; it does not
        // guarantee an Electron app exposes web contents. No AX attributes are set.
        // https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm
        _ = attribute(kAXRoleAttribute, of: app)
        let candidates = SelectionCandidateReader<AXUIElement>(parent: { element in
            AccessibilitySelectionOrigin.parent(of: element, application: app)
        }, isProtected: { isProtected($0, continuing: withinBudget) },
            sameElement: { CFEqual($0, $1) }, canRead: withinBudget, selectedSpan: { element in
                AccessibilitySelectedText.read(element, continuing: withinBudget)
            })

        func selection(from candidate: SelectionCandidate<AXUIElement>, focus: SelectionFocusPath<AXUIElement>?,
                       point: CGPoint?, window: SelectionWindowAnchor? = nil,
                       applicationAnchor: Bool = false) -> TextSelection? {
            let origin = AccessibilitySelectionOrigin(process: process, ancestry: candidate.ancestry,
                sourceIndex: candidate.sourceIndex, focus: focus, hitPoint: point,
                windowAnchor: window, applicationAnchor: applicationAnchor, terminalParent: candidate.terminalParent)
            guard withinBudget(), origin.isCurrent(continuing: withinBudget),
                  case .selected(let current) = AccessibilitySelectedText.read(origin.source, continuing: withinBudget),
                  current.range == candidate.span.range,
                  current.text.utf16.elementsEqual(candidate.span.text.utf16), withinBudget() else { return nil }
            var bounds = CGRect(x: fallbackPoint.x, y: fallbackPoint.y, width: 1, height: 1)
            if let range = current.range {
                var numeric = CFRange(location: range.location, length: range.length)
                if let value = AXValueCreate(.cfRange, &numeric), let rect = boundsForRange(value, in: origin.source) {
                    bounds = FloatingGeometry.appKitRect(fromAccessibility: rect, mainScreenTop: mainScreenTop)
                }
            }
            guard origin.isCurrent(continuing: withinBudget), withinBudget() else { return nil }
            return TextSelection(text: current.text, sourcePID: sourcePID, rangeLocation: current.range?.location ?? -1,
                rangeLength: current.range?.length ?? current.text.utf16.count, bounds: bounds, accessibilityOrigin: origin)
        }

        // A mouse selection can belong to a nonfocused text node. Keep the
        // hit-test inside this application; keyboard reads never reuse a point.
        // Give each route a bounded slice so an unresponsive hit provider
        // cannot consume the entire read before focused/window routes run.
        routeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.8)
        if let hitPoint, withinBudget() {
            let point = CGPoint(x: hitPoint.x, y: mainScreenTop - hitPoint.y)
            if let anchor = AccessibilitySelectionOrigin.hit(in: app, at: point), withinBudget(),
               let candidate = candidates.read(from: anchor),
               let value = selection(from: candidate, focus: nil, point: point) { return .selection(value) }
        }
        for systemWide in [false, true] {
            routeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.6)
            guard withinBudget() else { break }
            switch AccessibilityFocusResolver.resolve(application: app, systemWide: systemWide) {
            case .blocked:
                // A rejected secure/malformed focus cannot be bypassed by a
                // broader focus/window/application selected-text provider.
                return .empty
            case .unavailable: break
            case .path(let focus):
                // A provider can expose a wrapper through app focus but a
                // useful control through system focus. Probe both fixed roots.
                // Forwarded focus nodes are not an arbitrary child-tree crawl.
                for anchor in focus.elements.reversed() {
                    guard withinBudget() else { break }
                    if let candidate = candidates.read(from: anchor),
                       let value = selection(from: candidate, focus: focus, point: nil) { return .selection(value) }
                }
            }
        }
        routeDeadline = deadline
        var inspectedWindows: [AXUIElement] = []
        for attribute in [SelectionWindowAttribute.focused, .main] {
            guard withinBudget() else { break }
            if let window = AccessibilitySelectionOrigin.window(in: app, attribute: attribute),
               !inspectedWindows.contains(where: { CFEqual($0, window) }) {
                inspectedWindows.append(window)
                if let candidate = candidates.read(from: window),
                   let value = selection(from: candidate, focus: nil, point: nil,
                       window: .init(attribute: attribute, element: window)) { return .selection(value) }
            }
        }
        if withinBudget(), let candidate = candidates.read(from: app),
           let value = selection(from: candidate, focus: nil, point: nil, applicationAnchor: true) { return .selection(value) }
        return .empty
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
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
        let protected = AccessibilitySelectedText.isProtected(element)
        return !continuing() || protected
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
    var onToolbarDismiss: (() -> Void)?
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
    private var readNotBefore: TimeInterval = 0
    private var compatibilityRetry: DispatchWorkItem?
    private var compatibilityGestureContext: UInt64?
    private var compatibilityWaitingContext: UInt64?
    private var compatibilityToken: SelectionCompatibilityRequestToken?
    private var copyGestureContext: UInt64?
    private var copyPreparation: SelectionCapturePreparation?
    private var copyPreparationWindow: (context: UInt64, window: AXUIElement)?
    private var actionProofToken: SelectionCompatibilityRequestToken?
    private var copiedSelection: (context: UInt64, selection: TextSelection, target: SelectionCopyTarget)?
    private var copyRevalidation = SelectionCopyRevalidation()
    private let copyUserIntent = SelectionCopyUserIntent()
    private let compatibilityActivator = SelectionCompatibilityActivator()
    private let readQueue = DispatchQueue(label: "org.localaibasetools.capabilities.selection", qos: .userInitiated)
    private var reading = false
    private var dragging = false
    private var selectionMouseDown: (clickCount: Int, time: TimeInterval)?
    private var commandHeld = false
    private var commandSelectionPending = false
    private var keyboardSelectionKey: UInt16?
    private var keyboardSelectionWaitsForKeyUp = false
    private var cancelledSelectionKeyUps: Set<UInt16> = []
    private var trusted = false
    private var context: UInt64 = 0
    private var selectionPoint = NSEvent.mouseLocation
    private var selectionHitPoint: CGPoint?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// A transient AX failure must not permanently remove editing from a
    /// supported field. Recovery reads fresh evidence; it never repeats Copy.
    func recoverAXProof(for original: TextSelection,
                        accept: @escaping @MainActor (TextSelection) -> Bool) async -> TextSelection? {
        guard original.isClipboardOnly else { return original }
        guard let cached = copiedSelection, copyRevalidation.consecutiveTimeouts == 0,
              cached.context == context, cached.selection == original, trusted, !dragging,
              cached.target.process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) else { return nil }
        let capturedContext = context
        let token = SelectionCompatibilityRequestToken()
        compatibilityToken?.invalidate()
        actionProofToken?.invalidate(); actionProofToken = token
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = selectionPoint
        let hitPoint = selectionHitPoint
        return await withCheckedContinuation { continuation in
            readQueue.async { [weak self] in
                let current = { token.isValid && cached.target.process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) }
                var candidate: TextSelection?
                let initialTargetCurrent = cached.target.isCurrent(continuing: current, allowNewlyExposedAnchors: true)
                if initialTargetCurrent,
                   case .selection(let fresh) = AccessibilitySelectionReader().read(sourcePID: original.sourcePID,
                    mainScreenTop: mainTop, fallbackPoint: point, hitPoint: hitPoint, continuing: current),
                   fresh.accessibilityOrigin?.isCurrent(continuing: current) == true {
                    candidate = fresh
                }
                let targetCurrent = initialTargetCurrent && cached.target.isCurrent(continuing: current, allowNewlyExposedAnchors: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { continuation.resume(returning: nil); return }
                    defer { if self.actionProofToken === token { self.actionProofToken = nil } }
                    guard self.context == capturedContext, token.isValid, self.trusted, !self.dragging, targetCurrent,
                          self.copiedSelection?.selection == original,
                          cached.target.process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) else {
                        continuation.resume(returning: nil); return
                    }
                    // A still-current clipboard selection can run a read-only
                    // preview; replacement requires independent matching proof.
                    if let candidate, !candidate.text.utf16.elementsEqual(original.text.utf16) {
                        continuation.resume(returning: nil); return
                    }
                    guard let candidate, let verified = SelectionPromotion.verifiedAXSelection(from: original,
                        candidate: candidate, contextIsCurrent: targetCurrent), accept(verified) else {
                        continuation.resume(returning: original); return
                    }
                    self.copiedSelection = nil
                    continuation.resume(returning: verified)
                }
            }
        }
    }

    /// The Paste button belongs to the physical selection gesture that supplied
    /// the preview. A later gesture may select identical text in the same window.
    func isCurrentMenuPasteSelection(_ selection: TextSelection, context expected: UInt64) -> Bool {
        guard selection.isClipboardOnly, context == expected,
              let cached = copiedSelection, cached.context == expected, cached.selection == selection,
              copyRevalidation.consecutiveTimeouts == 0, trusted, !dragging, !commandHeld,
              cached.target.process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
        else { return false }
        return true
    }

    func menuPasteTarget(for selection: TextSelection) async -> (target: SelectionMenuPasteTarget, context: UInt64)? {
        let expected = context
        guard isCurrentMenuPasteSelection(selection, context: expected), let cached = copiedSelection else { return nil }
        let token = SelectionCompatibilityRequestToken()
        actionProofToken?.invalidate()
        actionProofToken = token
        let target: SelectionMenuPasteTarget? = await withCheckedContinuation { continuation in
            readQueue.async {
                let target = SelectionMenuPasteTarget.capture(from: cached.target) {
                    token.isValid && cached.target.process == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
                }
                continuation.resume(returning: target)
            }
        }
        defer { if actionProofToken === token { actionProofToken = nil } }
        guard token.isValid, isCurrentMenuPasteSelection(selection, context: expected), let target else { return nil }
        return (target, expected)
    }

    func input(for selection: TextSelection) async -> CapabilitySelectionInput {
        guard !selection.isClipboardOnly, SelectionSentenceContext.isSingleWord(selection.text), selection.sourcePID != ownPID,
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
                self.invalidateReadContext()
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
        commandHeld = false
        invalidateReadContext()
        cancelledSelectionKeyUps.removeAll()
    }

    private func installEventMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        // Inspect only event type/key code/modifier flags. Typed text is not collected.
        commandHeld = NSEvent.modifierFlags.contains(.command)
        commandSelectionPending = false
        keyboardSelectionKey = nil
        keyboardSelectionWaitsForKeyUp = false
        cancelledSelectionKeyUps.removeAll()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseDragged,
                                          .leftMouseUp, .rightMouseUp, .keyDown, .keyUp, .flagsChanged]
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
        if SelectionCopyEvents.isInternal(event) { return }
        if event.type == .keyDown, event.modifierFlags.contains(.command), [7, 8].contains(event.keyCode) {
            copyUserIntent.changed()
        }
        // AppKit captures a header drag even after the cursor leaves its panel.
        // Ignore that entire pointer sequence; Esc and app changes still dismiss.
        if isInteractingWithOverlay?() == true,
           [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp].contains(event.type) { return }
        switch event.type {
        case .flagsChanged:
            updateCommandState(event.modifierFlags.contains(.command))
        case .leftMouseDown, .rightMouseDown:
            let point = CapabilityDragPointer.screenPoint(for: event, window: event.window,
                primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
            // Only a local event can belong to our panel. Another app may
            // receive the click at the same coordinates as a covered panel.
            if local, shouldIgnoreOutsideClick?(point) == true { return }
            invalidateReadContext()
            dragging = false
            if !local { updateCommandState(event.modifierFlags.contains(.command)) }
            if event.type == .leftMouseDown && (event.clickCount >= 2 || event.modifierFlags.contains(.shift)) {
                selectionMouseDown = (event.clickCount, event.timestamp)
            }
            onDismiss?()
        case .leftMouseDragged:
            if !local { dragging = true; debounce?.cancel() }
        case .leftMouseUp, .rightMouseUp:
            let selectedByDragging = dragging
            let mouseDown = selectionMouseDown
            let clickCount = max(mouseDown?.clickCount ?? 0, event.clickCount)
            let clickSelection = mouseDown != nil || clickCount >= 2 || event.modifierFlags.contains(.shift)
            selectionMouseDown = nil
            dragging = false
            if local { return }
            // A flagsChanged notification can be missed when switching apps.
            // Use the button event's modifier snapshot for this new gesture.
            updateCommandState(event.modifierFlags.contains(.command))
            selectionPoint = CapabilityDragPointer.screenPoint(for: event, window: event.window,
                primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
            let selecting = event.type == .leftMouseUp &&
                (selectedByDragging || clickSelection)
            selectionHitPoint = selecting ? selectionPoint : nil
            // Keep AX responsive. On editors that require Copy, let the
            // complete click sequence and other selection tools settle first.
            let earliestCopy = clickSelection ? SelectionCapturePreparation.clickCopyDeadline(clickCount: clickCount,
                mouseDown: mouseDown?.time, mouseUp: event.timestamp, doubleClickInterval: NSEvent.doubleClickInterval) : nil
            registerSelectionGesture(selecting, earliestCopyTime: earliestCopy)
            scheduleRead(delay: clickSelection ? 0.12 : 0.14)
        case .keyDown:
            if event.keyCode == 53 { invalidateReadContext(); onDismiss?() }
            else if !local {
                // An older AX query must not publish the selection that existed
                // before this key changed it. Never inspect event.characters.
                let selecting = isKeyboardSelection(event)
                if selecting, event.isARepeat, cancelledSelectionKeyUps.contains(event.keyCode) {
                    invalidateReadContext()
                    return
                }
                if selecting, event.isARepeat, keyboardSelectionKey == event.keyCode {
                    // Repeats can change an arrow selection. Invalidate old
                    // reads while retaining one pending chord, not one Copy
                    // attempt per autorepeat event.
                    invalidateReadContext(preserveKeyboardSelection: true)
                    updateCommandState(event.modifierFlags.contains(.command))
                    keyboardSelectionWaitsForKeyUp = !event.modifierFlags.contains(.command)
                    if !keyboardSelectionWaitsForKeyUp { registerSelectionGesture(true) }
                    return
                }
                invalidateReadContext()
                if selecting {
                    selectionPoint = NSEvent.mouseLocation
                    selectionHitPoint = nil
                    // Latch intent while modifiers still identify the shortcut.
                    // Command can be released before A/arrow keyUp arrives.
                    updateCommandState(event.modifierFlags.contains(.command))
                    cancelledSelectionKeyUps.remove(event.keyCode)
                    keyboardSelectionKey = event.keyCode
                    keyboardSelectionWaitsForKeyUp = !event.modifierFlags.contains(.command)
                    if !keyboardSelectionWaitsForKeyUp { registerSelectionGesture(true) }
                }
            }
        case .keyUp:
            if !local, event.keyCode != 53 {
                if cancelledSelectionKeyUps.remove(event.keyCode) != nil { return }
                if keyboardSelectionKey == event.keyCode {
                    let waitingForKeyUp = keyboardSelectionWaitsForKeyUp
                    keyboardSelectionKey = nil
                    keyboardSelectionWaitsForKeyUp = false
                    // A matching release must not cancel the context rearmed
                    // by an earlier Command release, or dispatch a second Copy.
                    updateCommandState(event.modifierFlags.contains(.command))
                    if waitingForKeyUp { registerSelectionGesture(true) }
                    scheduleRead()
                    return
                }
                invalidateReadContext()
                // Preserve recovery for a missed keyDown, while cancelled
                // latched key releases above can never resurrect an old gesture.
                let selecting = isKeyboardSelection(event)
                if selecting {
                    selectionPoint = NSEvent.mouseLocation
                    selectionHitPoint = nil
                    updateCommandState(event.modifierFlags.contains(.command))
                }
                registerSelectionGesture(selecting)
                scheduleRead()
            }
        default: break
        }
    }

    private func isKeyboardSelection(_ event: NSEvent) -> Bool {
        let shiftSelection = event.modifierFlags.contains(.shift) &&
            [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode)
        let selectAll = event.keyCode == 0 && event.modifierFlags.contains(.command)
        return shiftSelection || selectAll
    }

    private func updateCommandState(_ held: Bool) {
        guard held != commandHeld else { return }
        let deferredSelection = commandSelectionPending
        commandHeld = held
        invalidateReadContext(preserveHitPoint: true, preserveCopiedSelection: true,
                              preserveKeyboardSelection: true)
        if held {
            // Modifier changes are distinct from arbitrary keyDown/keyUp.
            // A fixed Command-V Apply pair must not hide an active result.
            onToolbarDismiss?()
        } else if deferredSelection {
            registerSelectionGesture(true)
            scheduleRead()
        }
    }

    private func registerSelectionGesture(_ selecting: Bool, earliestCopyTime: TimeInterval? = nil) {
        if selecting && commandHeld {
            // Cmd+A / Cmd+Shift+arrow can finish while Command is still held.
            // Rearm only when it is released, keeping the toolbar hidden now.
            commandSelectionPending = true
            return
        }
        commandSelectionPending = false
        if selecting {
            // Commit a new gesture context at release. A read started between
            // mouse/key down and up must not overwrite this gesture's newly
            // armed preparation state when its older callback returns.
            invalidateReadContext(preserveHitPoint: true, preserveKeyboardSelection: true)
            compatibilityGestureContext = context; copyGestureContext = context
            copyPreparation = SelectionCapturePreparation(context: context, earliestCopyTime: earliestCopyTime)
        }
        onSelectionGesture?(selecting)
    }

    /// Consumed by a read once, never rearmed by the polling timer.
    func consumeCopyGesture() -> Bool {
        defer { copyGestureContext = nil }
        return copyGestureContext == context
    }

    func isReadDeferred(at time: TimeInterval) -> Bool { time < readNotBefore }

    private func tick() {
        let permission = AXIsProcessTrusted()
        if permission != trusted {
            trusted = permission
            invalidateReadContext()
            installEventMonitors()
            onPermissionChange?(permission)
            if !permission { onDismiss?() }
        }
        readSelection()
    }

    private func scheduleRead(delay: TimeInterval = 0.14) {
        debounce?.cancel()
        readNotBefore = ProcessInfo.processInfo.systemUptime + delay
        let work = DispatchWorkItem { [weak self] in self?.readSelection() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func invalidateReadContext(preserveHitPoint: Bool = false, preserveCopiedSelection: Bool = false,
                                       preserveKeyboardSelection: Bool = false) {
        context &+= 1
        readNotBefore = 0
        selectionMouseDown = nil
        actionProofToken?.invalidate(); actionProofToken = nil
        copyPreparation = nil
        copyPreparationWindow = nil
        if !preserveKeyboardSelection {
            if let keyboardSelectionKey { cancelledSelectionKeyUps.insert(keyboardSelectionKey) }
            keyboardSelectionKey = nil
            keyboardSelectionWaitsForKeyUp = false
        }
        copyGestureContext = nil
        if preserveCopiedSelection, let cached = copiedSelection {
            copiedSelection = (context, cached.selection, cached.target)
        } else { copiedSelection = nil; copyRevalidation = SelectionCopyRevalidation() }
        if !preserveHitPoint { selectionHitPoint = nil }
        commandSelectionPending = false
        compatibilityGestureContext = nil
        compatibilityWaitingContext = nil
        compatibilityRetry?.cancel(); compatibilityRetry = nil
        compatibilityToken?.invalidate(); compatibilityToken = nil
    }

    private func finishRead(in completedContext: UInt64) {
        reading = false
        // A newer gesture's debounce may have fired while the old AX query
        // owned the serial reader. Service it as soon as that query releases
        // the queue, subject to its own deadline and all normal guards.
        if completedContext != context, timer != nil, copyGestureContext == context {
            readSelection()
        }
    }

    private func readSelection() {
        // The polling timer must not bypass a new gesture's settling delay.
        // Otherwise it can consume the sole Copy opportunity before a native
        // editor has committed a double/triple-click selection.
        guard !isReadDeferred(at: ProcessInfo.processInfo.systemUptime) else { return }
        if compatibilityWaitingContext == context {
            // Do not publish an incomplete focus tree while Electron's delayed
            // mode request is settling. Opt-out stops waiting and future writes.
            if SelectionCompatibilityPreferences.isEnabled { return }
            compatibilityWaitingContext = nil
            compatibilityRetry?.cancel(); compatibilityRetry = nil
            compatibilityToken?.invalidate(); compatibilityToken = nil
        }
        guard trusted, actionProofToken == nil, !reading, !dragging, !commandHeld, isInteractingWithOverlay?() != true,
              let source = SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication),
              source.processIdentifier != ownPID else { return }
        let pid = source.processIdentifier
        reading = true
        let capturedContext = context
        let explicitGesture = compatibilityGestureContext == capturedContext
        compatibilityGestureContext = nil
        let copyGesture = consumeCopyGesture()
        var preparation = copyPreparation
        var preparationWindow = copyPreparationWindow?.context == capturedContext ? copyPreparationWindow?.window : nil
        let cachedCopy = copiedSelection?.context == capturedContext ? copiedSelection : nil
        let userIntent = copyUserIntent
        let token = SelectionCompatibilityRequestToken()
        compatibilityToken = token
        let point = selectionPoint
        let hitPoint = selectionHitPoint
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let activator = compatibilityActivator
        readQueue.async { [weak self] in
            let outcome = activator.prepare(source: source, explicitGesture: explicitGesture) {
                token.isValid && source == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
            }
            let settlementDelay = activator.delayBeforeRefresh(source: source)
            let current = { token.isValid && source == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) }
            var capturedCopy: (TextSelection, SelectionCopyTarget)?
            var cachedValidity: SelectionCopyValidity?
            var preparationRetry: TimeInterval?
            var result = SelectionReadResult.unavailable
            if !outcome.needsDelayedRead {
                if let cachedCopy {
                    let validity = cachedCopy.target.validity(continuing: current, allowNewlyExposedAnchors: true)
                    cachedValidity = validity
                    result = validity == .current ? .selection(cachedCopy.selection) : .empty
                } else {
                    result = AccessibilitySelectionReader().read(sourcePID: pid, mainScreenTop: mainTop, fallbackPoint: point,
                        hitPoint: hitPoint, continuing: current)
                    let hasAXSelection: Bool
                    if case .selection = result { hasAXSelection = true } else { hasAXSelection = false }
                    if hasAXSelection { preparation?.cancel(context: capturedContext) }
                    if copyGesture, !hasAXSelection, current(),
                       preparation?.beginAttempt(context: capturedContext, now: ProcessInfo.processInfo.systemUptime) == true {
                        var dispatched = false
                        let currentWindow = AccessibilitySelectionOrigin.window(in: AXUIElementCreateApplication(pid), attribute: .focused)
                        if preparationWindow == nil { preparationWindow = currentWindow }
                        let sameWindow = preparationWindow.flatMap { expected in currentWindow.map { CFEqual(expected, $0) } } ?? false
                        if !sameWindow, preparationWindow != nil { preparation?.cancel(context: capturedContext) }
                        if sameWindow, let currentWindow, let target = SelectionCopyTarget.capture(process: source,
                            hitPoint: hitPoint.map { CGPoint(x: $0.x, y: mainTop - $0.y) }, continuing: current),
                           CFEqual(target.window, currentWindow),
                           let copyAction = SelectionCopyAction.resolve(application: target.application, pid: pid, continuing: current) {
                            let transaction = SelectionClipboardTransaction(pasteboard: SystemSelectionClipboard())
                            if let text = transaction.capture(prepareCopy: {
                                target.isCurrent(continuing: current) && copyAction.isAvailable()
                            }, willCopy: { dispatched = true }, copy: { copyAction.perform() }, canCapture: current,
                               userCopyGeneration: { userIntent.value }) {
                                let validity = target.validity(continuing: current, allowNewlyExposedAnchors: true)
                                if validity != .invalid {
                                    var selection = TextSelection(text: text, sourcePID: pid, rangeLocation: -1,
                                        rangeLength: text.utf16.count, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1))
                                    selection.isClipboardOnly = true
                                    capturedCopy = (selection, target)
                                    cachedValidity = validity
                                    result = validity == .current ? .selection(selection) : .empty
                                }
                            }
                        }
                        if dispatched { preparation?.copyAttempted(context: capturedContext) }
                        else if current() {
                            preparationRetry = preparation?.preparationFailed(context: capturedContext,
                                now: ProcessInfo.processInfo.systemUptime)
                        }
                    } else if copyGesture, !hasAXSelection, current() {
                        // Bind the deferred Copy to the window seen on the
                        // first AX read, before waiting for another click.
                        if preparationWindow == nil {
                            preparationWindow = AccessibilitySelectionOrigin.window(in: AXUIElementCreateApplication(pid), attribute: .focused)
                        }
                        if preparationWindow != nil {
                            preparationRetry = preparation?.delayBeforeAttempt(context: capturedContext,
                                now: ProcessInfo.processInfo.systemUptime)
                        }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishRead(in: capturedContext)
                guard self.context == capturedContext, token.isValid, !self.commandHeld,
                      self.isInteractingWithOverlay?() != true,
                      source == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication) else { return }
                if outcome.needsDelayedRead {
                    if copyGesture { self.copyGestureContext = capturedContext }
                    let settlement = SelectionCompatibilitySettlement(context: capturedContext, source: source)
                    self.compatibilityWaitingContext = capturedContext
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        guard settlement.accepts(context: self.context,
                            source: SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication),
                            enabled: SelectionCompatibilityPreferences.isEnabled, running: self.timer != nil,
                            trusted: self.trusted && AXIsProcessTrusted(), dragging: self.dragging, tokenValid: token.isValid) else {
                            if self.compatibilityWaitingContext == capturedContext { self.compatibilityWaitingContext = nil }
                            return
                        }
                        self.compatibilityRetry = nil
                        self.reading = true
                        self.readQueue.async { [weak self] in
                            _ = activator.refreshAfterSettlement(source: source) {
                                token.isValid && source == SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication)
                            }
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.finishRead(in: capturedContext)
                                guard settlement.accepts(context: self.context,
                                    source: SelectionCompatibilityProcess(NSWorkspace.shared.frontmostApplication),
                                    enabled: SelectionCompatibilityPreferences.isEnabled, running: self.timer != nil,
                                    trusted: self.trusted && AXIsProcessTrusted(), dragging: self.dragging, tokenValid: token.isValid) else { return }
                                self.compatibilityWaitingContext = nil
                                self.readSelection()
                            }
                        }
                    }
                    self.compatibilityRetry = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settlementDelay ?? 2.2), execute: retry)
                    return
                }
                if let capturedCopy {
                    self.copiedSelection = (capturedContext, capturedCopy.0, capturedCopy.1)
                    self.copyRevalidation = SelectionCopyRevalidation()
                }
                if let validity = cachedValidity {
                    if self.copyRevalidation.shouldRetry(after: validity) {
                        self.scheduleRead(delay: 0.12)
                    } else if validity != .current {
                        self.copiedSelection = nil
                    }
                }
                self.copyPreparation = preparation
                if let preparationWindow { self.copyPreparationWindow = (capturedContext, preparationWindow) }
                if let preparationRetry {
                    self.copyGestureContext = capturedContext
                    self.scheduleRead(delay: preparationRetry)
                }
                self.onRead?(result)
            }
        }
    }
}
