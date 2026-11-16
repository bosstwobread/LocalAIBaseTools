import Foundation
import XCTest
@testable import MacHelper

private final class StreamingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, String)] = []
    private var finished = false
    let firstDelta: XCTestExpectation
    init(_ expectation: XCTestExpectation) { firstDelta = expectation }
    func append(_ text: String, model: String) {
        XCTAssertTrue(Thread.isMainThread, "Provider deltas must remain ordered on the main actor")
        lock.lock(); let first = values.isEmpty; values.append((text, model)); lock.unlock()
        if first { firstDelta.fulfill() }
    }
    func complete() { lock.lock(); finished = true; lock.unlock() }
    var state: (deltas: [String], models: [String], finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (values.map { $0.0 }, values.map { $0.1 }, finished)
    }
}

private final class StreamingFixture: @unchecked Sendable {
    let provider: AIProvider
    let initial: [Data]
    let tail: [Data]
    let hold: Bool
    let queue = DispatchQueue(label: "MacHelperTests.streaming-fixture")
    private var pending: StreamingProviderURLProtocol?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    init(provider: AIProvider, initial: Data, tail: Data = Data(), hold: Bool = false, fragmented: Bool = false) {
        self.provider = provider; self.hold = hold
        self.initial = fragmented ? initial.map { Data([$0]) } : [initial]
        self.tail = tail.isEmpty ? [] : [tail]
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func serve(_ item: StreamingProviderURLProtocol) {
        var request = item.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close(); request.httpBody = body
        }
        lock.lock(); recorded.append(request); lock.unlock()
        queue.async {
            if item.request.httpMethod == "GET" {
                let catalog: [String: Any] = self.provider == .ollama
                    ? ["models": [["model": "selected-model"]]] : ["data": [["id": "selected-model"]]]
                item.respond(contentType: "application/json")
                item.send(try! JSONSerialization.data(withJSONObject: catalog))
                item.finish()
            } else {
                item.respond(contentType: self.provider == .ollama ? "application/x-ndjson" : "text/event-stream")
                self.initial.forEach { item.send($0) }
                if self.hold { self.pending = item }
                else { self.tail.forEach { item.send($0) }; item.finish() }
            }
        }
    }
    func release() {
        queue.async {
            guard let item = self.pending else { return }
            self.pending = nil
            self.tail.forEach { item.send($0) }; item.finish()
        }
    }
}

private final class StreamingProviderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let fixtureLock = NSLock()
    private static var selected: StreamingFixture?
    private let stateLock = NSLock()
    private var stopped = false
    static func configure(_ fixture: StreamingFixture) { fixtureLock.lock(); selected = fixture; fixtureLock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.fixtureLock.lock(); let fixture = Self.selected; Self.fixtureLock.unlock()
        fixture?.serve(self)
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    private var maySend: Bool { stateLock.lock(); defer { stateLock.unlock() }; return !stopped }
    func respond(contentType: String) {
        guard maySend else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func send(_ bytes: Data) { if maySend { client?.urlProtocol(self, didLoad: bytes) } }
    func finish() { if maySend { client?.urlProtocolDidFinishLoading(self) } }
}

@MainActor
private final class StreamingChatGPTTransport: LocalGPTTransport {
    var onBytes: ((Data) -> Void)?
    var onEnd: (() -> Void)?
    var sent: [[String: Any]] = []
    func start(workingDirectory: URL, disabledMCPServers: [String]) throws {}
    func close() {}
    func write(_ data: Data) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sent.append(object)
        guard let id = object["id"], let method = object["method"] as? String else { return }
        let result: [String: Any]
        switch method {
        case "initialize": result = [:]
        case "account/read": result = ["account": ["type": "chatgpt"]]
        case "config/read": result = ["config": [
            "features": Dictionary(uniqueKeysWithValues: LocalGPTToolPolicy.disabledFeatures.map { ($0, false) }),
            "web_search": "disabled", "mcp_servers": [:], "model": "selected-model"
        ]]
        case "model/list": result = ["data": [["model": "selected-model", "displayName": "Selected", "isDefault": true, "supportedReasoningEfforts": []]]]
        case "thread/start": result = ["thread": ["id": "thread", "status": ["type": "idle"]], "model": "selected-model",
                                       "approvalPolicy": "never", "sandbox": ["type": "readOnly", "networkAccess": false]]
        case "turn/start": result = ["turn": ["id": "turn"]]
        default: XCTFail("Unexpected model transport operation: \(method)"); return
        }
        try emit(["id": id, "result": result])
        if method == "turn/start" {
            for delta in ["你好🙂", " second"] {
                try emit(["method": "item/agentMessage/delta", "params": ["threadId": "thread", "turnId": "turn", "itemId": "answer", "delta": delta]])
            }
        }
    }
    func finish() throws {
        try emit(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "completed",
            "items": [["id": "answer", "type": "agentMessage", "phase": "final_answer", "text": "你好🙂 second"]]]]])
    }
    private func emit(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10); onBytes?(bytes)
    }
}

