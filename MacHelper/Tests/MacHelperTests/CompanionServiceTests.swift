import Foundation
import Network
import XCTest
@testable import MacHelper

final class CompanionServiceTests: XCTestCase {
    private let first = CompanionService.Route(extensionID: "com.example.first", companionID: String(repeating: "a", count: 32))
    private let second = CompanionService.Route(extensionID: "com.example.second", companionID: String(repeating: "b", count: 32))

    @MainActor func testOnlyRetainedRouteClaimsAndAuthorizedCommandsAreAccepted() async throws {
        var samples: [String] = []
        let (service, directory) = makeService(authorize: { route, generation, command in
            route == self.first && generation == "active" && (command == nil || command == "process")
        }, invoke: { route, generation, command, payload in
            XCTAssertEqual(route, self.first)
            XCTAssertEqual(generation, "active")
            XCTAssertEqual(command, "process")
            samples.append(payload)
            return payload
        })

        let endpoint = directory.appendingPathComponent("endpoint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        service.setRoutes([first: nil])
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        service.setRoutes([first: nil])
        let socket = try await publishedSocket(in: directory)
        let watcher = open(socket)
        defer { watcher.cancel() }
        try await send(watch(first), to: watcher)
        try await expectStatus(false, from: watcher)

        let disabled = try await exchange(invocation(first, payload: "text"), socket: socket)
        expectError("unavailable", in: disabled)
        service.setRoutes([first: "active"])
        try await expectStatus(true, from: watcher)
        let wrongSource = CompanionService.Route(extensionID: second.extensionID, companionID: first.companionID)
        let wrongCompanion = CompanionService.Route(extensionID: first.extensionID, companionID: second.companionID)
        for message in [watch(wrongSource), invocation(wrongCompanion, payload: "text"), invocation(first, command: "denied", payload: "text")] {
            let denied = try await exchange(message, socket: socket)
            expectError("unavailable", in: denied)
        }
        XCTAssertTrue(samples.isEmpty)

        let opaque = " {\"field\":\"数据\"}\n\0 "
        let result = try await exchange(invocation(first, payload: opaque), socket: socket)
        XCTAssertEqual(Set(result?.keys.map { $0 } ?? []), ["ok", "payload"])
        XCTAssertEqual(result?["ok"] as? Bool, true)
        XCTAssertEqual(result?["payload"] as? String, opaque)
        XCTAssertEqual(samples, [opaque])
    }

    @MainActor func testRevokingOneRoutePreservesOtherStatusSubscribers() async throws {
        let (service, directory) = makeService { _, _, _, value in value }
        service.setRoutes([first: "first", second: "second"])
        let socket = try await publishedSocket(in: directory)
        let firstWatcher = open(socket), secondWatcher = open(socket)
        defer { firstWatcher.cancel(); secondWatcher.cancel() }
        try await send(watch(first), to: firstWatcher)
        try await send(watch(second), to: secondWatcher)
        try await expectStatus(true, from: firstWatcher)
        try await expectStatus(true, from: secondWatcher)

        service.setRoutes([second: nil])
        let revoked = try await readMessage(from: firstWatcher)
        XCTAssertNil(revoked)
        try await expectStatus(false, from: secondWatcher)
        service.setRoutes([second: "next"])
        try await expectStatus(true, from: secondWatcher)
        let retainedSocket = try await publishedSocket(in: directory)
        XCTAssertEqual(retainedSocket, socket)

        service.setRoutes([:])
        let closed = try await readMessage(from: secondWatcher)
        XCTAssertNil(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("endpoint").path))
    }

    @MainActor func testBrowserRoutesKeepSharedChromiumIDsSeparateAndPublishConnectedStatus() async throws {
        let edge = CompanionService.Route(extensionID: first.extensionID, companionID: first.companionID, browser: .edge)
        let firefox = CompanionService.Route(extensionID: first.extensionID, companionID: "tool@example.com", browser: .firefox)
        let safari = CompanionService.Route(extensionID: first.extensionID, companionID: "com.example.tool.safari", browser: .safari)
        let (service, directory) = makeService { route, _, _, _ in route.browser.rawValue }
        var changes = 0
        service.onConnectivityChange = { changes += 1 }
        service.setRoutes([first: "active", firefox: "active", safari: "active"])
        let socket = try await publishedSocket(in: directory)
        let unapprovedEdge = try await exchange(invocation(edge, payload: "edge"), socket: socket)
        expectError("unavailable", in: unapprovedEdge)
        let legacy = try await exchange(invocation(first, payload: "chrome"), socket: socket)
        XCTAssertEqual(legacy?["payload"] as? String, "chrome")

        service.setRoutes([first: "active", edge: "active", firefox: "active", safari: "active"])
        for route in [edge, firefox, safari] {
            let result = try await exchange(invocation(route, payload: "text"), socket: socket)
            XCTAssertEqual(result?["payload"] as? String, route.browser.rawValue)
        }
        let edgeWatcher = open(socket), safariWatcher = open(socket)
        defer { edgeWatcher.cancel(); safariWatcher.cancel() }
        try await send(watch(edge), to: edgeWatcher)
        try await expectStatus(true, from: edgeWatcher)
        try await send(watch(safari), to: safariWatcher)
        try await expectStatus(true, from: safariWatcher)
        try await waitUntil { changes == 2 }
        XCTAssertTrue(service.isConnected(edge))
        XCTAssertTrue(service.isConnected(safari))
        XCTAssertFalse(service.isConnected(first))

        edgeWatcher.cancel()
        safariWatcher.cancel()
        try await waitUntil { !service.isConnected(edge) }
        XCTAssertTrue(service.isConnected(safari), "Safari's short status poll remains visible briefly after it completes.")
        service.setRoutes([first: "active", edge: "active", firefox: "active"])
        XCTAssertFalse(service.isConnected(safari), "Revoking a Safari route clears its remembered status immediately.")
        XCTAssertEqual(changes, 4)
    }

