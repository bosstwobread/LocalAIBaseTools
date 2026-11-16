import Foundation
import XCTest
import Darwin
@testable import MacHelper

@MainActor
final class NativeSourceBuilderTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var builder: NativeSourceBuilder!
    private var sdk: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NativeExtensionSDK/MacHelperNativeSDK.swift")
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacHelperNativeTests-" + UUID().uuidString)
        source = root.appendingPathComponent("Author")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        builder = NativeSourceBuilder(sdkURL: sdk, cacheDirectory: root.appendingPathComponent("Builds"))
        try writePackage(Self.fixture)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testNativeBuildCachesCodeButResourcesUseFreshFrozenGeneration() async throws {
        let first = try SourcePackageInspector.snapshot(at: source)
        let binary = try await builder.build(snapshot: first)
        XCTAssertEqual(binary.lastPathComponent, "MacHelperNativeWorker")
        let cached = try await builder.build(snapshot: first)
        XCTAssertEqual(cached, binary)
        try Data("Changed resource\n".utf8).write(to: source.appendingPathComponent("prompts/translate.txt"))
        let second = try SourcePackageInspector.snapshot(at: source)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        let resourceBuild = try await builder.build(snapshot: second)
        XCTAssertEqual(resourceBuild, binary, "Resources must not require recompilation")
        let client = ScriptWorkerClient(executableURL: binary)
        try await client.load(entrySource: second.entrySource, resources: second.resources, permissions: second.manifest.permissions) { _ in [:] }
        let answer = try await client.invoke(command: "resource", input: [:])
        XCTAssertEqual(answer["text"] as? String, "Changed resource\n")
        let pid = client.processIdentifier
        await client.stop(); assertExited(pid)
    }

    func testNativeAIUsesExactPromptSeparateInputAndStreamingBeforeFinal() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        let binary = try await builder.build(snapshot: snapshot)
        let client = ScriptWorkerClient(executableURL: binary)
        var release = false
        var finished = false
        var progress: [String] = []
        var requests = 0
        try await client.load(entrySource: snapshot.entrySource, resources: snapshot.resources, permissions: snapshot.manifest.permissions,
            streamingCapabilityHandler: { request, emit in
                requests += 1
                XCTAssertEqual(Array((request["systemPrompt"] as? String ?? "").utf8), Array(Self.prompt.utf8))
                XCTAssertEqual(request["text"] as? String, "public \"fixture\"\n你好")
                emit(["text": "你", "delta": "你", "model": "fixture-native-model"])
                while !release { try await Task.sleep(nanoseconds: 5_000_000) }
                emit(["text": "你好", "delta": "好", "model": "fixture-native-model"])
                return ["text": "你好", "model": "fixture-native-model"]
            }) { _ in XCTFail("Expected streaming capability"); return [:] }
        let operation = Task {
            let result = try await client.invoke(command: "translate", input: ["text": "public \"fixture\"\n你好"]) { update in
                XCTAssertFalse(finished)
                progress.append(update["text"] as? String ?? "")
            }
            finished = true
            return result
        }
        for _ in 0..<200 where progress.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(progress, ["你"])
        XCTAssertFalse(finished)
        release = true
        let translated = try await operation.value
        XCTAssertEqual(translated["text"] as? String, "你好")
        XCTAssertEqual(progress, ["你", "你好"])
        XCTAssertEqual(requests, 1)
        let pid = client.processIdentifier
        await client.stop(); assertExited(pid)
    }

    func testRetainedNativeInputCannotReportIntoAnotherInvocation() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        let binary = try await builder.build(snapshot: snapshot)
        let client = ScriptWorkerClient(executableURL: binary)
        try await client.load(entrySource: snapshot.entrySource, resources: snapshot.resources, permissions: snapshot.manifest.permissions) { _ in [:] }
        var updates: [String] = []
        _ = try await client.invoke(command: "remember", input: [:])
        let answer = try await client.invoke(command: "stale", input: [:]) { updates.append($0["text"] as? String ?? "") }
        XCTAssertEqual(answer["text"] as? String, "fresh final")
        XCTAssertEqual(updates, ["fresh partial"])
        await client.stop()
    }

    func testNativePermissionAndInvocationGuardsRejectUnapprovedCapabilities() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        let binary = try await builder.build(snapshot: snapshot)
        let client = ScriptWorkerClient(executableURL: binary)
        var aiCalls = 0
        try await client.load(entrySource: snapshot.entrySource, resources: snapshot.resources, permissions: ["native.execute"]) { _ in aiCalls += 1; return [:] }
        for command in ["translate", "stale"] {
            do { _ = try await client.invoke(command: command, input: [:]); XCTFail("A missing permission must reject the operation") }
            catch { XCTAssertNotEqual(error as? ScriptWorkerError, .timedOut) }
        }
        XCTAssertEqual(aiCalls, 0)
        let result = try await client.invoke(command: "resource", input: [:])
        XCTAssertEqual(result["text"] as? String, Self.prompt)
        await client.stop()
    }

    func testNativeCancellationReapsWorkerAndCancelsHostAI() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        let binary = try await builder.build(snapshot: snapshot)
        let client = ScriptWorkerClient(executableURL: binary, requestTimeout: 20)
        var started = false
        var cancelled = false
        try await client.load(entrySource: snapshot.entrySource, resources: snapshot.resources, permissions: snapshot.manifest.permissions) { _ in
            started = true
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { cancelled = true; throw error }
            return ["text": "unexpected"]
        }
        let pid = client.processIdentifier
        let invocation = Task { try await client.invoke(command: "translate", input: ["text": "synthetic public input"]) }
        for _ in 0..<200 where !started { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(started)
        invocation.cancel()
        do { _ = try await invocation.value; XCTFail("Cancelled invocation must fail") }
        catch { XCTAssertEqual(error as? ScriptWorkerError, .cancelled) }
        await client.stop()
        XCTAssertTrue(cancelled); assertExited(pid)
    }

    func testFailedNativeRebuildPreservesThePriorExecutableAndUsesFrozenSource() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        // The builder uses captured source, even if the editable file changes.
        try Data("This is not Swift".utf8).write(to: source.appendingPathComponent("Main.swift"))
        let binary = try await builder.build(snapshot: snapshot)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let invalid = try SourcePackageInspector.snapshot(at: source)
        do { _ = try await builder.build(snapshot: invalid); XCTFail("Invalid Swift must not replace good code") }
        catch { XCTAssertTrue(error.localizedDescription.contains("compile")) }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Builds").path).contains(where: { $0.hasPrefix(".build-") }))
        let client = ScriptWorkerClient(executableURL: binary)
        try await client.load(entrySource: snapshot.entrySource, resources: snapshot.resources, permissions: snapshot.manifest.permissions) { _ in [:] }
        let resource = try await client.invoke(command: "resource", input: [:])
        XCTAssertEqual(resource["text"] as? String, Self.prompt)
        await client.stop()
    }

    func testCancelledAndTimedOutBuildsLeaveNoPartialCacheGeneration() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        let pending = Task { try await builder.build(snapshot: snapshot) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled build must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let brief = NativeSourceBuilder(sdkURL: sdk, cacheDirectory: root.appendingPathComponent("Brief"), timeout: 0.1)
        do { _ = try await brief.build(snapshot: snapshot); XCTFail("The real native compile must exceed the tiny test timeout") }
        catch { XCTAssertEqual(error as? NativeSourceBuildError, .timedOut) }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Brief").path) {
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Brief").path).contains(where: { $0.hasPrefix(".build-") }))
        }
    }

    func testTamperedNativeCacheAndSymlinkedSDKAreRejected() async throws {
        let snapshot = try SourcePackageInspector.snapshot(at: source)
        let binary = try await builder.build(snapshot: snapshot)
        try Data("invalid executable".utf8).write(to: binary)
        do { _ = try await builder.build(snapshot: snapshot); XCTFail("Tampered cache must not execute") }
        catch { XCTAssertTrue(error.localizedDescription.contains("validation")) }
        let link = root.appendingPathComponent("SDK.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sdk)
        let unsafe = NativeSourceBuilder(sdkURL: link, cacheDirectory: root.appendingPathComponent("Unsafe"))
        do { _ = try await unsafe.build(snapshot: snapshot); XCTFail("Symlinked SDK must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("regular file")) }
    }

    private func writePackage(_ main: String) throws {
        let manifest = SourceExtensionManifest(runtime: "native", identifier: "com.example.native-fixture", displayName: "Native Fixture", version: "1.0.0",
            summary: "Synthetic native fixture.", entryPoint: "Main.swift", permissions: ["native.execute", "ai.transform", "ui.panel"],
            commands: ["translate", "resource", "remember", "stale"].map { SourceExtensionCommand(identifier: $0, title: $0, trigger: "manual") })
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("extension.json"))
        try Data(main.utf8).write(to: source.appendingPathComponent("Main.swift"))
        try Data(Self.prompt.utf8).write(to: source.appendingPathComponent("prompts/translate.txt"))
    }

    private func assertExited(_ pid: Int32?, file: StaticString = #filePath, line: UInt = #line) {
        guard let pid else { return }
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    private static let prompt = "  Original prompt e\u{301}\nPreserve whitespace.\n"
    private static let fixture = #"""
    import Foundation
    @main struct NativeFixture {
      static func main() {
        var saved: MacHelperNativeInput?
        MacHelperNative.run(commands: [
          "translate": { input in
            let answer = try await input.transform(request: ["action":"translate", "text":input.text, "systemPrompt":try input.readText("prompts/translate.txt")]) { partial in
              try? input.reportProgress(text: partial["text"] as? String ?? "")
            }
            return ["text":answer["text"] as? String ?? ""]
          },
          "resource": { input in ["text":try input.readText("prompts/translate.txt")] },
          "remember": { input in saved=input; return ["text":"remembered"] },
          "stale": { input in
            do { try saved?.reportProgress(text:"obsolete") } catch { }
            try input.reportProgress(text:"fresh partial")
            return ["text":"fresh final"]
          }
        ])
      }
    }
    """#
}
