import XCTest
@testable import MacHelper

final class ExtensionBatchSelectionTests: XCTestCase {
    private func item(_ id: String, installed: Bool = true, enabled: Bool = false) -> ExtensionBatchItem {
        ExtensionBatchItem(id: id, installed: installed, enabled: enabled)
    }

    func testCatalogToolsCannotBeSelectedOrTargeted() {
        let items = [item("installed"), item("catalog", installed: false)]
        var selection = ExtensionBatchSelection()
        selection.setSelected(true, id: "catalog", items: items)
        selection.setSelected(true, id: "missing", items: items)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        selection.selectAll(true, items: items)
        XCTAssertEqual(selection.selectedIDs, ["installed"])
        XCTAssertEqual(selection.targets(for: .editSource, items: items), ["installed"])
    }

    func testRefreshPreservesSelectedIdentitiesAndDoesNotSelectNewTools() {
        var selection = ExtensionBatchSelection()
        selection.selectAll(true, items: [item("first"), item("second", enabled: true)])
        let refreshed = [item("second", enabled: false), item("first", enabled: true), item("new")]
        selection.reconcile(items: refreshed)
        XCTAssertEqual(selection.selectedIDs, ["first", "second"])
        XCTAssertEqual(selection.targets(for: .editSource, items: refreshed), ["second", "first"])
        XCTAssertEqual(selection.targets(for: .reload, items: refreshed), ["first"])
    }

    func testRemovedOrNoLongerInstalledToolsArePruned() {
        var selection = ExtensionBatchSelection()
        selection.selectAll(true, items: [item("retained"), item("removed"), item("catalog-again")])
        selection.reconcile(items: [item("retained"), item("catalog-again", installed: false)])
        XCTAssertEqual(selection.selectedIDs, ["retained"])
        selection.reconcile(items: [])
        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    func testIndividualSelectionAndClearDoNotChangeOtherSelections() {
        let items = [item("first"), item("second"), item("third")]
        var selection = ExtensionBatchSelection()
        selection.setSelected(true, id: "first", items: items)
        selection.setSelected(true, id: "second", items: items)
        selection.setSelected(false, id: "first", items: items)
        XCTAssertEqual(selection.selectedIDs, ["second"])
        selection.selectAll(false, items: items)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertTrue(selection.targets(for: .enable, items: items).isEmpty)
    }

    func testMixedEnabledStatesPlanOnlyRelevantSelectedTools() {
        let items = [item("on", enabled: true), item("off"), item("unselected-on", enabled: true), item("unselected-off")]
        var selection = ExtensionBatchSelection()
        selection.setSelected(true, id: "on", items: items)
        selection.setSelected(true, id: "off", items: items)
        XCTAssertEqual(selection.targets(for: .reload, items: items), ["on"])
        XCTAssertEqual(selection.targets(for: .enable, items: items), ["off"])
        XCTAssertEqual(selection.targets(for: .disable, items: items), ["on"])
        XCTAssertEqual(selection.targets(for: .editSource, items: items), ["on", "off"])
    }

    func testActionsBecomeNoOpsWhenTheRequestedStateAlreadyMatches() {
        var selection = ExtensionBatchSelection()
        selection.selectAll(true, items: [item("tool", enabled: true)])
        XCTAssertTrue(selection.targets(for: .enable, items: [item("tool", enabled: true)]).isEmpty)
        let disabled = [item("tool", enabled: false)]
        XCTAssertTrue(selection.targets(for: .disable, items: disabled).isEmpty)
        XCTAssertTrue(selection.targets(for: .reload, items: disabled).isEmpty)
        XCTAssertEqual(selection.targets(for: .editSource, items: disabled), ["tool"])
    }

    func testTargetsFollowVisibleOrderAndDeduplicateIdentities() {
        let items = [item("third", enabled: true), item("first"), item("third", enabled: true), item("second"), item("first")]
        var selection = ExtensionBatchSelection()
        selection.selectAll(true, items: items)
        XCTAssertEqual(selection.selectedIDs, ["first", "second", "third"])
        XCTAssertEqual(selection.targets(for: .editSource, items: items), ["third", "first", "second"])
        XCTAssertEqual(selection.targets(for: .enable, items: items), ["first", "second"])
        XCTAssertEqual(selection.targets(for: .reload, items: items), ["third"])
    }

    func testPlanningRechecksCurrentInstallationEvenBeforeReconciliation() {
        var selection = ExtensionBatchSelection()
        selection.selectAll(true, items: [item("tool", enabled: true)])
        let current = [item("tool", installed: false, enabled: true)]
        for action: ExtensionBatchAction in [.reload, .editSource, .enable, .disable] {
            XCTAssertTrue(selection.targets(for: action, items: current).isEmpty)
        }
    }
}
