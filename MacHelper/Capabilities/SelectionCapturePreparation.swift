import Foundation

/// A single selection gesture may outlive a briefly unavailable menu or
/// clipboard representation. Retry preparation only; a Copy attempt is terminal.
/// No clock, timer, clipboard, AX, or keyboard operation is performed here.
struct SelectionCapturePreparation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case armed, preparing, waiting, finished }

    let context: UInt64
    let earliestCopyTime: TimeInterval?
    var maximumAttempts = 3
    var preparationWindow: TimeInterval = 1.2
    var retryInterval: TimeInterval = 0.12
    private(set) var attemptCount = 0
    private(set) var phase = Phase.armed
    private var startedAt: TimeInterval?
    private var nextAttemptAt: TimeInterval?
    private var lastTime: TimeInterval?

    init(context: UInt64, earliestCopyTime: TimeInterval? = nil) {
        self.context = context
        self.earliestCopyTime = earliestCopyTime
    }

    /// A second mouse-down may still start a third click. The double-click
    /// interval runs between mouse-downs; time spent holding the button counts.
    /// After a triple- or Shift-click, only the editor/other clipboard users
    /// need time to settle. The transaction still checks clipboard quiet and
    /// ownership immediately before taking its snapshot and dispatching Copy.
    static func clickCopyDeadline(clickCount: Int, mouseDown: TimeInterval?, mouseUp: TimeInterval,
                                  doubleClickInterval: TimeInterval) -> TimeInterval {
        let settled = mouseUp + 0.35
        guard clickCount == 2 else { return settled }
        return max(settled, min(mouseDown ?? mouseUp, mouseUp) + doubleClickInterval)
    }

    mutating func beginAttempt(context: UInt64, now: TimeInterval) -> Bool {
        guard context == self.context else { return false }
        guard phase == .armed || phase == .waiting else { return false }
        guard validConfiguration, validTime(now), attemptCount < maximumAttempts else {
            phase = .finished; return false
        }
        if let earliestCopyTime, now < earliestCopyTime { return false }
        if let nextAttemptAt, now < nextAttemptAt { return false }
        if let startedAt, now >= startedAt + preparationWindow {
            phase = .finished; return false
        }
        if startedAt == nil { startedAt = now }
        lastTime = now
        nextAttemptAt = nil
        attemptCount += 1
        phase = .preparing
        return true
    }

    /// Called only when no Copy was attempted. Returns the bounded timer delay
    /// for another preparation attempt, never permission to dispatch Copy twice.
    mutating func preparationFailed(context: UInt64, now: TimeInterval) -> TimeInterval? {
        guard context == self.context, phase == .preparing else { return nil }
        guard validConfiguration, validTime(now), attemptCount < maximumAttempts,
              let startedAt, now + retryInterval < startedAt + preparationWindow else {
            phase = .finished; return nil
        }
        lastTime = now
        nextAttemptAt = now + retryInterval
        phase = .waiting
        return retryInterval
    }

    mutating func copyAttempted(context: UInt64) {
        guard context == self.context else { return }
        phase = .finished
        nextAttemptAt = nil
    }

    /// A regular poll may arrive before the scheduled preparation retry. It
    /// must preserve the remaining delay rather than consume that retry arm.
    func delayBeforeAttempt(context: UInt64, now: TimeInterval) -> TimeInterval? {
        if context == self.context, phase == .armed, validTime(now),
           let earliestCopyTime { return max(0.001, earliestCopyTime - now) }
        guard context == self.context, phase == .waiting, validTime(now),
              let nextAttemptAt, let startedAt, now < startedAt + preparationWindow else { return nil }
        return max(0.001, nextAttemptAt - now)
    }

    /// Call for cancellation, stale source/user Copy, or final AX success.
    mutating func cancel(context: UInt64) {
        guard context == self.context else { return }
        phase = .finished
        nextAttemptAt = nil
    }

    private var validConfiguration: Bool {
        (earliestCopyTime?.isFinite ?? true) && maximumAttempts > 0 && maximumAttempts <= 3 &&
            preparationWindow.isFinite && preparationWindow > 0 && preparationWindow <= 1.2 &&
            retryInterval.isFinite && retryInterval > 0 && retryInterval < preparationWindow
    }

    private func validTime(_ now: TimeInterval) -> Bool {
        now.isFinite && (lastTime.map { now >= $0 } ?? true)
    }
}
