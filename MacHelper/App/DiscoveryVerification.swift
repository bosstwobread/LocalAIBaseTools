import AppKit
import Foundation
import MacHelper

/// Real offscreen controls over fixed public metadata. This check never opens
/// a provider, extension worker, browser, user settings, or installation path.
@MainActor
enum DiscoveryVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Fixture {
        let translation = DiscoveryEntry(id: "com.example.translation", slug: "translation", name: "Translation", version: "1.0.0",
            summary: "Understand selected text.", description: "Read text in your own language.",
            capabilities: ["Translate selected text"], exampleQueries: ["Help me understand a sentence."],
            keywords: ["translate"], limitations: ["Requires text selection."], platforms: ["macOS"])
        let invoice = DiscoveryEntry(id: "com.example.invoice", slug: "invoice", name: "Invoices", version: "1.0.0",
            summary: "Prepare a bill.", description: "Make an invoice for completed work.",
            capabilities: ["Draft invoices"], exampleQueries: ["Create a bill for my client."],
            keywords: ["billing"], limitations: ["Review totals yourself."], platforms: ["macOS"])
        var snapshot: DiscoveryCatalogSnapshot
        var loadCount = 0
        var searchCount = 0
        var cancelCount = 0
        var holdSearch = false
        var noMatch = false
        var changeRevision = false
        var opened: [URL] = []

        init() {
            snapshot = DiscoveryCatalogSnapshot(index: DiscoveryIndex(revision: String(repeating: "a", count: 64),
                updatedAt: "2026-11-17T00:00:00Z", extensions: [translation, invoice]), stale: false)
        }