    @MainActor func testRejectsMalformedOrOversizedRequestsBeforeDispatch() async throws {
        var calls = 0
        let (service, directory) = makeService { _, _, _, value in calls += 1; return value }
        service.setRoutes([first: "active"])
        let socket = try await publishedSocket(in: directory)
        var invalid = [
            watch(first).merging(["payload": "unrequested"], uniquingKeysWith: { _, next in next }),
            invocation(first, command: "invalid\n", payload: "text"),
            invocation(first, payload: String(repeating: "x", count: CompanionService.maximumPayloadBytes + 1)),
            invocation(first, payload: "text").merging(["payload": ["not", "text"]], uniquingKeysWith: { _, next in next }),
            invocation(.init(extensionID: first.extensionID + "\n", companionID: first.companionID), payload: "text"),
            invocation(.init(extensionID: first.extensionID, companionID: "untrusted"), payload: "text"),
            invocation(first, payload: "text").merging(["browser": "untrusted"], uniquingKeysWith: { _, next in next }),
            invocation(first, payload: "text").merging(["browser": NSNull()], uniquingKeysWith: { _, next in next }),
            invocation(first, payload: "text").merging(["provider": "unrequested"], uniquingKeysWith: { _, next in next })
        ]
        invalid.append(["type": "invoke", "extension": first.extensionID, "companion": first.companionID, "payload": "missing command"])
        for message in invalid {
            let refused = try await exchange(message, socket: socket)
            expectError("invalid", in: refused)
        }
        let oversized = open(socket)
        defer { oversized.cancel() }
        var length = UInt32(CompanionService.maximumFrameBytes + 1).littleEndian
        try await send(withUnsafeBytes(of: &length) { Data($0) }, to: oversized)
        let refused = try await readMessage(from: oversized)
        expectError("invalid", in: refused)
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testEachSourceHasOneActiveInvocationAndGenerationReplacementCancelsIt() async throws {
        var starts = 0, cancellations = 0
        let alias = CompanionService.Route(extensionID: first.extensionID, companionID: second.companionID)
        let (service, directory) = makeService { _, _, _, payload in
            if payload == "block" {
                starts += 1
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancellations += 1; throw error }
            }
            return payload
        }
        service.setRoutes([first: "old", alias: "old", second: "active"])
        let socket = try await publishedSocket(in: directory)
        let blocked = Task { try await exchange(invocation(first, payload: "block"), socket: socket) }
        defer { blocked.cancel() }
        try await waitUntil { starts == 1 }
        let sameSource = try await exchange(invocation(alias, payload: "extra"), socket: socket)
        expectError("busy", in: sameSource)
        let differentSource = try await exchange(invocation(second, payload: "independent"), socket: socket)
        XCTAssertEqual(differentSource?["payload"] as? String, "independent")

        service.setRoutes([first: "new", alias: "new", second: "active"])
        try await waitUntil { cancellations == 1 }
        let stale = try await blocked.value
        XCTAssertNil(stale)
        let afterReplacement = Task { try await exchange(invocation(first, payload: "block"), socket: socket) }
        defer { afterReplacement.cancel() }
        try await waitUntil { starts == 2 }
        afterReplacement.cancel()
        _ = try? await afterReplacement.value
        try await waitUntil { cancellations == 2 }

        let beforeDisable = Task { try await exchange(invocation(first, payload: "block"), socket: socket) }
        defer { beforeDisable.cancel() }
        try await waitUntil { starts == 3 }
        service.setRoutes([first: nil, alias: nil, second: "active"])
        try await waitUntil { cancellations == 3 }
        let dropped = try await beforeDisable.value
        XCTAssertNil(dropped)
    }

