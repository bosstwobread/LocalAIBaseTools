import Foundation
import XCTest
@testable import MessageHelperCore

final class LocalGPTProtocolTests: XCTestCase {
    func testMCPOverrideUsesValidatedUnquotedCLIKeySegments() throws {
        let arguments = try LocalGPTToolPolicy.arguments(disabledMCPServers: ["node_repl", "computer-use"])
        XCTAssertTrue(arguments.contains("mcp_servers.node_repl.enabled=false"))
        XCTAssertTrue(arguments.contains("mcp_servers.computer-use.enabled=false"))
        XCTAssertFalse(arguments.contains { $0.contains("mcp_servers.\"") })
        for invalid in ["", "name.with.dot", "quoted\"name", "path/name", "name\nnext", "中文"] {
            XCTAssertThrowsError(try LocalGPTToolPolicy.arguments(disabledMCPServers: [invalid]))
        }
    }

    func testDecoderPreservesSplitUnicodeAndMultipleLines() throws {
        let text = "{\"value\":\"问题🙂\"}\n{\"id\":7}\n"
        var decoder = LocalGPTLineDecoder()
        var result: [[String: Any]] = []
        for byte in text.utf8 { result += try decoder.append(Data([byte])) }
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["value"] as? String, "问题🙂")
        XCTAssertEqual(result[1]["id"] as? Int, 7)
        XCTAssertNoThrow(try decoder.finish())
    }

    func testDecoderRejectsMalformedTruncatedAndOversizedMessages() throws {
        var malformed = LocalGPTLineDecoder()
        XCTAssertThrowsError(try malformed.append(Data("not json\n".utf8)))
        var truncated = LocalGPTLineDecoder()
        _ = try truncated.append(Data("{\"id\":1}".utf8))
        XCTAssertThrowsError(try truncated.finish())
        var oversized = LocalGPTLineDecoder(maximumLineBytes: 5)
        XCTAssertThrowsError(try oversized.append(Data("123456".utf8)))
    }

    func testOtherThreadOrOldTurnCannotCompleteCurrentAnswer() throws {
        var accumulator = LocalGPTTurnAccumulator(threadID: "current", startedAt: 10)
        accumulator.turnID = "new"
        XCTAssertNil(try accumulator.receive(method: "turn/completed", params: completed(thread: "other", turn: "new"), now: 11, onDelta: { _ in XCTFail() }))
        XCTAssertNil(try accumulator.receive(method: "turn/completed", params: completed(thread: "current", turn: "old"), now: 11, onDelta: { _ in XCTFail() }))
    }

    func testCompletedAnswerExcludesCommentaryAndUsesAuthoritativeText() throws {
        var accumulator = LocalGPTTurnAccumulator(threadID: "thread", startedAt: 10)
        accumulator.turnID = "turn"
        var deltas: [String] = []
        _ = try accumulator.receive(method: "item/agentMessage/delta", params: [
            "threadId": "thread", "turnId": "turn", "itemId": "a", "delta": "Partial answer"
        ], now: 11.5, onDelta: { deltas.append($0) })
        let payload: [String: Any] = ["threadId": "thread", "turn": [
            "id": "turn", "status": "completed", "items": [
                ["type": "agentMessage", "id": "progress", "phase": "commentary", "text": "Thinking about it"],
                ["type": "agentMessage", "id": "answer", "phase": "final_answer", "text": "Confirmed final answer"]
            ]
        ]]
        let answer = try XCTUnwrap(accumulator.receive(method: "turn/completed", params: payload, now: 13, onDelta: { _ in }))
        XCTAssertEqual(deltas, ["Partial answer"])
        XCTAssertEqual(answer.text, "Confirmed final answer")
        XCTAssertEqual(answer.firstTextSeconds, 1.5)
        XCTAssertEqual(answer.completeSeconds, 3)
    }

    func testDeltaWithoutCompletedFinalMessageIsNotSuccess() throws {
        var accumulator = LocalGPTTurnAccumulator(threadID: "thread", startedAt: 10)
        accumulator.turnID = "turn"
        _ = try accumulator.receive(method: "item/agentMessage/delta", params: ["threadId": "thread", "turnId": "turn", "delta": "Not yet final"], now: 11, onDelta: { _ in })
        XCTAssertThrowsError(try accumulator.receive(method: "turn/completed", params: ["threadId": "thread", "turn": ["id": "turn", "status": "completed", "items": []]], now: 12, onDelta: { _ in })) {
            XCTAssertEqual($0 as? LocalGPTError, .emptyAnswer)
        }
    }

    func testFailedTurnAndToolItemsAreRejected() throws {
        var accumulator = LocalGPTTurnAccumulator(threadID: "thread", startedAt: 10)
        accumulator.turnID = "turn"
        XCTAssertThrowsError(try accumulator.receive(method: "turn/completed", params: ["threadId": "thread", "turn": ["id": "turn", "status": "failed", "items": [], "error": ["message": "Limit reached"]]], now: 12, onDelta: { _ in })) {
            XCTAssertEqual($0 as? LocalGPTError, .requestFailed("Limit reached"))
        }
        XCTAssertThrowsError(try accumulator.receive(method: "item/started", params: ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]], now: 12, onDelta: { _ in }))
    }

    func testItemCompletedSupportsTurnPayloadWithoutItems() throws {
        var accumulator = LocalGPTTurnAccumulator(threadID: "thread", startedAt: 10)
        accumulator.turnID = "turn"
        _ = try accumulator.receive(method: "item/completed", params: ["threadId": "thread", "turnId": "turn", "item": ["id": "a", "type": "agentMessage", "text": "Final result"]], now: 11, onDelta: { _ in })
        let result = try accumulator.receive(method: "turn/completed", params: ["threadId": "thread", "turn": ["id": "turn", "status": "completed", "items": []]], now: 12, onDelta: { _ in })
        XCTAssertEqual(result?.text, "Final result")
    }

    func testToolInCompletionPayloadCannotBeReportedAsSuccess() throws {
        var accumulator = LocalGPTTurnAccumulator(threadID: "thread", startedAt: 10)
        accumulator.turnID = "turn"
        XCTAssertThrowsError(try accumulator.receive(method: "turn/completed", params: [
            "threadId": "thread", "turn": ["id": "turn", "status": "completed", "items": [
                ["id": "a", "type": "agentMessage", "text": "Answer"],
                ["id": "tool", "type": "commandExecution"]
            ]]
        ], now: 12, onDelta: { _ in }))
    }

    private func completed(thread: String, turn: String) -> [String: Any] {
        ["threadId": thread, "turn": ["id": turn, "status": "completed", "items": [["id": "a", "type": "agentMessage", "text": "Answer"]]]]
    }
}