        func controller(draft: DiscoveryViewController.Draft = .init()) -> DiscoveryViewController {
            DiscoveryViewController(services: .init(load: { [self] _ in loadCount += 1; return snapshot },
                search: { [self] _, _, update in
                    searchCount += 1
                    update("Understanding your request…")
                    repeat { try await Task.sleep(nanoseconds: 20_000_000) } while holdSearch
                    let revision = snapshot.index.revision
                    if changeRevision {
                        snapshot = .init(index: .init(revision: String(repeating: "b", count: 64),
                            updatedAt: "2026-11-18T00:00:00Z", extensions: [translation, invoice]), stale: false)
                    }
                    return .init(revision: revision, updatedAt: "2026-11-17T00:00:00Z", stale: false,
                        model: "fixture-model", matches: noMatch ? [] : [.init(id: translation.id,
                            reason: "Translates selected sentences for reading.", fit: "partial")],
                        noMatchReason: noMatch ? "This catalog has no tool for that task." : nil)
                }, cancel: { [self] in
                    cancelCount += 1
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }), draft: draft, marketplaceURL: { URL(string: "https://market.example/")! },
                openDetails: { [self] in opened.append($0); return true })
        }
    }

    static func run() async -> Int32 {
        var checks: [String] = []
        do {
            let fixture = Fixture(), controller = fixture.controller()
            controller.loadViewIfNeeded()
            controller.view.frame = NSRect(x: 0, y: 0, width: 820, height: 700)
            controller.viewDidAppear()
            try await idle(controller)
            controller.view.layoutSubtreeIfNeeded()
            try check(fixture.loadCount == 1 && fixture.searchCount == 0, "Browsing metadata started AI or repeated its load.")
            try check(find("discovery-result-" + fixture.translation.id, in: controller.view) != nil &&
                      find("discovery-result-" + fixture.invoice.id, in: controller.view) != nil,
                      "Keyword mode did not list the metadata catalog.")
            try check(try button("discovery-ai-search", in: controller).isHidden, "Keyword mode exposed AI as its search action.")
            let query = try queryView(in: controller)
            query.string = "invoice"; controller.textDidChange(Notification(name: NSText.didChangeNotification))
            try check(fixture.searchCount == 0 && find("discovery-result-" + fixture.invoice.id, in: controller.view) != nil &&
                      find("discovery-result-" + fixture.translation.id, in: controller.view) == nil,
                      "Keyword search did not search description metadata without AI.")
            checks.append("metadata browsing and description keyword matching never call AI")

            let original = "Help me understand a sentence in another language."
            controller.present(query: original)
            try check(fixture.searchCount == 0 && query.string == original && controller.draft.describesNeed,
                      "Website prefill modified the request or ran AI.")
            try button("discovery-ai-search", in: controller).performClick(nil)
            try await idle(controller)
            try check(fixture.searchCount == 1 && labels(in: controller.view).contains("Translates selected sentences for reading.") &&
                      labels(in: controller.view).contains("Partial match"), "AI reasons and fit did not render.")
            try check(labels(in: controller.view).contains("• Requires text selection."), "A result omitted its published limitation.")
            try button("discovery-details-" + fixture.translation.id, in: controller).performClick(nil)
            try check(fixture.opened.map(\.absoluteString) == ["https://market.example/#extension/translation"],
                      "Details did not open the trusted marketplace listing.")
            checks.append("links only prefill; explicit AI results show reasons and limitations and open verified listing details")

            query.string = String(repeating: "😀", count: 1001)
            controller.textDidChange(Notification(name: NSText.didChangeNotification))
            try check(!(try button("discovery-ai-search", in: controller)).isEnabled &&
                      field("discovery-status", in: controller).stringValue.contains("2,000"),
                      "The UI accepted a query exceeding its UTF-16 limit.")
            controller.present(query: original)
            fixture.holdSearch = true
            try button("discovery-ai-search", in: controller).performClick(nil)
            try await eventually("AI fixture did not start") { fixture.searchCount == 2 }
            try button("discovery-cancel", in: controller).performClick(nil)
            try check(controller.isBusy && !(try button("discovery-ai-search", in: controller)).isEnabled,
                      "A new search could start before old provider cancellation finished.")
            try await idle(controller)
            try check(fixture.cancelCount == 1 && field("discovery-status", in: controller).stringValue == "Search cancelled.",
                      "Cancellation did not finish cleanly.")
            fixture.holdSearch = false
            try await Task.sleep(nanoseconds: 40_000_000)
            try check(field("discovery-status", in: controller).stringValue == "Search cancelled.",
                      "An obsolete operation overwrote cancellation state.")
            checks.append("query bounds use the shared validator; cancellation blocks new work until cleanup and rejects late results")

            let replacement = fixture.controller(draft: controller.draft)
            replacement.loadViewIfNeeded()
            try check(replacement.draft.query == original && replacement.draft.describesNeed && fixture.searchCount == 2,
                      "Rebuilding localized presentation dropped the draft or ran AI.")
            fixture.changeRevision = true
            try button("discovery-ai-search", in: controller).performClick(nil)
            try await idle(controller)
            try check(field("discovery-status", in: controller).stringValue == "The catalog changed. Search again." &&
                      !labels(in: controller.view).contains("Translates selected sentences for reading."),
                      "A result from an obsolete catalog revision was shown.")
            fixture.changeRevision = false; fixture.noMatch = true
            try button("discovery-ai-search", in: controller).performClick(nil)
            try await idle(controller)
            try check(labels(in: controller.view).contains("No suitable extension was found.") &&
                      labels(in: controller.view).contains("This catalog has no tool for that task."),
                      "A no-match result was presented as a recommendation.")
            checks.append("presentation rebuild preserves request drafts; obsolete catalog results and no-match replies are handled explicitly")
            print("PASS: " + checks.joined(separator: "; "))
            return 0
        } catch {
            print("FAIL: " + error.localizedDescription)
            return 1
        }
    }

    private static func idle(_ controller: DiscoveryViewController) async throws {
        try await eventually("Discovery controls stayed busy") { !controller.isBusy }
        await Task.yield()
    }
    private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(message: message)
    }
    private static func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    private static func button(_ id: String, in controller: DiscoveryViewController) throws -> NSButton {
        guard let button = find(id, in: controller.view) as? NSButton else { throw Failure(message: "Missing button: " + id) }
        return button
    }
    private static func field(_ id: String, in controller: DiscoveryViewController) throws -> NSTextField {
        guard let field = find(id, in: controller.view) as? NSTextField else { throw Failure(message: "Missing field: " + id) }
        return field
    }
    private static func queryView(in controller: DiscoveryViewController) throws -> NSTextView {
        guard let view = find("discovery-query", in: controller.view) as? NSTextView else { throw Failure(message: "Missing query field") }
        return view
    }
    private static func labels(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { labels(in: $0) }
    }
    private static func check(_ result: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !result() { throw Failure(message: message) }
    }
}