    @MainActor func testStatusCapacityCannotExhaustInvocationAndExtraInputClosesWatcher() async throws {
        let (service, directory) = makeService { _, _, _, value in value }
        service.setRoutes([first: "active"])
        let socket = try await publishedSocket(in: directory)
        var watchers: [NWConnection] = []
        defer { watchers.forEach { $0.cancel() } }
        for _ in 0..<16 {
            let watcher = open(socket)
            watchers.append(watcher)
            try await send(watch(first), to: watcher)
            try await expectStatus(true, from: watcher)
        }
        let extraWatcher = try await exchange(watch(first), socket: socket)
        expectError("busy", in: extraWatcher)
        let available = try await exchange(invocation(first, payload: "valid"), socket: socket)
        XCTAssertEqual(available?["payload"] as? String, "valid")

        try await send(watch(first), to: watchers[0])
        let closed = try await readMessage(from: watchers[0])
        XCTAssertNil(closed)
        let replacement = open(socket)
        defer { replacement.cancel() }
        try await send(watch(first), to: replacement)
        try await expectStatus(true, from: replacement)
    }

    @MainActor func testRepliesKeepFixedErrorEnvelopeAndBoundEncodedOutput() async throws {
        struct TestError: Error {}
        let (service, directory) = makeService { _, _, _, value in
            switch value {
            case "raw": return String(repeating: "a", count: CompanionService.maximumPayloadBytes + 1)
            case "escaped": return String(repeating: "\0", count: CompanionService.maximumPayloadBytes)
            case "secret": throw TestError()
            default: throw CompanionService.Failure.invalid
            }
        }
        service.setRoutes([first: "active"])
        let socket = try await publishedSocket(in: directory)
        for payload in ["raw", "escaped", "secret"] {
            let failed = try await exchange(invocation(first, payload: payload), socket: socket)
            expectError("failed", in: failed)
        }
        let invalid = try await exchange(invocation(first, payload: "bad domain input"), socket: socket)
        expectError("invalid", in: invalid)
    }

    @MainActor private func makeService(authorize: @escaping CompanionService.Authorize = { _, _, _ in true },
                                       invoke: @escaping CompanionService.Invoke) -> (CompanionService, URL) {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mhc-\(UUID().uuidString)", isDirectory: true)
        let service = CompanionService(directory: directory, authorize: authorize, invoke: invoke)
        addTeardownBlock {
            await service.setRoutes([:])
            try? FileManager.default.removeItem(at: directory)
        }
        return (service, directory)
    }

    private func watch(_ route: CompanionService.Route) -> [String: Any] {
        var request = ["type": "watchStatus", "extension": route.extensionID, "companion": route.companionID]
        if route.browser != .chrome { request["browser"] = route.browser.rawValue }
        return request
    }

    private func invocation(_ route: CompanionService.Route, command: String = "process", payload: String) -> [String: Any] {
        var request = ["type": "invoke", "extension": route.extensionID, "companion": route.companionID, "command": command, "payload": payload]
        if route.browser != .chrome { request["browser"] = route.browser.rawValue }
        return request
    }

    @MainActor private func publishedSocket(in directory: URL) async throws -> URL {
        let endpoint = directory.appendingPathComponent("endpoint")
        try await waitUntil { FileManager.default.fileExists(atPath: endpoint.path) }
        let name = try String(contentsOf: endpoint, encoding: .utf8)
        XCTAssertNotNil(name.range(of: #"\A[0-9a-f]{32}\.sock\z"#, options: .regularExpression))
        return directory.appendingPathComponent(name)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func open(_ socket: URL) -> NWConnection {
        let network = NWConnection(to: .unix(path: socket.path), using: .tcp)
        network.start(queue: .global())
        return network
    }

    private func send(_ request: [String: Any], to network: NWConnection) async throws {
        let payload = try JSONSerialization.data(withJSONObject: request)
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try await send(frame, to: network)
    }

    private func send(_ data: Data, to network: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            network.send(content: data, completion: .contentProcessed { error in
                if let error { result.resume(throwing: error) }
                else { result.resume() }
            })
        }
    }

    private func exchange(_ request: [String: Any], socket: URL) async throws -> [String: Any]? {
        let network = open(socket)
        defer { network.cancel() }
        return try await withTaskCancellationHandler {
            try await send(request, to: network)
            return try await readMessage(from: network)
        } onCancel: {
            network.cancel()
        }
    }

    private func readMessage(from network: NWConnection) async throws -> [String: Any]? {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(3)); network.cancel() }
            catch { }
        }
        defer { deadline.cancel() }
        guard let header = try await receive(4, from: network), header.count == 4 else { return nil }
        let count = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard (1...CompanionService.maximumFrameBytes).contains(count), let data = try await receive(count, from: network) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func expectStatus(_ enabled: Bool, from network: NWConnection) async throws {
        let message = try await readMessage(from: network)
        let status = try XCTUnwrap(message)
        XCTAssertEqual(Set(status.keys), ["type", "enabled"])
        XCTAssertEqual(status["type"] as? String, "status")
        XCTAssertEqual(status["enabled"] as? Bool, enabled)
    }

    private func expectError(_ error: String, in reply: [String: Any]?) {
        XCTAssertEqual(Set(reply?.keys.map { $0 } ?? []), ["ok", "error"])
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, error)
    }

    private func receive(_ count: Int, from network: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            network.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data) }
            }
        }
    }
}
