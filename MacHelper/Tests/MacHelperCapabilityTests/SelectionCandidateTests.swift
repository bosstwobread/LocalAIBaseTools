import XCTest
import ApplicationServices
@testable import MacHelperCapabilities

final class SelectionCandidateTests: XCTestCase {
    func testIdenticalTextInAnotherNodeDoesNotMatchReadSourceIdentity() {
        let process = SelectionCompatibilityProcess(processIdentifier: 42, bundleIdentifier: "com.example.fixture", launchDate: nil)
        let readSource = AXUIElementCreateApplication(42)
        let otherSource = AXUIElementCreateApplication(43)
        let origin = AccessibilitySelectionOrigin(process: process, ancestry: [readSource], sourceIndex: 0,
            focus: nil, hitPoint: .zero)
        XCTAssertTrue(origin.matchesSource(readSource))
        XCTAssertFalse(origin.matchesSource(otherSource))
    }

    func testSwitchingReadProofRoutesPreservesSelectionAndRefreshesProvenance() {
        let process = SelectionCompatibilityProcess(processIdentifier: 42, bundleIdentifier: "com.example.fixture", launchDate: nil)
        let node = AXUIElementCreateApplication(42)
        let hit = AccessibilitySelectionOrigin(process: process, ancestry: [node], sourceIndex: 0, focus: nil, hitPoint: .zero)
        let focus = AccessibilitySelectionOrigin(process: process, ancestry: [node], sourceIndex: 0,
            focus: SelectionFocusPath(elements: [node]), hitPoint: nil)
        var first = TextSelection(text: "word", sourcePID: 42, rangeLocation: 0, rangeLength: 4, bounds: .zero, accessibilityOrigin: hit)
        var state = SelectionState()
        XCTAssertTrue(state.observe(first))
        let generation = state.generation
        first.accessibilityOrigin = focus
        XCTAssertFalse(state.observe(first))
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.selection?.accessibilityOrigin?.focus?.elements.count, 1)
    }

    private func reader(parents: [Int: Int], protected: Set<Int> = [], budget: @escaping () -> Bool = { true },
                        read: @escaping (Int) -> SelectedTextReadResult) -> SelectionCandidateReader<Int> {
        .init(parent: { parents[$0].map { .element($0) } ?? .root }, isProtected: { protected.contains($0) },
              sameElement: ==, canRead: budget, selectedSpan: read)
    }

    func testMalformedParentFailsClosedBeforeReadingAnyText() {
        var reads = 0
        let candidate = SelectionCandidateReader<Int>(parent: { _ in .invalid }, isProtected: { _ in false },
            sameElement: ==, canRead: { true }, selectedSpan: { _ in
                reads += 1
                return .selected(.init(text: "word", range: NSRange(location: 0, length: 4)))
            })
        XCTAssertNil(candidate.read(from: 1))
        XCTAssertEqual(reads, 0)
    }

    func testEmptyChildDoesNotHideParentSelectionAndPreservesItsOwnRange() throws {
        let span = SelectedTextSpan(text: "word", range: NSRange(location: 51, length: 4))
        let value = reader(parents: [1: 2, 2: 3]) { $0 == 2 ? .selected(span) : .empty }.read(from: 1)
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.ancestry, [1, 2, 3])
        XCTAssertEqual(result.sourceIndex, 1)
        XCTAssertEqual(result.span.range, NSRange(location: 51, length: 4))
        guard case .root = result.terminalParent else { return XCTFail("The terminal parent must record a proven root") }
    }

    func testProtectionCyclesAndExpiredBudgetPreventAnyTextRead() {
        for (parents, protected, allowed) in [([1: 2, 2: 3], Set([3]), true), ([1: 2, 2: 1], Set<Int>(), true), ([1: 2], Set<Int>(), false)] {
            var reads = 0
            let value = reader(parents: parents, protected: protected, budget: { allowed }) { _ in
                reads += 1
                return .selected(.init(text: "word", range: NSRange(location: 0, length: 4)))
            }.read(from: 1)
            XCTAssertNil(value)
            XCTAssertEqual(reads, 0)
        }
    }

    func testUnavailableChildAndBoundedParentsNeverReadOtherDescendants() throws {
        var seen: [Int] = []
        var candidate = reader(parents: Dictionary(uniqueKeysWithValues: (1...20).map { ($0, $0 + 1) })) { node in
            seen.append(node)
            return node == 8 ? .selected(.init(text: "last", range: NSRange(location: 3, length: 4))) : .unavailable
        }
        candidate.maximumAncestors = 100
        let result = try XCTUnwrap(candidate.read(from: 1))
        XCTAssertEqual(result.ancestry, Array(1...8))
        XCTAssertEqual(seen, Array(1...8))
        XCTAssertEqual(result.sourceIndex, 7)
        guard case .element(let next) = result.terminalParent else { return XCTFail("Depth limits must preserve the last parent link for revalidation") }
        XCTAssertEqual(next, 9)
    }
}
