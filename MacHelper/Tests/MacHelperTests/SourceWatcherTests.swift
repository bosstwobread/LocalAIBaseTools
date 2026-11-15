import Foundation
import XCTest
@testable import MacHelper

final class SourceWatcherTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-watcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: root.appendingPathComponent("main.js"))
        try Data("prompt".utf8).write(to: root.appendingPathComponent("prompts/translate.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAtomicEditorReplacementAndNestedResourceChangesAreDetected() async throws {
        let root = try fixture()
        let first = expectation(description: "Atomic save detected")
        let second = expectation(description: "Nested prompt detected")
        let counter = CallbackCounter()
        let watcher = SourceFileWatcher(rootURL: root, interval: 0.03, debounce: 0.04) {
            let number = counter.increment()
            if number == 1 { first.fulfill() }
            if number == 2 { second.fulfill() }
        }
        watcher.start(); defer { watcher.stop() }
        try Data("changed1".utf8).write(to: root.appendingPathComponent("main.js"), options: [.atomic])
        await fulfillment(of: [first], timeout: 2)
        try Data("new prompt".utf8).write(to: root.appendingPathComponent("prompts/translate.txt"), options: [.atomic])
        await fulfillment(of: [second], timeout: 2)
    }

    func testRapidSavesAreDebouncedAndStoppingCancelsPendingReload() async throws {
        let root = try fixture(); let counter = CallbackCounter()
        let reload = expectation(description: "One reload after edits settle")
        let watcher = SourceFileWatcher(rootURL: root, interval: 0.02, debounce: 0.12) { if counter.increment() == 1 { reload.fulfill() } }
        watcher.start()
        for index in 0..<5 {
            try Data("edit\(index)".utf8).write(to: root.appendingPathComponent("main.js"), options: [.atomic])
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        await fulfillment(of: [reload], timeout: 2)
        XCTAssertEqual(counter.value, 1)
        try Data("pending".utf8).write(to: root.appendingPathComponent("main.js"))
        try await Task.sleep(nanoseconds: 50_000_000)
        watcher.stop()
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(counter.value, 1)
    }

    func testAddedAndRemovedResourcesReloadWithoutRequiringAValidManifest() async throws {
        let root = try fixture(); let changed = expectation(description: "New source file detected")
        let watcher = SourceFileWatcher(rootURL: root, interval: 0.02, debounce: 0.03) { changed.fulfill() }
        watcher.start(); defer { watcher.stop() }
        try Data("new resource".utf8).write(to: root.appendingPathComponent("prompts/new.txt"))
        await fulfillment(of: [changed], timeout: 2)
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
