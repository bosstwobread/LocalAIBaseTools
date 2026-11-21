import XCTest
@testable import MacHelperCapabilities

final class SelectionEditorMarkerTests: XCTestCase {
    private func reader(owners: [Int: Int] = [101: 5, 129: 6],
                        parents: [Int: Int] = [5: 2, 6: 2, 2: 1],
                        protected: Set<Int> = [],
                        canRead: @escaping () -> Bool = { true }) -> SelectionEditorMarkerReader<Int, Int> {
        SelectionEditorMarkerReader(owner: { owners[$0] }, parent: { parents[$0] },
            protected: { protected.contains($0) }, sameElement: ==, sameMarker: ==, canRead: canRead)
    }

    func testMirroredSelectionUsesBothEndpointsOwnedByTheFocusedEditor() {
        // A layout group can index the same second line with different numeric
        // offsets. Each side independently verifies its own numeric coordinates.
        let markers = (101, 129)
        XCTAssertTrue(reader().matches(captured: markers, origin: markers, editor: markers, focused: 2))
        XCTAssertFalse(reader().matches(captured: markers, origin: markers, editor: markers, focused: 3))
        XCTAssertFalse(reader(owners: [101: 5, 129: 7], parents: [5: 2, 7: 3])
            .matches(captured: markers, origin: markers, editor: markers, focused: 2))
    }

    func testStaleOrMissingMarkersCannotBindDuplicateTextAtAnotherOffset() {
        let markers = (101, 129)
        XCTAssertFalse(reader().matches(captured: (81, 109), origin: markers, editor: markers, focused: 2))
        XCTAssertFalse(reader().matches(captured: markers, origin: markers, editor: (101, 130), focused: 2))
        XCTAssertFalse(reader().matches(captured: markers, origin: nil, editor: markers, focused: 2))
        XCTAssertFalse(reader().matches(captured: markers, origin: markers, editor: nil, focused: 2))
        XCTAssertFalse(reader().matches(captured: (101, 101), origin: (101, 101), editor: (101, 101), focused: 2))
    }

    func testEndpointOwnershipRejectsProtectedUnresolvableCyclicOrOverBudgetPaths() {
        let markers = (101, 129)
        let cases = [
            reader(protected: [6]), reader(protected: [2]),
            reader(owners: [101: 5]), reader(parents: [5: 5, 6: 2]),
            reader(parents: Dictionary(uniqueKeysWithValues: (5...15).map { ($0, $0 + 1) } + [(16, 2)])),
            reader(canRead: { false })
        ]
        for probe in cases {
            XCTAssertFalse(probe.matches(captured: markers, origin: markers, editor: markers, focused: 2))
        }
    }
}
