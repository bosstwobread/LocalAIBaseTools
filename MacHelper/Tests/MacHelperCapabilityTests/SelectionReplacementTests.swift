import XCTest
@testable import MacHelperCapabilities

final class SelectionReplacementTests: XCTestCase {
    private let evidence = SelectionReplacementEvidence(processIdentifier: 42,
        range: NSRange(location: 7, length: 7), text: "draft😊")

    private func accepts(pid: Int32? = 42, focused: Bool = true, range: NSRange? = NSRange(location: 7, length: 7),
                         text: String? = "draft😊", protected: Bool = false, settable: Bool = true) -> Bool {
        evidence.accepts(processIdentifier: pid, sameFocusedElement: focused,
            currentRange: range, currentText: text, protected: protected, settable: settable)
    }

    @MainActor
    func testMissingFocusRechecksOnceBeforeAnEdit() async throws {
        var checks = 0
        var waits = 0
        let outcome = try await SelectionApplyPreflight.perform(isCurrent: { true }, waitForFocus: { waits += 1 }) {
            checks += 1
            if checks == 1 { throw SelectionReplacementPreflightError.focusUnavailable }
            return .pasteRequested
        }
        XCTAssertEqual(outcome, .pasteRequested)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(waits, 1)
    }

    @MainActor
    func testFocusWaitCannotApplyAnInvalidatedPreview() async {
        var current = true
        var checks = 0
        do {
            _ = try await SelectionApplyPreflight.perform(isCurrent: { current }, waitForFocus: { current = false }) {
                checks += 1
                throw SelectionReplacementPreflightError.focusUnavailable
            }
            XCTFail("The original preview must still be current after waiting")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(checks, 1)
    }

    @MainActor
    func testChangedTargetAndPasteFailuresAreFinal() async {
        for failure in [SelectionPasteFailure.changedTarget, .clipboardChanged, .eventUnavailable] {
            var checks = 0
            do {
                _ = try await SelectionApplyPreflight.perform(isCurrent: { true }, waitForFocus: { XCTFail("Unexpected wait") }) {
                    checks += 1
                    throw failure
                }
                XCTFail("A rejected transaction must stay rejected")
            } catch { XCTAssertEqual(error as? SelectionPasteFailure, failure) }
            XCTAssertEqual(checks, 1)
        }
    }

    func testExactOriginalEditableSelectionIsRequired() {
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(pid: 43))
        XCTAssertFalse(accepts(pid: nil))
        XCTAssertFalse(accepts(focused: false), "Same words in another field cannot authorize replacement")
        XCTAssertFalse(accepts(range: NSRange(location: 8, length: 7)))
        XCTAssertFalse(accepts(range: NSRange(location: 7, length: 0)))
        XCTAssertFalse(accepts(range: nil))
        XCTAssertFalse(accepts(text: "changed"))
        XCTAssertFalse(accepts(text: nil))
        XCTAssertFalse(accepts(protected: true))
        XCTAssertFalse(accepts(settable: false))
        XCTAssertFalse(evidence.accepts(processIdentifier: 42, sameFocusedElement: true,
            currentRange: evidence.range, currentText: evidence.text, protected: false, settable: true, enabled: false))
    }

    func testExactReplacementKeepsTheSelectedParagraphBreak() throws {
        let source = "Before\nThe library open at nine and I want borrow a book.\nAfter"
        let original = "The library open at nine and I want borrow a book.\n"
        let range = (source as NSString).range(of: original)
        let evidence = SelectionReplacementEvidence(processIdentifier: 42, range: range, text: original)
        let replacement = try XCTUnwrap(evidence.replacementText(for: "The library opens at nine, and I want to borrow a book."))
        XCTAssertEqual((source as NSString).replacingCharacters(in: range, with: replacement),
                       "Before\nThe library opens at nine, and I want to borrow a book.\nAfter")
    }

    func testExactReplacementRangeAccountsForRestoredWhitespace() {
        let evidence = SelectionReplacementEvidence(processIdentifier: 42,
            range: NSRange(location: Int.max - 2, length: 2), text: "a\n")
        XCTAssertEqual(evidence.replacementText(for: "b"), "b\n")
        XCTAssertNil(evidence.replacementText(for: "bc"))
    }

    func testCanonicalEquivalenceDoesNotAuthorizeDifferentEditorBytes() {
        let decomposed = "e\u{301}"
        let captured = SelectionReplacementEvidence(processIdentifier: 42,
            range: NSRange(location: 0, length: decomposed.utf16.count), text: decomposed)
        XCTAssertFalse(captured.accepts(processIdentifier: 42, sameFocusedElement: true,
            currentRange: NSRange(location: 0, length: decomposed.utf16.count),
            currentText: "é", protected: false, settable: true))
    }