@MainActor
private final class MockLocalGPTTransport: LocalGPTTransport {
    var onBytes: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    var onTurn: (([String: Any]) throws -> Void)?
    var sent: [[String: Any]] = []
    var accountType = "chatgpt"
    var resumeID = "thread"
    var isOpen = false
    var configuredMCPServers: [String: [String: Any]] = [:]
    var disabledMCPHistory: [[String]] = []
    var bypassToolPolicy = false
    var bypassSandbox = false

    func start(workingDirectory: URL, disabledMCPServers: [String]) throws {
        isOpen = true
        disabledMCPHistory.append(disabledMCPServers)
        for name in disabledMCPServers { configuredMCPServers[name]?["enabled"] = false }
    }
    func close() { isOpen = false }
    func write(_ bytes: Data) throws {
        guard isOpen else { throw LocalGPTError.disconnected }
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        sent.append(request)
        guard let method = request["method"] as? String, let id = request["id"] else { return }
        switch method {
        case "initialize": try emit(["id": id, "result": [:]])
        case "account/read": try emit(["id": id, "result": ["account": ["type": accountType], "requiresOpenaiAuth": true]])
        case "config/read":
            let features = Dictionary(uniqueKeysWithValues: LocalGPTToolPolicy.disabledFeatures.map { ($0, bypassToolPolicy) })
            try emit(["id": id, "result": ["config": ["features": features, "web_search": "disabled", "mcp_servers": configuredMCPServers]]])
        case "thread/start", "thread/resume":
            try emit(["id": id, "result": ["thread": ["id": resumeID, "status": ["type": "idle"]], "model": "configured-model", "approvalPolicy": "never", "sandbox": ["type": bypassSandbox ? "dangerFullAccess" : "readOnly", "networkAccess": false]]])
        case "turn/start": try onTurn?(request)
        default: break
        }
    }

    func emit(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object)
        bytes.append(10)
        onBytes?(bytes)
    }
}