@MainActor
final class AIProviderStreamingTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp")

    func testChatGPTForwardsOrderedRawDeltasBeforeItsConfirmedFinalAnswer() async throws {
        let transport = StreamingChatGPTTransport()
        let subject = AIProviderClient(chatGPTClient: LocalGPTClient(transport: transport))
        let capture = StreamingCapture(expectation(description: "ChatGPT delta before completion"))
        let operation = Task {
            defer { capture.complete() }
            return try await subject.answer(request: request(), workingDirectory: directory,
                settings: HelperSettings(model: "selected-model"), onDelta: { capture.append($0, model: $1) })
        }
        await fulfillment(of: [capture.firstDelta], timeout: 2)
        XCTAssertFalse(capture.state.finished)
        XCTAssertEqual(capture.state.deltas, ["你好🙂", " second"])
        try transport.finish()
        let result = try await operation.value
        XCTAssertEqual(result, AIProviderAnswer(text: "你好🙂 second", model: "selected-model"))
        XCTAssertEqual(capture.state.models, ["selected-model", "selected-model"])
    }

    func testChatGPTStreamsWithOnlyTheExactExtensionSystemPromptAndLiteralUserText() async throws {
        let transport = StreamingChatGPTTransport()
        let subject = AIProviderClient(chatGPTClient: LocalGPTClient(transport: transport))
        let capture = StreamingCapture(expectation(description: "Literal prompt delta before completion"))
        let system = " \nExtension prompt e\u{0301} 中文🙂\n\t  "
        let text = " \t{\"source\":\"original text\"}\n\n🙂  "
        let operation = Task {
            try await subject.answer(request: HelperRequest(id: "literal", action: .translate, text: text,
                targetLanguage: "ja", tone: "friendly", guidance: "Do not append legacy guidance.", systemPrompt: system),
                workingDirectory: directory, settings: HelperSettings(model: "selected-model"),
                onDelta: { capture.append($0, model: $1) })
        }
        await fulfillment(of: [capture.firstDelta], timeout: 2)
        let start = try XCTUnwrap(transport.sent.first { $0["method"] as? String == "thread/start" })
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(Array(try XCTUnwrap(params["developerInstructions"] as? String).utf8), Array(system.utf8))
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        let turn = try XCTUnwrap(transport.sent.first { $0["method"] as? String == "turn/start" })
        let input = try XCTUnwrap((turn["params"] as? [String: Any])?["input"] as? [[String: String]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(input[0]["text"]).utf8), Array(text.utf8))
        XCTAssertEqual(capture.state.deltas, ["你好🙂", " second"])
        try transport.finish()
        let result = try await operation.value
        XCTAssertEqual(result, AIProviderAnswer(text: "你好🙂 second", model: "selected-model"))
    }

    func testBothProvidersDeliverFragmentedUnicodeBeforeResponseCompletion() async throws {
        for provider in [AIProvider.ollama, .lmStudio] {
            let fixture = StreamingFixture(provider: provider,
                initial: try frame(provider, text: "你好🙂") + frame(provider, text: " second"),
                tail: try terminal(provider), hold: true, fragmented: true)
            let subject = client(fixture)
            let capture = StreamingCapture(expectation(description: "First \(provider.rawValue) delta before EOF"))
            let operation = Task {
                defer { capture.complete() }
                return try await subject.answer(request: request(), workingDirectory: directory,
                    settings: settings(provider), onDelta: { capture.append($0, model: $1) })
            }
            await fulfillment(of: [capture.firstDelta], timeout: 3)
            XCTAssertFalse(capture.state.finished, "A streamed delta must arrive before terminal completion")
            fixture.release()
            let result = try await operation.value
            XCTAssertEqual(result, AIProviderAnswer(text: "你好🙂 second", model: "selected-model"))
            XCTAssertEqual(capture.state.deltas, ["你好🙂", " second"])
            XCTAssertEqual(capture.state.models, ["selected-model", "selected-model"])
            XCTAssertEqual(fixture.requests.filter { $0.httpMethod == "POST" }.count, 1)
            let generated = try XCTUnwrap(fixture.requests.last { $0.httpMethod == "POST" })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(generated.httpBody)) as? [String: Any])
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["model"] as? String, "selected-model")
            XCTAssertNil(body["tools"])
            XCTAssertNil(body["functions"])
        }
    }

    func testCancellationStopsAnOpenStreamingRequest() async throws {
        for provider in [AIProvider.ollama, .lmStudio] {
            let fixture = StreamingFixture(provider: provider, initial: try frame(provider, text: "partial"), hold: true)
            let subject = client(fixture)
            let capture = StreamingCapture(expectation(description: "Delta before cancellation"))
            let operation = Task {
                try await subject.answer(request: request(), workingDirectory: directory, settings: settings(provider),
                    onDelta: { capture.append($0, model: $1) })
            }
            await fulfillment(of: [capture.firstDelta], timeout: 3)
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Cancelled streams must not succeed") }
            catch { XCTAssertEqual(error as? LocalGPTError, .cancelled) }
            fixture.release()
        }
    }

    func testLiteralPromptsRemainUnchangedWhileStreamingAndCancellingLocalProviders() async throws {
        let system = " \nExact e\u{0301} prompt 中文🙂\n\t  "
        let text = " \tLiteral data\n{\"word\":\"ready\"}\n  "
        for provider in [AIProvider.ollama, .lmStudio] {
            let fixture = StreamingFixture(provider: provider, initial: try frame(provider, text: "partial"), hold: true)
            let subject = client(fixture)
            let capture = StreamingCapture(expectation(description: "Literal \(provider.rawValue) delta before cancellation"))
            let operation = Task {
                try await subject.answer(request: HelperRequest(id: "literal", action: .polish, text: text,
                    guidance: "Ignored legacy guidance", systemPrompt: system), workingDirectory: directory, settings: settings(provider),
                    onDelta: { capture.append($0, model: $1) })
            }
            await fulfillment(of: [capture.firstDelta], timeout: 3)
            let generated = try XCTUnwrap(fixture.requests.last { $0.httpMethod == "POST" })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(generated.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(Array(try XCTUnwrap(messages[0]["content"]).utf8), Array(system.utf8))
            XCTAssertEqual(Array(try XCTUnwrap(messages[1]["content"]).utf8), Array(text.utf8))
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertNil(body["tools"])
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Cancelled literal-prompt streams must not succeed") }
            catch { XCTAssertEqual(error as? LocalGPTError, .cancelled) }
            fixture.release()
            XCTAssertEqual(capture.state.deltas, ["partial"])
        }
    }

    func testDisconnectCancelsOpenProviderStream() async throws {
        let fixture = StreamingFixture(provider: .ollama, initial: try frame(.ollama, text: "partial"), hold: true)
        let subject = client(fixture)
        let capture = StreamingCapture(expectation(description: "Delta before disconnect"))
        let operation = Task {
            try await subject.answer(request: request(), workingDirectory: directory, settings: settings(.ollama),
                onDelta: { capture.append($0, model: $1) })
        }
        await fulfillment(of: [capture.firstDelta], timeout: 3)
        await subject.disconnect()
        do { _ = try await operation.value; XCTFail("Disconnected streams must not succeed") }
        catch { XCTAssertEqual(error as? LocalGPTError, .cancelled) }
        fixture.release()
    }

    func testMissingFinalMarkersMalformedJSONAndUTF8AreRejected() async throws {
        for provider in [AIProvider.ollama, .lmStudio] {
            let partial = try frame(provider, text: "partial")
            let malformed = Data((provider == .ollama ? "{broken\n" : "data: {broken\n\n").utf8)
            var invalidUTF8 = Data((provider == .ollama ? "{\"model\":\"" : "data: {\"model\":\"").utf8)
            invalidUTF8.append(contentsOf: [0xF0, 0x9F])
            invalidUTF8.append(Data((provider == .ollama ? "\"}\n" : "\"}\n\n").utf8))
            for body in [partial, malformed, invalidUTF8] {
                await assertInvalid(provider, body: body)
            }
            if provider == .lmStudio {
                await assertInvalid(provider, body: partial + (try terminal(provider, includeDone: false)))
                await assertInvalid(provider, body: partial + Data("data: [DONE]\n\n".utf8))
            }
        }
    }

    func testModelMismatchToolRequestsAndTruncatedFinishReasonsFail() async throws {
        for provider in [AIProvider.ollama, .lmStudio] {
            let wrongModel = try frame(provider, text: "unsafe", model: "different-model") + terminal(provider)
            let tool = try frame(provider, text: "unsafe", tool: true) + terminal(provider)
            let truncated = try frame(provider, text: "partial") + terminal(provider, reason: "length")
            let serviceError = try encoded(provider, object: ["error": "Do not expose sensitive server details"])
            for body in [wrongModel, tool, truncated, serviceError] { await assertInvalid(provider, body: body) }
        }
    }

    func testBoundedAnswerAndEmptyFinalTextAreRejected() async throws {
        for provider in [AIProvider.ollama, .lmStudio] {
            let tooLong = try frame(provider, text: String(repeating: "x", count: 50_000))
                + frame(provider, text: String(repeating: "y", count: 50_000)) + terminal(provider)
            await assertInvalid(provider, body: tooLong)
            await assertInvalid(provider, body: try frame(provider, text: " \n") + terminal(provider))
        }
    }

    private func assertInvalid(_ provider: AIProvider, body: Data, file: StaticString = #filePath, line: UInt = #line) async {
        let subject = client(StreamingFixture(provider: provider, initial: body))
        do {
            _ = try await subject.answer(request: request(), workingDirectory: directory, settings: settings(provider), onDelta: { _, _ in })
            XCTFail("Malformed or incomplete streams must fail", file: file, line: line)
        } catch {
            guard let providerError = error as? AIProviderError, case .invalidResponse = providerError else {
                XCTFail("Expected an invalid streaming response, received \(error)", file: file, line: line); return
            }
        }
    }
    private func client(_ fixture: StreamingFixture) -> AIProviderClient {
        StreamingProviderURLProtocol.configure(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingProviderURLProtocol.self]
        return AIProviderClient(session: URLSession(configuration: configuration))
    }
    private func request() -> HelperRequest { HelperRequest(id: "stream", action: .translate, text: "Synthetic public text") }
    private func settings(_ provider: AIProvider) -> HelperSettings { HelperSettings(provider: provider, model: "selected-model") }
    private func encoded(_ provider: AIProvider, object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return provider == .ollama ? json + Data("\n".utf8) : Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
    private func frame(_ provider: AIProvider, text: String, model: String = "selected-model", tool: Bool = false) throws -> Data {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if tool { message["tool_calls"] = [["function": ["name": "run"]]] }
        if provider == .ollama { return try encoded(provider, object: ["model": model, "message": message, "done": false]) }
        return try encoded(provider, object: ["model": model, "choices": [["index": 0, "delta": message, "finish_reason": NSNull()]]])
    }
    private func terminal(_ provider: AIProvider, reason: String = "stop", includeDone: Bool = true) throws -> Data {
        if provider == .ollama {
            return try encoded(provider, object: ["model": "selected-model", "message": ["role": "assistant", "content": ""], "done": true, "done_reason": reason])
        }
        let final = try encoded(provider, object: ["model": "selected-model", "choices": [["index": 0, "delta": [:], "finish_reason": reason]]])
        return final + (includeDone ? Data("data: [DONE]\n\n".utf8) : Data())
    }
}
