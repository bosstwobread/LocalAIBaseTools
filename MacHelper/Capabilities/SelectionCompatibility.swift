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

/// AX may return a fresh wrapper for the same window on each read. Compare
/// the underlying elements, retaining them so reused addresses cannot alias.
struct SelectionWindowIdentity: Hashable, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

private struct SelectionCompatibilityTarget: Hashable {
    let source: SelectionCompatibilityProcess
    let window: SelectionWindowIdentity?
}

private struct SelectionCompatibilityActivationPolicy {
    private enum ProbeAttempt { case first, retryAvailable, last }
    private var attempted: [SelectionCompatibilityTarget: ProbeAttempt] = [:]
    private var unsupported: Set<SelectionCompatibilityProcess> = []
    private var pendingRefresh: [SelectionCompatibilityTarget: TimeInterval] = [:]

    mutating func begin(_ target: SelectionCompatibilityTarget) -> Bool {
        guard target.source.processIdentifier > 1, !target.source.bundleIdentifier.isEmpty,
              !unsupported.contains(target.source) else { return false }
        switch attempted[target] {
        case nil where attempted.count < 256:
            attempted[target] = .first
        case .retryAvailable:
            attempted[target] = .last
        default:
            return false
        }
        return true
    }

    /// A stale check before a write hasn't used this window's request.
    mutating func release(_ target: SelectionCompatibilityTarget) {
        if attempted[target] == .last {
            attempted[target] = .retryAvailable
        } else {
            attempted.removeValue(forKey: target)
        }
    }

    /// A timeout does not establish lack of support. Allow one more probe on a
    /// later selection gesture without ever repeating a dispatched write.
    mutating func inconclusive(_ target: SelectionCompatibilityTarget) {
        if pendingRefresh[target] != nil {
            if attempted[target] == .first {
                attempted[target] = .last
            } else {
                finishRefresh(for: target)
            }
        } else if attempted[target] == .first {
            attempted[target] = .retryAvailable
        }
    }

    mutating func markUnsupported(_ source: SelectionCompatibilityProcess) {
        unsupported.insert(source)
        pendingRefresh = pendingRefresh.filter { $0.key.source != source }
    }

    mutating func awaitRefresh(for target: SelectionCompatibilityTarget, readyAt: TimeInterval) {
        pendingRefresh[target] = readyAt
        deferOtherWindows(of: target.source, until: readyAt)
    }

    /// Electron debounces writes on the process, even for different windows.
    mutating func deferOtherWindows(of source: SelectionCompatibilityProcess, until readyAt: TimeInterval) {
        for target in pendingRefresh.keys where target.source == source {
            pendingRefresh[target] = max(pendingRefresh[target] ?? readyAt, readyAt)
        }
    }

    func remainingDelay(for target: SelectionCompatibilityTarget, now: TimeInterval) -> TimeInterval? {
        pendingRefresh[target].map { max(0, $0 - now) }
    }