@MainActor
final class LocalGPTClientTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp")

    func testIdleEOFClearsConnectionAndNotifiesExactlyOnce() async throws {
        let mock = MockLocalGPTTransport()
        let client = LocalGPTClient(transport: mock)
        var reasons: [String] = []
        client.onDisconnected = { reasons.append($0) }
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        XCTAssertTrue(reasons.isEmpty)
        mock.onEnd?()
        XCTAssertNil(client.connection)
        XCTAssertEqual(reasons, [LocalGPTError.disconnected.localizedDescription])
        mock.onEnd?()
        await client.disconnect()
        XCTAssertEqual(reasons.count, 1)
    }

    func testConfiguredMCPServersAreDisabledBeforeCreatingConversation() async throws {
        let mock = MockLocalGPTTransport()
        mock.configuredMCPServers = ["computer-use": [:], "already-off": ["enabled": false]]
        let client = LocalGPTClient(transport: mock)
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        XCTAssertEqual(mock.disabledMCPHistory, [[], ["computer-use"]])
        XCTAssertEqual(mock.sent.filter { $0["method"] as? String == "thread/start" }.count, 1)
        await client.disconnect()
    }

    func testNewMessageStartsEphemeralConversationWithMessageHelperInstructions() async throws {
        let mock = MockLocalGPTTransport()
        let client = LocalGPTClient(transport: mock)
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        let request = try XCTUnwrap(mock.sent.first { $0["method"] as? String == "thread/start" })
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        let instructions = try XCTUnwrap(params["developerInstructions"] as? String)
        XCTAssertTrue(instructions.contains("MessageHelper"))
        XCTAssertTrue(instructions.contains("untrusted"))
        XCTAssertTrue(instructions.contains("prices"))
        await client.disconnect()
    }

    func testUnverifiedToolConfigurationFailsBeforeConversationCreation() async throws {
        let mock = MockLocalGPTTransport()
        mock.bypassToolPolicy = true
        let client = LocalGPTClient(transport: mock)
        do { _ = try await client.connect(threadID: nil, workingDirectory: directory); XCTFail() }
        catch { XCTAssertTrue(error is LocalGPTError) }
        XCTAssertFalse(mock.sent.contains { $0["method"] as? String == "thread/start" })
    }

    func testUnconfirmedSandboxCannotAcceptQuestions() async throws {
        let mock = MockLocalGPTTransport()
        mock.bypassSandbox = true
        let client = LocalGPTClient(transport: mock)
        do { _ = try await client.connect(threadID: nil, workingDirectory: directory); XCTFail() }
        catch { XCTAssertTrue(error is LocalGPTError) }
        XCTAssertNil(client.connection)
        XCTAssertFalse(mock.isOpen)
    }

    func testConnectResumesExactThreadAndDoesNotOverrideModel() async throws {
        let mock = MockLocalGPTTransport()
        let actual = LocalGPTClient(transport: mock)
        let connection = try await actual.connect(threadID: "thread", workingDirectory: directory)
        XCTAssertEqual(connection.threadID, "thread")
        XCTAssertEqual(connection.model, "configured-model")
        let resume = try XCTUnwrap(mock.sent.first { $0["method"] as? String == "thread/resume" })
        let params = try XCTUnwrap(resume["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thread")
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertNil(params["model"])
        await actual.disconnect()
    }

    func testMismatchedResumeIsRejectedWithoutStartingTurn() async throws {
        let mock = MockLocalGPTTransport()
        let actual = LocalGPTClient(transport: mock)
        do {
            _ = try await actual.connect(threadID: "different-thread", workingDirectory: directory)
            XCTFail("A different conversation must not be silently substituted")
        } catch { XCTAssertFalse(mock.isOpen) }
        XCTAssertFalse(mock.sent.contains { $0["method"] as? String == "turn/start" })
    }

    func testOnlyExistingChatGPTAuthenticationIsAccepted() async throws {
        let mock = MockLocalGPTTransport()
        mock.accountType = "apiKey"
        let client = LocalGPTClient(transport: mock)
        do { _ = try await client.connect(threadID: nil, workingDirectory: directory); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGPTError, .notAuthenticated) }
        XCTAssertFalse(mock.sent.contains { $0["method"] as? String == "thread/start" })
    }

    func testEventsBeforeTurnAcknowledgementAreCorrelatedAndCompleted() async throws {
        let mock = MockLocalGPTTransport()
        let client = LocalGPTClient(transport: mock)
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        let requestID = UUID()
        mock.onTurn = { request in
            XCTAssertEqual((request["params"] as? [String: Any])?["clientUserMessageId"] as? String, requestID.uuidString)
            try mock.emit(["method": "turn/completed", "params": self.completion(turn: "old", text: "Wrong answer")])
            try mock.emit(["method": "item/agentMessage/delta", "params": ["threadId": "thread", "turnId": "new", "itemId": "a", "delta": "你好"]])
            try mock.emit(["method": "turn/completed", "params": self.completion(turn: "new", text: "你好。Final answer.")])
            try mock.emit(["id": request["id"]!, "result": ["turn": ["id": "new", "status": "inProgress", "items": []]]])
        }
        let answer = try await client.answer(prompt: "Question?", requestID: requestID, onDelta: { _ in })
        XCTAssertEqual(answer.turnID, "new")
        XCTAssertEqual(answer.text, "你好。Final answer.")
        XCTAssertNotNil(answer.firstTextSeconds)
        XCTAssertEqual(mock.sent.filter { $0["method"] as? String == "turn/start" }.count, 1)
        await client.disconnect()
    }

    func testEOFDoesNotRetryUncertainSend() async throws {
        let mock = MockLocalGPTTransport()
        let actual = LocalGPTClient(transport: mock)
        _ = try await actual.connect(threadID: nil, workingDirectory: directory)
        mock.onTurn = { _ in mock.onEnd?() }
        do { _ = try await actual.answer(prompt: "Question?", requestID: UUID(), onDelta: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGPTError, .disconnected) }
        XCTAssertNil(actual.connection)
        XCTAssertEqual(mock.sent.filter { $0["method"] as? String == "turn/start" }.count, 1)
    }

    func testAlreadyFailedStartResponseDoesNotWaitForTimeout() async throws {
        let mock = MockLocalGPTTransport()
        let client = LocalGPTClient(transport: mock, requestTimeout: 30, answerTimeout: 120)
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        mock.onTurn = { request in
            try mock.emit(["id": request["id"]!, "result": ["turn": [
                "id": "failed-turn", "status": "failed", "items": [],
                "error": ["message": "Account limit reached"]
            ]]])
        }
        do { _ = try await client.answer(prompt: "Question?", requestID: UUID(), onDelta: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGPTError, .requestFailed("Account limit reached")) }
        XCTAssertFalse(mock.isOpen)
    }

    func testTimeoutFailsAndDoesNotRetry() async throws {
        let mock = MockLocalGPTTransport()
        let client = LocalGPTClient(transport: mock, requestTimeout: 0.05, answerTimeout: 0.1)
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        do { _ = try await client.answer(prompt: "Question?", requestID: UUID(), onDelta: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGPTError, .timeout) }
        XCTAssertEqual(mock.sent.filter { $0["method"] as? String == "turn/start" }.count, 1)
        XCTAssertFalse(mock.isOpen)
    }

    func testUnexpectedServerRequestIsRejectedAndConnectionClosed() async throws {
        let mock = MockLocalGPTTransport()
        let actual = LocalGPTClient(transport: mock)
        _ = try await actual.connect(threadID: nil, workingDirectory: directory)
        mock.onTurn = { _ in
            try mock.emit(["id": "approval", "method": "item/commandExecution/requestApproval", "params": [:]])
        }
        do { _ = try await actual.answer(prompt: "Question?", requestID: UUID(), onDelta: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error is LocalGPTError) }
        XCTAssertTrue(mock.sent.contains { $0["id"] as? String == "approval" && $0["error"] != nil })
        XCTAssertFalse(mock.isOpen)
    }

    func testTaskCancellationInterruptsMatchingTurnWithoutRetry() async throws {
        let mock = MockLocalGPTTransport()
        let client = LocalGPTClient(transport: mock)
        _ = try await client.connect(threadID: nil, workingDirectory: directory)
        mock.onTurn = { request in
            try mock.emit(["id": request["id"]!, "result": ["turn": ["id": "active-turn", "status": "inProgress", "items": []]]])
        }
        let answer = Task { try await client.answer(prompt: "Question?", requestID: UUID(), onDelta: { _ in }) }
        try await Task.sleep(nanoseconds: 30_000_000)
        answer.cancel()
        do { _ = try await answer.value; XCTFail() }
        catch { XCTAssertEqual(error as? LocalGPTError, .cancelled) }
        let interrupt = try XCTUnwrap(mock.sent.first { $0["method"] as? String == "turn/interrupt" })
        XCTAssertEqual((interrupt["params"] as? [String: Any])?["turnId"] as? String, "active-turn")
        XCTAssertFalse(mock.isOpen)
    }

    private func completion(turn: String, text: String) -> [String: Any] {
        ["threadId": "thread", "turn": ["id": turn, "status": "completed", "items": [["id": "a", "type": "agentMessage", "phase": "final_answer", "text": text]]]]
    }
}
