import AppKit
import ApplicationServices
import Foundation

/// This app-wide assistive mode is opt-in because Electron apps can change
/// their own interface when they detect a complete accessibility client.
public enum SelectionCompatibilityPreferences {
    static let key = "MacHelper.electronAccessibilityCompatibility"
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
}

struct SelectionCompatibilityProcess: Hashable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let launchDate: Date?

    init(processIdentifier: Int32, bundleIdentifier: String, launchDate: Date?) {
        self.processIdentifier = processIdentifier; self.bundleIdentifier = bundleIdentifier; self.launchDate = launchDate
    }

    init?(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier > 1, let bundle = application.bundleIdentifier,
              !bundle.isEmpty else { return nil }
        self.init(processIdentifier: application.processIdentifier, bundleIdentifier: bundle, launchDate: application.launchDate)
    }
}

struct SelectionCompatibilityActivationPolicy {
    private var attempted: Set<SelectionCompatibilityProcess> = []
    private var pendingRefresh: [SelectionCompatibilityProcess: TimeInterval] = [:]

    mutating func begin(source: SelectionCompatibilityProcess, explicitGesture: Bool, enabled: Bool,
                        trusted: Bool, currentSource: Bool) -> Bool {
        guard explicitGesture, enabled, trusted, currentSource, source.processIdentifier > 1,
              !source.bundleIdentifier.isEmpty, attempted.count < 256, !attempted.contains(source) else { return false }
        attempted.insert(source)
        return true
    }

    /// A stale context before the write made no request. Allow a later explicit
    /// gesture to try again; actual attempts and known unsupported cases stay final.
    mutating func releaseStaleReservation(for source: SelectionCompatibilityProcess) {
        attempted.remove(source)
    }

    mutating func awaitRefresh(for source: SelectionCompatibilityProcess, readyAt: TimeInterval) {
        pendingRefresh[source] = readyAt
    }

    func remainingDelay(for source: SelectionCompatibilityProcess, now: TimeInterval) -> TimeInterval? {
        pendingRefresh[source].map { max(0, $0 - now) }
    }

    mutating func finishRefresh(for source: SelectionCompatibilityProcess) {
        pendingRefresh.removeValue(forKey: source)
    }
}

enum SelectionCompatibilityActivationOutcome: String {
    case notRequested, stale, unsupported, notSettable, alreadyEnabled, requested, pendingSettlement, refreshed, failed
    var needsDelayedRead: Bool { self == .requested || self == .pendingSettlement }
}

final class SelectionCompatibilityRequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

struct SelectionCompatibilitySettlement {
    let context: UInt64
    let source: SelectionCompatibilityProcess

    func accepts(context: UInt64, source: SelectionCompatibilityProcess?, enabled: Bool,
                 running: Bool, trusted: Bool, dragging: Bool, tokenValid: Bool) -> Bool {
        self.context == context && self.source == source && enabled && running && trusted && !dragging && tokenValid
    }
}

protocol SelectionCompatibilityAccessibility {
    func isAdvertised(source: SelectionCompatibilityProcess) -> Bool
    func isSettable(source: SelectionCompatibilityProcess) -> Bool
    func isEnabled(source: SelectionCompatibilityProcess) -> Bool
    func request(source: SelectionCompatibilityProcess) -> Bool
}