    func testActionRoutingPreservesSpecificCommandAndInvalidatesReloadedChoices() {
        var routing = SelectionActionRouting()
        routing.replace(["translation/translate", "writing/polish", "writing/shorten"])
        XCTAssertNil(routing.selected)
        XCTAssertTrue(routing.select("writing/shorten"))
        XCTAssertEqual(routing.selected, "writing/shorten")
        XCTAssertFalse(routing.select("missing/action"))
        XCTAssertEqual(routing.selected, "writing/shorten")
        routing.replace(["translation/translate"])
        XCTAssertNil(routing.selected, "A disabled or reloaded tool cannot silently route to another command")
        XCTAssertFalse(routing.select("writing/shorten"))
    }

    func testToolbarOverflowIsBoundedWithoutDroppingCommands() {
        for count in [0, 1, 2, 5, 6, 128, 2048] {
            let identifiers = (0..<count).map { "tool/command-\($0)" }
            let layout = SelectionToolbarLayout(identifiers: identifiers)
            XCTAssertLessThanOrEqual(layout.visible.count, 5)
            XCTAssertEqual(layout.visible + layout.overflow, identifiers)
            XCTAssertLessThanOrEqual(layout.visible.count + (layout.overflow.isEmpty ? 0 : 1), 5)
        }
    }

    func testPostWriteVerificationNeverTreatsSetterSuccessAsConfirmation() {
        XCTAssertEqual(SelectionReplacementOutcome.verify(expected: "Full result", actual: "Full result"), .confirmed)
        XCTAssertEqual(SelectionReplacementOutcome.verify(expected: "Full result", actual: nil), .unverified)
        XCTAssertEqual(SelectionReplacementOutcome.verify(expected: "Full result", actual: "Full"), .changedByEditor)
        XCTAssertEqual(SelectionReplacementOutcome.verify(expected: "Full result", actual: ""), .changedByEditor)
        XCTAssertEqual(SelectionReplacementOutcome.verify(expected: "e\u{301}", actual: "é"), .changedByEditor)
        XCTAssertEqual(SelectionReplacementOutcome.verify(expected: "New text", actual: "Old text", originalText: "Old text"), .unverified,
                       "An unchanged browser AX cache is not proof of a refused or truncated renderer edit")
    }

    func testUnrelatedToolChangesPreserveSelectedOwnerAndItsGeneration() {
        let owner = SelectionActionIdentity(identifier: "writing/polish", generation: "writing-v1")
        let other = SelectionActionIdentity(identifier: "translation/translate", generation: "translation-v1")
        var routing = SelectionActionRouting()
        XCTAssertFalse(routing.reconcile([owner, other]))
        XCTAssertTrue(routing.select(owner.identifier))
        // An unrelated reload, a new install, reordering, and disabling another
        // tool must keep the same authority for an active or completed preview.
        XCTAssertTrue(routing.reconcile([.init(identifier: other.identifier, generation: "translation-v2"), owner]))
        XCTAssertEqual(routing.selectedIdentity, owner)
        XCTAssertTrue(routing.reconcile([owner, .init(identifier: "new/action", generation: "new-v1")]))
        XCTAssertEqual(routing.selectedIdentity, owner)
        XCTAssertTrue(routing.reconcile([owner]))
        XCTAssertEqual(routing.selectedIdentity, owner)
    }

    func testOwnerReloadRemovalOrCommandChangeInvalidatesSelectedPreview() {
        let owner = SelectionActionIdentity(identifier: "writing/polish", generation: "writing-v1")
        for changed in [
            [SelectionActionIdentity(identifier: owner.identifier, generation: "writing-v2")],
            [SelectionActionIdentity(identifier: "writing/shorten", generation: owner.generation)],
            []
        ] {
            var routing = SelectionActionRouting()
            routing.reconcile([owner]); XCTAssertTrue(routing.select(owner.identifier))
            XCTAssertFalse(routing.reconcile(changed))
            XCTAssertNil(routing.selectedIdentity)
        }
    }

