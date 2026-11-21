import ApplicationServices
import Foundation
import XCTest
@testable import MacHelperCapabilities

final class SelectionCompatibilityTests: XCTestCase {
    private let source = SelectionCompatibilityProcess(processIdentifier: 42, bundleIdentifier: "org.example.editor", launchDate: Date(timeIntervalSince1970: 100))

    func testPreferenceDefaultsOffInFreshDomain() throws {
        let name = "SelectionCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(SelectionCompatibilityPreferences.isEnabled(in: defaults))
        defaults.set(true, forKey: SelectionCompatibilityPreferences.key)
        XCTAssertTrue(SelectionCompatibilityPreferences.isEnabled(in: defaults))
    }

    func testOffOrdinaryPollUntrustedAndStaleNeverTouchProvider() {
        for (enabled, gesture, trusted, current) in [(false, true, true, true), (true, false, true, true),
                                                    (true, true, false, true), (true, true, true, false)] {
            let access = MockAccessibility()
            let activator = SelectionCompatibilityActivator(enabled: { enabled }, trusted: { trusted }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: gesture, currentSource: { current }), .notRequested)
            XCTAssertEqual(access.calls, [])
        }
    }

    func testBoundedTwoPhaseHandshakePerRunningIdentity() {
        let access = MockAccessibility()
        var now: TimeInterval = 0
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .requested)
        XCTAssertEqual(access.calls, ["advertised", "settable", "enabled", "request"])
        XCTAssertEqual(activator.delayBeforeRefresh(source: source), 2.2)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .pendingSettlement)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: false, currentSource: { true }), .notRequested)
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .pendingSettlement)
        XCTAssertEqual(access.calls.count, 4)
        now = 2.2
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .refreshed)
        XCTAssertEqual(access.calls, ["advertised", "settable", "enabled", "request", "advertised", "settable", "request"])
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .notRequested)
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .notRequested)
        let relaunched = SelectionCompatibilityProcess(processIdentifier: source.processIdentifier,
            bundleIdentifier: source.bundleIdentifier, launchDate: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(activator.prepare(source: relaunched, explicitGesture: true, currentSource: { true }), .requested)
        XCTAssertEqual(access.calls.count, 11)
    }

    // Synthetic AX elements give these tests distinct/equivalent CF identities
    // without inspecting a running app or requiring Accessibility permission.
    func testNewEditorWindowCanRecoverEvenAfterTheProcessHasEnabledAccessibility() {
        let firstWindow = SelectionWindowIdentity(AXUIElementCreateApplication(42))
        let sameWindow = SelectionWindowIdentity(AXUIElementCreateApplication(42))
        let secondWindow = SelectionWindowIdentity(AXUIElementCreateApplication(43))
        XCTAssertEqual(Set([firstWindow, sameWindow, secondWindow]).count, 2)
        let access = MockAccessibility()
        var now: TimeInterval = 0
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
        func prepare(_ window: SelectionWindowIdentity, failed: Bool) -> SelectionCompatibilityActivationOutcome {
            activator.prepare(source: source, window: window, explicitGesture: true,
                              selectionReadFailed: failed, currentSource: { true })
        }

        XCTAssertEqual(prepare(firstWindow, failed: true), .requested)
        now = 3
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, window: sameWindow, currentSource: { true }), .refreshed)
        access.enabled = true
        XCTAssertEqual(prepare(secondWindow, failed: false), .notRequested)
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 2)
        XCTAssertEqual(prepare(secondWindow, failed: true), .requested)
        XCTAssertEqual(prepare(secondWindow, failed: true), .pendingSettlement)
        now = 6
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, window: secondWindow, currentSource: { true }), .refreshed)
        XCTAssertEqual(prepare(secondWindow, failed: true), .notRequested)
        XCTAssertEqual(prepare(sameWindow, failed: true), .notRequested)
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 4)
    }

    func testWindowSwitchDoesNotRefreshStaleWindowOrRestartTheProcessDebounceTooSoon() {
        let first = SelectionWindowIdentity(AXUIElementCreateApplication(42))
        let second = SelectionWindowIdentity(AXUIElementCreateApplication(43))
        var focused = first
        let access = MockAccessibility()
        var now: TimeInterval = 0
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
        func prepare(_ window: SelectionWindowIdentity) -> SelectionCompatibilityActivationOutcome {
            activator.prepare(source: source, window: window, explicitGesture: true,
                              selectionReadFailed: true, currentSource: { focused == window })
        }
        func refresh(_ window: SelectionWindowIdentity) -> SelectionCompatibilityActivationOutcome {
            activator.refreshAfterSettlement(source: source, window: window, currentSource: { focused == window })
        }

        XCTAssertEqual(prepare(first), .requested)
        now = 1
        focused = second
        XCTAssertEqual(prepare(second), .requested)
        now = 2.3
        XCTAssertEqual(refresh(first), .stale)
        focused = first
        XCTAssertEqual(prepare(first), .pendingSettlement)
        XCTAssertEqual(refresh(first), .pendingSettlement)
        now = 3.3
        XCTAssertEqual(refresh(first), .refreshed)
        focused = second
        XCTAssertEqual(refresh(second), .pendingSettlement)
        now = 6
        XCTAssertEqual(refresh(second), .refreshed)
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 4)
    }

    func testUnsupportedApplicationIsNotReprobedForEveryWindow() {
        for advertised in [true, false] {
            let access = MockAccessibility()
            access.advertised = advertised
            access.settable = false
            let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, accessibility: access)
            func prepare(_ id: Int32) -> SelectionCompatibilityActivationOutcome {
                activator.prepare(source: source, window: .init(AXUIElementCreateApplication(id)),
                                  explicitGesture: true, selectionReadFailed: true, currentSource: { true })
            }
            XCTAssertEqual(prepare(42), advertised ? .notSettable : .unsupported)
            let calls = access.calls
            XCTAssertEqual(prepare(43), .notRequested)
            XCTAssertEqual(access.calls, calls)
        }
    }

    func testTransientProbeIsBoundedToOneMoreGestureAndNeverDisablesOtherWindows() {
        let access = MockAccessibility()
        let first = SelectionWindowIdentity(AXUIElementCreateApplication(42))
        let second = SelectionWindowIdentity(AXUIElementCreateApplication(43))
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, accessibility: access)
        func prepare(_ window: SelectionWindowIdentity, gesture: Bool = true) -> SelectionCompatibilityActivationOutcome {
            activator.prepare(source: source, window: window, explicitGesture: gesture,
                              selectionReadFailed: true, currentSource: { true })
        }
        access.advertised = nil
        XCTAssertEqual(prepare(first), .failed)
        XCTAssertEqual(prepare(first, gesture: false), .notRequested)
        XCTAssertEqual(prepare(first), .failed)
        XCTAssertEqual(prepare(first), .notRequested)
        XCTAssertEqual(access.calls, ["advertised", "advertised"])
        access.advertised = true
        XCTAssertEqual(prepare(second), .requested)
    }

    func testTransientProbeAtSettlementDoesNotRepeatInitialWrite() {
        let access = MockAccessibility()
        var now: TimeInterval = 0
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .requested)
        now = 3
        access.settable = nil
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .failed)
        access.settable = true
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .pendingSettlement)
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .refreshed)
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 2)
    }

    func testUnsupportedNotSettableAlreadyEnabledAndFailureDoNotRetry() {
        for outcome in [SelectionCompatibilityActivationOutcome.unsupported, .notSettable, .alreadyEnabled, .failed] {
            let access = MockAccessibility()
            access.advertised = outcome != .unsupported
            access.settable = outcome != .notSettable
            access.enabled = outcome == .alreadyEnabled
            access.accepted = outcome != .failed
            let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), outcome)
            let count = access.calls.count
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .notRequested)
            XCTAssertEqual(access.calls.count, count)
            XCTAssertEqual(access.calls.contains("request"), outcome == .failed)
            XCTAssertFalse(outcome.needsDelayedRead)
        }
        XCTAssertTrue(SelectionCompatibilityActivationOutcome.requested.needsDelayedRead)
    }

    func testOptOutLostTrustAndChangedSourceBeforeWriteBlockRequest() {
        for invalidation in ["enabled", "trusted", "source"] {
            let access = MockAccessibility()
            var enabled = true, trusted = true, current = true
            access.beforeEnabled = {
                if invalidation == "enabled" { enabled = false }
                if invalidation == "trusted" { trusted = false }
                if invalidation == "source" { current = false }
            }
            let activator = SelectionCompatibilityActivator(enabled: { enabled }, trusted: { trusted }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .stale)
            XCTAssertFalse(access.calls.contains("request"))
            enabled = true; trusted = true; current = true; access.beforeEnabled = nil
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .requested,
                           "A cancelled pre-write context must not permanently consume this process's request")
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 1)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .pendingSettlement)
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 1)
        }
    }

    func testSettledRefreshEmitsEnabledSupportWithoutRequiringUnreliableGetter() {
        let access = MockAccessibility()
        var now: TimeInterval = 0, actualCompleteMode = false
        var supportNotifications: [Bool] = []
        access.onRequest = { supportNotifications.append(actualCompleteMode) }
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .requested)
        XCTAssertEqual(supportNotifications, [false], "Electron notifies before its delayed complete-mode update")
        now = 2.2; actualCompleteMode = true
        XCTAssertEqual(supportNotifications, [false], "The delayed mode update supplies no notification itself")
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .refreshed)
        XCTAssertEqual(supportNotifications, [false, true])
        XCTAssertEqual(access.calls.filter { $0 == "enabled" }.count, 1, "Exact-mode getter is not a readiness proof for the second phase")
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 2)
    }

    func testCancelledPendingPhaseResumesOnlyNewGestureWithoutRestartingInitialDelay() {
        let access = MockAccessibility()
        var now: TimeInterval = 0, current = true
        let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .requested)
        now = 1; current = false
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { current }), .stale)
        now = 5; current = true
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: false, currentSource: { current }), .notRequested)
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 1)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .pendingSettlement)
        XCTAssertEqual(activator.delayBeforeRefresh(source: source), 0)
        XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { current }), .refreshed)
        XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 2)
        XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .notRequested)
    }

    func testRefreshRechecksOptInTrustAndSourceAfterProviderReadsAndStaysPendingOnStale() {
        for invalidation in ["enabled", "trusted", "source"] {
            let access = MockAccessibility()
            var now: TimeInterval = 0, enabled = true, trusted = true, current = true
            let activator = SelectionCompatibilityActivator(enabled: { enabled }, trusted: { trusted }, now: { now }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .requested)
            now = 2.2
            access.beforeSettable = {
                if invalidation == "enabled" { enabled = false }
                if invalidation == "trusted" { trusted = false }
                if invalidation == "source" { current = false }
            }
            XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { current }), .stale)
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 1)
            enabled = true; trusted = true; current = true; access.beforeSettable = nil
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: false, currentSource: { current }), .notRequested)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .pendingSettlement)
            XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { current }), .refreshed)
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 2)
        }
    }

    func testSecondPhaseUnsupportedNotSettableAndFailedWriteAreTerminal() {
        for expected in [SelectionCompatibilityActivationOutcome.unsupported, .notSettable, .failed] {
            let access = MockAccessibility()
            var now: TimeInterval = 0
            let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .requested)
            now = 2.2
            access.advertised = expected != .unsupported; access.settable = expected != .notSettable; access.accepted = expected != .failed
            XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), expected)
            let count = access.calls.count
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { true }), .notRequested)
            XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { true }), .notRequested)
            XCTAssertEqual(access.calls.count, count)
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, expected == .failed ? 2 : 1)
        }
    }

    func testStaleFalseProviderProbeNeverConsumesInitialOrPendingPhase() {
        for stage in ["advertised", "settable", "enabled"] {
            let access = MockAccessibility()
            var current = true
            if stage == "advertised" { access.advertised = false; access.beforeAdvertised = { current = false } }
            if stage == "settable" { access.settable = false; access.beforeSettable = { current = false } }
            if stage == "enabled" { access.enabled = true; access.beforeEnabled = { current = false } }
            let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .stale)
            XCTAssertFalse(access.calls.contains("request"))
            current = true; access.advertised = true; access.settable = true; access.enabled = false
            access.beforeAdvertised = nil; access.beforeSettable = nil; access.beforeEnabled = nil
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .requested)
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 1)
        }
        for stage in ["advertised", "settable"] {
            let access = MockAccessibility()
            var current = true, now: TimeInterval = 0
            let activator = SelectionCompatibilityActivator(enabled: { true }, trusted: { true }, now: { now }, accessibility: access)
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .requested)
            now = 2.2
            if stage == "advertised" { access.advertised = false; access.beforeAdvertised = { current = false } }
            else { access.settable = false; access.beforeSettable = { current = false } }
            XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { current }), .stale)
            current = true; access.advertised = true; access.settable = true
            access.beforeAdvertised = nil; access.beforeSettable = nil
            XCTAssertEqual(activator.prepare(source: source, explicitGesture: true, currentSource: { current }), .pendingSettlement)
            XCTAssertEqual(activator.refreshAfterSettlement(source: source, currentSource: { current }), .refreshed)
            XCTAssertEqual(access.calls.filter { $0 == "request" }.count, 2)
        }
    }

    func testDelayedReadRejectsAnyChangedContextSourcePermissionOrLifecycle() {
        let gate = SelectionCompatibilitySettlement(context: 4, source: source)
        func accepts(context: UInt64 = 4, source: SelectionCompatibilityProcess? = nil,
                     enabled: Bool = true, running: Bool = true, trusted: Bool = true,
                     dragging: Bool = false, tokenValid: Bool = true) -> Bool {
            gate.accepts(context: context, source: source ?? self.source, enabled: enabled,
                running: running, trusted: trusted, dragging: dragging, tokenValid: tokenValid)
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(context: 5))
        XCTAssertFalse(accepts(source: .init(processIdentifier: 43, bundleIdentifier: source.bundleIdentifier, launchDate: source.launchDate)))
        XCTAssertFalse(accepts(source: .init(processIdentifier: 42, bundleIdentifier: "another.app", launchDate: source.launchDate)))
        XCTAssertFalse(accepts(source: .init(processIdentifier: 42, bundleIdentifier: source.bundleIdentifier, launchDate: Date(timeIntervalSince1970: 200))))
        XCTAssertFalse(accepts(enabled: false))
        XCTAssertFalse(accepts(running: false))
        XCTAssertFalse(accepts(trusted: false))
        XCTAssertFalse(accepts(dragging: true))
        XCTAssertFalse(accepts(tokenValid: false))
        let token = SelectionCompatibilityRequestToken()
        XCTAssertTrue(token.isValid); token.invalidate(); XCTAssertFalse(token.isValid)
    }

    private final class MockAccessibility: SelectionCompatibilityAccessibility {
        var calls: [String] = []
        var advertised: Bool? = true, settable: Bool? = true, enabled: Bool? = false
        var accepted = true
        var beforeEnabled: (() -> Void)?
        var beforeAdvertised: (() -> Void)?
        var beforeSettable: (() -> Void)?
        var onRequest: (() -> Void)?
        func isAdvertised(source: SelectionCompatibilityProcess) -> Bool? { calls.append("advertised"); beforeAdvertised?(); return advertised }
        func isSettable(source: SelectionCompatibilityProcess) -> Bool? { calls.append("settable"); beforeSettable?(); return settable }
        func isEnabled(source: SelectionCompatibilityProcess) -> Bool? { calls.append("enabled"); beforeEnabled?(); return enabled }
        func request(source: SelectionCompatibilityProcess) -> Bool { calls.append("request"); onRequest?(); return accepted }
    }
}