private struct SystemSelectionCompatibilityAccessibility: SelectionCompatibilityAccessibility {
    private func application(_ source: SelectionCompatibilityProcess) -> AXUIElement {
        let application = AXUIElementCreateApplication(source.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        return application
    }
    func isAdvertised(source: SelectionCompatibilityProcess) -> Bool {
        var names: CFArray?
        return AXUIElementCopyAttributeNames(application(source), &names) == .success &&
            (names as? [String])?.contains("AXManualAccessibility") == true
    }
    func isSettable(source: SelectionCompatibilityProcess) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(application(source), "AXManualAccessibility" as CFString, &writable) == .success && writable.boolValue
    }
    func isEnabled(source: SelectionCompatibilityProcess) -> Bool {
        var current: CFTypeRef?
        return AXUIElementCopyAttributeValue(application(source), "AXManualAccessibility" as CFString, &current) == .success && current as? Bool == true
    }
    func request(source: SelectionCompatibilityProcess) -> Bool {
        AXUIElementSetAttributeValue(application(source), "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }
}

/// Runs on the serial selection-read queue after an explicit selection gesture.
/// It sets only Electron's documented mode switch, never EnhancedUserInterface,
/// focus, selection, values, pasteboard, or a document editing action.
final class SelectionCompatibilityActivator: @unchecked Sendable {
    // All mutable activation state and provider access are serialized here;
    // production also invokes this object only from the selection-read queue.
    private let lock = NSLock()
    private var policy = SelectionCompatibilityActivationPolicy()
    private let enabled: () -> Bool
    private let trusted: () -> Bool
    private let now: () -> TimeInterval
    private let accessibility: SelectionCompatibilityAccessibility

    init(enabled: @escaping () -> Bool = { SelectionCompatibilityPreferences.isEnabled },
         trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         accessibility: SelectionCompatibilityAccessibility? = nil) {
        self.enabled = enabled; self.trusted = trusted; self.now = now
        self.accessibility = accessibility ?? SystemSelectionCompatibilityAccessibility()
    }

    func prepare(source: SelectionCompatibilityProcess, explicitGesture: Bool,
                 currentSource: () -> Bool) -> SelectionCompatibilityActivationOutcome {
        lock.lock(); defer { lock.unlock() }
        guard explicitGesture, enabled(), trusted(), currentSource() else { return .notRequested }
        // A later deliberate gesture may resume the one pending refresh. It
        // must not repeat the first request or restart Electron's debounce.
        if policy.remainingDelay(for: source, now: now()) != nil { return .pendingSettlement }
        guard policy.begin(source: source, explicitGesture: explicitGesture, enabled: enabled(),
                           trusted: trusted(), currentSource: currentSource()) else { return .notRequested }
        let advertised = accessibility.isAdvertised(source: source)
        guard enabled(), trusted(), currentSource() else {
            policy.releaseStaleReservation(for: source); return .stale
        }
        guard advertised else { return .unsupported }
        let settable = accessibility.isSettable(source: source)
        guard enabled(), trusted(), currentSource() else {
            policy.releaseStaleReservation(for: source); return .stale
        }
        guard settable else { return .notSettable }
        let alreadyEnabled = accessibility.isEnabled(source: source)
        guard enabled(), trusted(), currentSource() else {
            policy.releaseStaleReservation(for: source); return .stale
        }
        if alreadyEnabled { return .alreadyEnabled }
        guard accessibility.request(source: source) else { return .failed }
        policy.awaitRefresh(for: source, readyAt: now() + 2.2)
        return .requested
    }

    func delayBeforeRefresh(source: SelectionCompatibilityProcess) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return policy.remainingDelay(for: source, now: now())
    }

    /// Electron emits its support-change event before its delayed mode update.
    /// One settled second true refreshes that event. Never gate this on the
    /// exact-mode getter, which may remain false when additional flags are set.
    func refreshAfterSettlement(source: SelectionCompatibilityProcess,
                                currentSource: () -> Bool) -> SelectionCompatibilityActivationOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let delay = policy.remainingDelay(for: source, now: now()) else { return .notRequested }
        guard enabled(), trusted(), currentSource() else { return .stale }
        guard delay <= 0 else { return .pendingSettlement }
        let advertised = accessibility.isAdvertised(source: source)
        guard enabled(), trusted(), currentSource() else { return .stale }
        guard advertised else {
            policy.finishRefresh(for: source); return .unsupported
        }
        let settable = accessibility.isSettable(source: source)
        guard enabled(), trusted(), currentSource() else { return .stale }
        guard settable else {
            policy.finishRefresh(for: source); return .notSettable
        }
        // Consume before the write, so failure or a subsequent context change
        // cannot cause a third request. Stale pre-write checks leave it pending
        // for a future explicit gesture, never for an ordinary polling timer.
        policy.finishRefresh(for: source)
        return accessibility.request(source: source) ? .refreshed : .failed
    }
}