    func testWebProvidersChooseApprovedPasteWithoutApplicationAllowlist() {
        for bundle in ["com.google.Chrome", "com.microsoft.edgemac", "com.openai.codex", "org.example.arbitrary-webview"] {
            XCTAssertEqual(SelectionReplacementStrategy.choose(bundleIdentifier: bundle, providerContext: .web,
                directAvailable: true, pasteApproved: true, pasteEditable: true), .pasteShortcut)
            XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: bundle, providerContext: .web,
                directAvailable: true, pasteApproved: false, pasteEditable: true))
            XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: bundle, providerContext: .web,
                directAvailable: true, pasteApproved: true, pasteEditable: false))
        }
        XCTAssertEqual(SelectionReplacementStrategy.choose(bundleIdentifier: "com.apple.TextEdit", providerContext: .native,
            directAvailable: true, pasteApproved: true, pasteEditable: true), .selectedText)
        XCTAssertEqual(SelectionReplacementStrategy.choose(bundleIdentifier: "com.example.native-editor", providerContext: .native,
            directAvailable: false, pasteApproved: true, pasteEditable: true), .pasteShortcut)
        XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: "com.openai.codex", providerContext: .blocked,
                directAvailable: true, pasteApproved: true, pasteEditable: true))
        for bundle in ["com.google.Chrome", "com.microsoft.edgemac", "com.openai.codex", "org.example.deep-editor"] {
            XCTAssertEqual(SelectionReplacementStrategy.choose(bundleIdentifier: bundle, providerContext: .unknown,
                directAvailable: true, pasteApproved: true, pasteEditable: true), .pasteShortcut)
            XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: bundle, providerContext: .blocked,
                directAvailable: true, pasteApproved: true, pasteEditable: true))
        }
        for missing in [nil, "", "  "] as [String?] {
            XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: missing, providerContext: .web,
                directAvailable: true, pasteApproved: true, pasteEditable: true))
        }
    }

    func testDeepOrTimedOutRoutingCanUseOnlyApprovedPasteWithStrictEditability() {
        let deep = SelectionProviderContextReader<Int>(role: { $0 == 0 ? "AXTextArea" : "AXGroup" }, parent: { $0 + 1 },
            isProtected: { _ in false }, sameElement: ==, canRead: { true }).read(from: 0)
        XCTAssertEqual(deep, .unknown)
        let timedOut = SelectionProviderContextReader<Int>(role: { _ in "AXTextArea" }, parent: { $0 + 1 },
            isProtected: { _ in false }, sameElement: ==, canRead: { false }).read(from: 0)
        XCTAssertEqual(timedOut, .unknown)
        for context in [deep, timedOut] {
            for direct in [false, true] {
                XCTAssertEqual(SelectionReplacementStrategy.choose(bundleIdentifier: "org.example.deep-editor", providerContext: context,
                    directAvailable: direct, pasteApproved: true, pasteEditable: true), .pasteShortcut)
                XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: "org.example.deep-editor", providerContext: context,
                    directAvailable: direct, pasteApproved: false, pasteEditable: true))
                XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: "org.example.deep-editor", providerContext: context,
                    directAvailable: direct, pasteApproved: true, pasteEditable: false))
            }
        }
        XCTAssertNil(SelectionReplacementStrategy.choose(bundleIdentifier: "org.example.deep-editor", providerContext: .blocked,
            directAvailable: true, pasteApproved: true, pasteEditable: true))
        XCTAssertEqual(SelectionReplacementStrategy.choose(bundleIdentifier: "com.apple.TextEdit", providerContext: .native,
            directAvailable: true, pasteApproved: true, pasteEditable: true), .selectedText)
    }

    func testProviderContextReadsOnlyBoundedAncestorRolesAndRecognizesNativeAndWeb() {
        let web = SelectionProviderContextReader<Int>(
            role: { [0: "AXTextArea", 1: "AXGroup", 2: "AXWebArea", 3: "AXWindow"][$0] },
            parent: { [0: 1, 1: 2, 2: 3][$0] }, isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertEqual(web.read(from: 0), .web)
        let native = SelectionProviderContextReader<Int>(
            role: { [0: "AXTextArea", 1: "AXScrollArea", 2: "AXWindow"][$0] },
            parent: { [0: 1, 1: 2][$0] }, isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertEqual(native.read(from: 0), .native)
    }

    func testProviderContextFailsClosedForCyclesMissingMetadataAndProtectedAncestors() {
        let cycle = SelectionProviderContextReader<Int>(role: { _ in "AXGroup" }, parent: { $0 == 0 ? 1 : 0 },
            isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertEqual(cycle.read(from: 0), .blocked)
        let missingParent = SelectionProviderContextReader<Int>(role: { _ in "AXTextArea" }, parent: { _ in nil },
            isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertEqual(missingParent.read(from: 0), .blocked)
        let missingRole = SelectionProviderContextReader<Int>(role: { $0 == 0 ? "AXTextArea" : nil }, parent: { $0 + 1 },
            isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertEqual(missingRole.read(from: 0), .blocked)
        let protectedWeb = SelectionProviderContextReader<Int>(role: { $0 == 0 ? "AXTextArea" : "AXWebArea" }, parent: { $0 + 1 },
            isProtected: { $0 == 1 }, sameElement: ==, canRead: { true })
        XCTAssertEqual(protectedWeb.read(from: 0), .blocked)
    }

    func testSavedStrategyCannotBecomeAnUnclassifiedOrWebDirectWrite() {
        XCTAssertTrue(SelectionReplacementStrategy.selectedText.acceptsCurrentContext(.native))
        for context in [SelectionProviderContext.web, .unknown, .blocked] {
            XCTAssertFalse(SelectionReplacementStrategy.selectedText.acceptsCurrentContext(context))
        }
        for context in [SelectionProviderContext.web, .native, .unknown] {
            XCTAssertTrue(SelectionReplacementStrategy.pasteShortcut.acceptsCurrentContext(context))
        }
        XCTAssertFalse(SelectionReplacementStrategy.pasteShortcut.acceptsCurrentContext(.blocked))
    }

    func testProtectionRevalidationDistinguishesInvalidParentsCyclesAndDepthLimits() {
        func protection(parent: @escaping (Int) -> SelectionParent<Int>, protected: Set<Int> = [],
                        canRead: @escaping () -> Bool = { true }) -> SelectionAncestorProtection {
            SelectionProtectionReader(parent: parent, isProtected: { protected.contains($0) },
                sameElement: ==, canRead: canRead).read(from: 0)
        }
        XCTAssertEqual(protection(parent: { $0 == 2 ? .root : .element($0 + 1) }), .clear)
        XCTAssertEqual(protection(parent: { $0 == 2 ? .invalid : .element($0 + 1) }), .blocked)
        XCTAssertEqual(protection(parent: { .element($0 == 1 ? 0 : 1) }), .blocked)
        XCTAssertEqual(protection(parent: { .element($0 + 1) }, protected: [2]), .blocked)
        XCTAssertEqual(protection(parent: { .element($0 + 1) }), .unknown)
        XCTAssertEqual(protection(parent: { _ in .root }, canRead: { false }), .unknown)
    }

    func testProviderContextDeadlineAndDepthNeverGuessNativeFromIncompleteProof() {
        var roleReads = 0
        let expired = SelectionProviderContextReader<Int>(role: { _ in roleReads += 1; return "AXWebArea" }, parent: { $0 + 1 },
            isProtected: { _ in false }, sameElement: ==, canRead: { false })
        XCTAssertEqual(expired.read(from: 0), .unknown)
        XCTAssertEqual(roleReads, 0)
        let deep = SelectionProviderContextReader<Int>(role: { _ in roleReads += 1; return "AXGroup" }, parent: { $0 + 1 },
            isProtected: { _ in false }, sameElement: ==, canRead: { true })
        XCTAssertEqual(deep.read(from: 0), .unknown)
        XCTAssertEqual(roleReads, 16)
        var checks = 0
        let midway = SelectionProviderContextReader<Int>(role: { _ in "AXGroup" }, parent: { $0 + 1 },
            isProtected: { _ in false }, sameElement: ==, canRead: { checks += 1; return checks < 4 })
        XCTAssertEqual(midway.read(from: 0), .unknown)
    }

    func testSourceApplicationIdentityRejectsChangedBundlePIDAndMissingIdentity() {
        let identity = SelectionSourceApplicationIdentity(processIdentifier: 42, bundleIdentifier: "com.google.Chrome")!
        XCTAssertTrue(identity.matches(processIdentifier: 42, bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(identity.matches(processIdentifier: 43, bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(identity.matches(processIdentifier: 42, bundleIdentifier: "com.microsoft.edgemac"))
        XCTAssertFalse(identity.matches(processIdentifier: nil, bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(identity.matches(processIdentifier: 42, bundleIdentifier: nil))
        XCTAssertNil(SelectionSourceApplicationIdentity(processIdentifier: 42, bundleIdentifier: nil))
        XCTAssertNil(SelectionSourceApplicationIdentity(processIdentifier: 42, bundleIdentifier: ""))
        XCTAssertNil(SelectionSourceApplicationIdentity(processIdentifier: 1, bundleIdentifier: "com.google.Chrome"))
    }

}
