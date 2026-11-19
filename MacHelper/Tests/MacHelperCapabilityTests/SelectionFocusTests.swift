import Foundation
import XCTest
@testable import MacHelperCapabilities

final class SelectionFocusTests: XCTestCase {
    private func reader(_ links: [Int: Int], protected: Set<Int> = [], canRead: @escaping () -> Bool = { true }) -> SelectionFocusReader<Int> {
        .init(focusedChild: { links[$0].map { .element($0) } ?? .leaf }, isProtected: { protected.contains($0) }, sameElement: ==, canRead: canRead)
    }

    func testNativeFocusAndForwardedWebFocusPreserveAnchorAndLeaf() throws {
        let native = try XCTUnwrap(reader([:]).read(from: 1))
        XCTAssertEqual(native.elements, [1])
        let web = try XCTUnwrap(reader([1: 2, 2: 3, 3: 3]).read(from: 1))
        XCTAssertEqual(web.elements, [1, 2, 3])
        XCTAssertEqual(web.anchor, 1)
        XCTAssertEqual(web.leaf, 3)
        XCTAssertTrue(web.matches(reader([1: 2, 2: 3]).read(from: 1), sameElement: ==))
        var otherRoute = web
        otherRoute.systemWide = true
        XCTAssertFalse(web.matches(otherRoute, sameElement: ==), "Focus proofs must be revalidated through their original root")
    }

    func testChangedAnchorLeafOrIntermediateFocusRejectsOriginalTarget() throws {
        let original = try XCTUnwrap(reader([1: 2, 2: 3]).read(from: 1))
        for changed in [reader([4: 2, 2: 3]).read(from: 4), reader([1: 2, 2: 4]).read(from: 1),
                        reader([1: 4, 4: 3]).read(from: 1), reader([1: 3]).read(from: 1), nil] {
            XCTAssertFalse(original.matches(changed, sameElement: ==))
        }
    }

    func testCyclesProtectionDepthAndDeadlineFailClosed() {
        XCTAssertNil(reader([1: 2, 2: 1]).read(from: 1))
        XCTAssertNil(reader([1: 2, 2: 3], protected: [2]).read(from: 1))
        XCTAssertNil(reader([1: 2, 2: 3, 3: 4, 4: 5]).read(from: 1))
        XCTAssertNil(reader([1: 2], canRead: { false }).read(from: 1))
        var reads = 0
        XCTAssertNil(reader([1: 2], canRead: { reads += 1; return reads < 3 }).read(from: 1))
        let malformed = SelectionFocusReader<Int>(focusedChild: { _ in .invalid }, isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertNil(malformed.read(from: 1), "Wrong-type or failed focus queries cannot be treated as a valid leaf")
    }

    func testOnlyAnAbsentRootFocusIsUnavailable() {
        var pathReads = 0
        let discovery = SelectionFocusReader<Int>(focusedChild: { _ in pathReads += 1; return .leaf },
            isProtected: { _ in false }, sameElement: ==, canRead: { true })
        guard case .unavailable = discovery.resolveRoot(.leaf) else { return XCTFail("An absent root attribute permits a fallback") }
        assertBlocked(discovery.resolveRoot(.invalid))
        assertBlocked(discovery.resolveRoot(.element(1), validAnchor: { _ in false }))
        XCTAssertEqual(pathReads, 0, "Malformed or foreign root evidence cannot inspect a focus path")
        guard case .path(let path) = discovery.resolveRoot(.element(1)) else { return XCTFail("A child leaf is a valid path, not an absent root") }
        XCTAssertEqual(path.elements, [1])
        XCTAssertEqual(pathReads, 1)
    }

    func testBlockedFocusCannotBeCollapsedIntoUnavailableFallbackEvidence() {
        assertBlocked(reader([1: 2], protected: [2]).resolveRoot(.element(1)))
        assertBlocked(reader([1: 2, 2: 1]).resolveRoot(.element(1)))
        assertBlocked(reader([1: 2, 2: 3, 3: 4, 4: 5]).resolveRoot(.element(1)))
        assertBlocked(reader([:], canRead: { false }).resolveRoot(.leaf))
        let malformed = SelectionFocusReader<Int>(focusedChild: { _ in .invalid }, isProtected: { _ in false }, sameElement: ==, canRead: { true })
        assertBlocked(malformed.resolveRoot(.element(1)))
        var allowed = true
        let expiredAfterAnchorCheck = reader([:], canRead: { allowed })
        assertBlocked(expiredAfterAnchorCheck.resolveRoot(.element(1), validAnchor: { _ in allowed = false; return true }))
    }

    private func assertBlocked(_ result: SelectionFocusResolution<Int>,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .blocked = result else { return XCTFail("Rejected focus proof must suppress broader fallback capture", file: file, line: line) }
    }

    func testFocusDiscoveryCannotAuthorizeOffsetsFromAnotherControl() {
        let leaf = SelectionReplacementEvidence(processIdentifier: 42, range: NSRange(location: 0, length: 5), text: "draft")
        XCTAssertTrue(leaf.accepts(processIdentifier: 42, sameFocusedElement: true,
            currentRange: NSRange(location: 0, length: 5), currentText: "draft", protected: false, settable: true))
        XCTAssertFalse(leaf.accepts(processIdentifier: 42, sameFocusedElement: true,
            currentRange: NSRange(location: 400, length: 5), currentText: "draft", protected: false, settable: true))
    }
}
