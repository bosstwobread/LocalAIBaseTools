import XCTest
@testable import MacHelperCapabilities

final class SelectionCopyRevalidationTests: XCTestCase {
    func testOnlyTwoChecksFollowConsecutiveTransportFailures() {
        var checks = SelectionCopyRevalidation()
        XCTAssertTrue(checks.shouldRetry(after: .temporarilyUnavailable))
        XCTAssertTrue(checks.shouldRetry(after: .temporarilyUnavailable))
        XCTAssertFalse(checks.shouldRetry(after: .temporarilyUnavailable))
    }

    func testDefiniteLossEndsRecoveryImmediately() {
        var checks = SelectionCopyRevalidation()
        XCTAssertTrue(checks.shouldRetry(after: .temporarilyUnavailable))
        XCTAssertFalse(checks.shouldRetry(after: .invalid))
    }

    func testVerifiedTargetResetsConsecutiveFailureBudget() {
        var checks = SelectionCopyRevalidation()
        XCTAssertTrue(checks.shouldRetry(after: .temporarilyUnavailable))
        XCTAssertTrue(checks.shouldRetry(after: .temporarilyUnavailable))
        XCTAssertFalse(checks.shouldRetry(after: .current))
        XCTAssertEqual(checks.consecutiveTimeouts, 0)
        XCTAssertTrue(checks.shouldRetry(after: .temporarilyUnavailable))
    }
}