    mutating func finishRefresh(for target: SelectionCompatibilityTarget) {
        pendingRefresh.removeValue(forKey: target)
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
    func isAdvertised(source: SelectionCompatibilityProcess) -> Bool?
    func isSettable(source: SelectionCompatibilityProcess) -> Bool?
    func isEnabled(source: SelectionCompatibilityProcess) -> Bool?
    func request(source: SelectionCompatibilityProcess) -> Bool
}

private struct SystemSelectionCompatibilityAccessibility: SelectionCompatibilityAccessibility {
    private func application(_ source: SelectionCompatibilityProcess) -> AXUIElement {
        let application = AXUIElementCreateApplication(source.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        return application
    }
    func isAdvertised(source: SelectionCompatibilityProcess) -> Bool? {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(application(source), &names) == .success,
              let attributes = names as? [String] else { return nil }
        return attributes.contains("AXManualAccessibility")
    }
    func isSettable(source: SelectionCompatibilityProcess) -> Bool? {
        var writable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(application(source), "AXManualAccessibility" as CFString, &writable)
        if result == .attributeUnsupported { return false }
        return result == .success ? writable.boolValue : nil
    }
    func isEnabled(source: SelectionCompatibilityProcess) -> Bool? {
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(source), "AXManualAccessibility" as CFString, &current) == .success else { return nil }
        return current as? Bool
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

    func prepare(source: SelectionCompatibilityProcess, window: SelectionWindowIdentity? = nil,
                 explicitGesture: Bool, selectionReadFailed: Bool = false, currentSource: () -> Bool) -> SelectionCompatibilityActivationOutcome {
        lock.lock(); defer { lock.unlock() }
        guard explicitGesture, window == nil || selectionReadFailed, enabled(), trusted(), currentSource() else { return .notRequested }
        let target = SelectionCompatibilityTarget(source: source, window: window)
        // A later deliberate gesture may resume the one pending refresh. It
        // must not repeat the first request or restart Electron's debounce.
        if policy.remainingDelay(for: target, now: now()) != nil { return .pendingSettlement }
        guard policy.begin(target) else { return .notRequested }
        let advertised = accessibility.isAdvertised(source: source)
        guard enabled(), trusted(), currentSource() else {
            policy.release(target); return .stale
        }
        if let stopped = check(advertised, for: target, unsupported: .unsupported) { return stopped }
        let settable = accessibility.isSettable(source: source)
        guard enabled(), trusted(), currentSource() else {
            policy.release(target); return .stale
        }
        if let stopped = check(settable, for: target, unsupported: .notSettable) { return stopped }
        let alreadyEnabled = accessibility.isEnabled(source: source)
        guard enabled(), trusted(), currentSource() else {
            policy.release(target); return .stale
        }
        // A verified editor window can miss the support notification even if
        // complete mode is already on. A failed read permits one rebroadcast.
        guard let alreadyEnabled else { policy.inconclusive(target); return .failed }
        if alreadyEnabled && window == nil { return .alreadyEnabled }
        guard accessibility.request(source: source) else { return .failed }
        policy.awaitRefresh(for: target, readyAt: now() + 2.2)
        return .requested
    }

    func delayBeforeRefresh(source: SelectionCompatibilityProcess, window: SelectionWindowIdentity? = nil) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return policy.remainingDelay(for: .init(source: source, window: window), now: now())
    }

    /// Electron emits its support-change event before its delayed mode update.
    /// One settled second true refreshes that event. Never gate this on the
    /// exact-mode getter, which may remain false when additional flags are set.
    func refreshAfterSettlement(source: SelectionCompatibilityProcess, window: SelectionWindowIdentity? = nil,
                                currentSource: () -> Bool) -> SelectionCompatibilityActivationOutcome {
        lock.lock(); defer { lock.unlock() }
        let target = SelectionCompatibilityTarget(source: source, window: window)
        guard let delay = policy.remainingDelay(for: target, now: now()) else { return .notRequested }
        guard enabled(), trusted(), currentSource() else { return .stale }
        guard delay <= 0 else { return .pendingSettlement }
        let advertised = accessibility.isAdvertised(source: source)
        guard enabled(), trusted(), currentSource() else { return .stale }
        if let stopped = check(advertised, for: target, unsupported: .unsupported) { return stopped }
        let settable = accessibility.isSettable(source: source)
        guard enabled(), trusted(), currentSource() else { return .stale }
        if let stopped = check(settable, for: target, unsupported: .notSettable) { return stopped }
        // Consume before the write, so failure or a subsequent context change
        // cannot cause a third request. Stale pre-write checks leave it pending
        // for a future explicit gesture, never for an ordinary polling timer.
        policy.finishRefresh(for: target)
        guard accessibility.request(source: source) else { return .failed }
        policy.deferOtherWindows(of: source, until: now() + 2.2)
        return .refreshed
    }

    private func check(_ supported: Bool?, for target: SelectionCompatibilityTarget,
                       unsupported: SelectionCompatibilityActivationOutcome) -> SelectionCompatibilityActivationOutcome? {
        guard let supported else {
            policy.inconclusive(target)
            return .failed
        }
        guard supported else {
            policy.markUnsupported(target.source)
            return unsupported
        }
        return nil
    }
}
