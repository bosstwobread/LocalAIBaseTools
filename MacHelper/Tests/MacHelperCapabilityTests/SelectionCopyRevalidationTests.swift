import XCTest
import ApplicationServices
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

    func testReadOnlyPointerCanReachVerifiedWindowThroughDeepGroups() {
        func valid(window: Int = 9, blocked: Int? = nil, cycles: Bool = false, placeholder: Bool = true) -> Bool {
            SelectionReadOnlyCopy.reachesWindow(from: 0, to: window, sameElement: ==) { node, isHit in
                guard node != blocked else { return nil }
                let next = cycles && node == 5 ? 1 : node + 1
                return (.element(next), isHit && placeholder)
            }
        }
        XCTAssertTrue(valid())
        XCTAssertFalse(valid(blocked: 5))
        XCTAssertFalse(valid(cycles: true))
        XCTAssertFalse(valid(window: 16))
        XCTAssertFalse(valid(placeholder: false))
        XCTAssertFalse(SelectionReadOnlyCopy.reachesWindow(from: 0, to: 9, sameElement: ==) { node, isHit in
            (node == 8 ? .root : .element(node + 1), isHit)
        })
    }

    func testOnlyNonwritableEmptyTextOnReadOnlyRolesIsAPlaceholder() {
        func placeholder(_ role: String, hit: Bool = true, text: String? = "", valueReadOnly: Bool = true,
                         textReadOnly: Bool = true) -> Bool {
            SelectionReadOnlyCopy.isPlaceholder(role: role, isHit: hit, selectedText: text,
                                                valueIsReadOnly: valueReadOnly, selectedTextIsReadOnly: textReadOnly)
        }
        XCTAssertTrue(placeholder(kAXStaticTextRole))
        XCTAssertTrue(placeholder(kAXGroupRole, hit: false))
        XCTAssertFalse(placeholder(kAXGroupRole))
        XCTAssertFalse(placeholder(kAXTextFieldRole))
        XCTAssertFalse(placeholder(kAXTextAreaRole, hit: false))
        XCTAssertFalse(placeholder(kAXStaticTextRole, text: nil))
        XCTAssertFalse(placeholder(kAXStaticTextRole, text: "selection"))
        XCTAssertFalse(placeholder(kAXStaticTextRole, valueReadOnly: false))
        XCTAssertFalse(placeholder(kAXStaticTextRole, textReadOnly: false))
    }
}
