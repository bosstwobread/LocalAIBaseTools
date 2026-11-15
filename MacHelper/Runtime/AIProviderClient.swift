import Foundation
import CoreFoundation

public struct AIProviderAnswer: Sendable, Equatable {
    public let text: String
    public let model: String
}

public enum AIProviderError: LocalizedError, Equatable {
    case modelRequired
    case modelUnavailable
    case invalidResponse(String)
    case httpStatus(Int)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelRequired:
            return "Open MacHelper Settings, refresh models, and choose a model for this provider."
        case .modelUnavailable:
            return "The selected model is no longer available. Refresh models in MacHelper Settings and choose another model."
        case .invalidResponse(let detail):
            return "The local AI service returned an invalid response: \(detail)"
        case .httpStatus(let status):
            return "The local AI service returned HTTP \(status). Check that its local server is running and the selected model is ready."
        case .unavailable(let provider):
            return "Could not connect to \(provider). Start its local server on this Mac and check the address in MacHelper Settings."
        }
    }
}

/// One answer-only interface for installed AI services. No provider fallback is implicit.
@MainActor
public final class AIProviderClient {
    private let chatGPTClient: LocalGPTClient
    private let session: URLSession
    private var pendingHTTP: Task<(Data, HTTPURLResponse), Error>?
    private var pendingStream: Task<AIProviderAnswer, Error>?
    private var isBusy = false
    private static let maximumResponseBytes = 2 * 1024 * 1024
    private static let maximumAnswerBytes = 96 * 1024
    private static let maximumModels = 256

    /// A supplied session contributes its configuration (including test URL protocols),
    /// while redirects, cookies, credentials, proxies, and caching remain disabled.
    public init(session: URLSession = .shared, chatGPTClient: LocalGPTClient? = nil) {
        self.chatGPTClient = chatGPTClient ?? LocalGPTClient()
        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration,
                                  delegate: RefuseAIRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func listModels(workingDirectory: URL, settings: HelperSettings) async throws -> LocalGPTModelCatalog {
        guard !isBusy else { throw LocalGPTError.busy }
        isBusy = true
        defer { isBusy = false }
        let settings = try settings.validated()
        if settings.provider == .chatGPT {
            let catalog = try await chatGPTClient.listModels(workingDirectory: workingDirectory)
            guard !settings.model.isEmpty else { return catalog }
            let models = catalog.models.map {
                LocalGPTModel(model: $0.model, displayName: $0.displayName,
                              isDefault: $0.model == settings.model,
                              defaultReasoningEffort: $0.defaultReasoningEffort,
                              supportedReasoningEfforts: $0.supportedReasoningEfforts)
            }
            return LocalGPTModelCatalog(models: models, defaultModel: settings.model)
        }
        return try await localModels(settings: settings)
    }

    /// Raw provider deltas are delivered synchronously in order on the main
    /// actor. They remain provisional until the terminal answer succeeds.
    public func answer(request: HelperRequest, workingDirectory: URL,
                       settings: HelperSettings,
                       onDelta: (@Sendable (String, String) -> Void)? = nil) async throws -> AIProviderAnswer {
        guard !isBusy else { throw LocalGPTError.busy }
        isBusy = true
        defer { isBusy = false }
        try request.validate()
        guard request.action == .translate || request.action == .polish else {
            throw AIProviderError.invalidResponse("Only translation and English editing requests can generate text.")
        }
        let settings = try settings.validated()
        let selectedModel = request.model?.isEmpty == false ? request.model! : settings.model
        let prompt = try request.prompt()
        if settings.provider == .chatGPT {
            do {
                let connection = try await chatGPTClient.connect(threadID: nil, workingDirectory: workingDirectory,
                                                                model: selectedModel)
                // LocalGPTClient delivers callbacks synchronously on this actor.
                // Forward directly so the terminal response cannot overtake a delta.
                let answer = try await chatGPTClient.answer(prompt: prompt, requestID: UUID(), onDelta: { delta in
                    onDelta?(delta, connection.model)
                })
                await chatGPTClient.disconnect()
                return AIProviderAnswer(text: answer.text, model: connection.model)
            } catch {
                await chatGPTClient.disconnect()
                throw error
            }
        }

        guard !selectedModel.isEmpty else { throw AIProviderError.modelRequired }
        let catalog = try await localModels(settings: settings)
        guard catalog.models.contains(where: { $0.model == selectedModel }) else {
            throw AIProviderError.modelUnavailable
        }
        let body: [String: Any] = [
            "model": selectedModel,
            "stream": onDelta != nil,
            "messages": [
                ["role": "system", "content": LocalGPTClient.answerInstructions],
                ["role": "user", "content": prompt]
            ]
        ]
        // No tools, function definitions, or commands are sent to any provider.
        let path = settings.provider == .ollama ? "api/chat" : "chat/completions"
        if let onDelta {
            return try await streamAnswer(settings: settings, path: path, body: body,
                                          selectedModel: selectedModel, onDelta: onDelta)
        }
        let response = try await send(settings: settings, path: path, body: body)
        let text = try Self.answerText(response, provider: settings.provider, selectedModel: selectedModel)
        return AIProviderAnswer(text: text, model: selectedModel)
    }

    public func disconnect() async {
        pendingHTTP?.cancel()
        pendingStream?.cancel()
        await chatGPTClient.disconnect()
    }

    private func localModels(settings: HelperSettings) async throws -> LocalGPTModelCatalog {
        let path = settings.provider == .ollama ? "api/tags" : "models"
        let response = try await send(settings: settings, path: path)
        let key = settings.provider == .ollama ? "models" : "data"
        guard let entries = response[key] as? [[String: Any]], entries.count <= Self.maximumModels else {
            throw AIProviderError.invalidResponse("The model catalog is missing or exceeds its size limit.")
        }
        var seen = Set<String>()
        var models: [LocalGPTModel] = []
        for entry in entries {
            let identifier: String?
            if settings.provider == .ollama {
                identifier = (entry["model"] as? String) ?? (entry["name"] as? String)
            } else {
                identifier = entry["id"] as? String
            }
            guard let identifier, LocalGPTModel.validIdentifier(identifier), seen.insert(identifier).inserted else {
                throw AIProviderError.invalidResponse("The model catalog contains invalid or duplicate model IDs.")
            }
            models.append(LocalGPTModel(model: identifier, displayName: identifier,
                                        isDefault: identifier == settings.model,
                                        defaultReasoningEffort: nil, supportedReasoningEfforts: []))
        }
        // An empty catalog is valid when the user has not yet downloaded a model.
        let selected = models.contains(where: { $0.model == settings.model }) ? settings.model : nil
        return LocalGPTModelCatalog(models: models, defaultModel: selected)
    }

    private func send(settings: HelperSettings, path: String,
                      body: [String: Any]? = nil) async throws -> [String: Any] {
        let request = try Self.httpRequest(settings: settings, path: path, body: body)
        let url = request.url!
        let maximumBytes = Self.maximumResponseBytes
        let task = Task.detached(priority: .userInitiated) { [session] () throws -> (Data, HTTPURLResponse) in
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw AIProviderError.invalidResponse("An HTTP response was not received.")
            }
            guard response.url == url else {
                throw AIProviderError.invalidResponse("The service changed its local address.")
            }
            guard (200...299).contains(response.statusCode) else {
                throw AIProviderError.httpStatus(response.statusCode)
            }
            guard response.expectedContentLength <= maximumBytes else {
                throw AIProviderError.invalidResponse("The response exceeds its size limit.")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw AIProviderError.invalidResponse("The response exceeds its size limit.")
                }
                data.append(byte)
            }
            return (data, response)
        }
        pendingHTTP = task
        defer { pendingHTTP = nil }
        do {
            let (data, _) = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["error"] == nil else {
                throw AIProviderError.invalidResponse("Expected a JSON object without a service error.")
            }
            return response
        } catch let error as AIProviderError {
            throw error
        } catch is CancellationError {
            throw LocalGPTError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LocalGPTError.cancelled
        } catch {
            throw AIProviderError.unavailable(settings.provider.displayName)
        }
    }

    private static func httpRequest(settings: HelperSettings, path: String,
                                    body: [String: Any]?, streaming: Bool = false) throws -> URLRequest {
        var base = URL(string: settings.baseURL)!
        if settings.provider == .lmStudio, base.lastPathComponent != "v1" { base.appendPathComponent("v1", isDirectory: true) }
        let url = path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url)
        request.setValue(streaming && settings.provider == .lmStudio ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func streamAnswer(settings: HelperSettings, path: String, body: [String: Any],
                              selectedModel: String,
                              onDelta: @escaping @Sendable (String, String) -> Void) async throws -> AIProviderAnswer {
        let request = try Self.httpRequest(settings: settings, path: path, body: body, streaming: true)
        let maximumBytes = Self.maximumResponseBytes
        let task = Task.detached(priority: .userInitiated) { [session] () throws -> AIProviderAnswer in
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == request.url else {
                throw AIProviderError.invalidResponse("The service changed its local address.")
            }
            guard (200...299).contains(response.statusCode) else { throw AIProviderError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= maximumBytes else {
                throw AIProviderError.invalidResponse("The response exceeds its size limit.")
            }
            var parser = ProviderStreamParser(provider: settings.provider, model: selectedModel)
            for try await byte in bytes {
                try Task.checkCancellation()
                let deltas = try parser.append(byte)
                for delta in deltas {
                    try await MainActor.run { try Task.checkCancellation(); onDelta(delta, selectedModel) }
                }
                if parser.isComplete { break }
            }
            try Task.checkCancellation()
            // A final NDJSON object without its optional trailing newline is valid.
            for delta in try parser.finish() {
                try await MainActor.run { try Task.checkCancellation(); onDelta(delta, selectedModel) }
            }
            return AIProviderAnswer(text: parser.text, model: selectedModel)
        }
        pendingStream = task
        defer { pendingStream = nil }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch let error as AIProviderError { throw error }
        catch is CancellationError { throw LocalGPTError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw LocalGPTError.cancelled }
        catch { throw AIProviderError.unavailable(settings.provider.displayName) }
    }

    private static func answerText(_ response: [String: Any], provider: AIProvider,
                                   selectedModel: String) throws -> String {
        guard response["model"] as? String == selectedModel else {
            throw AIProviderError.invalidResponse("The service did not confirm the selected model.")
        }
        let message: [String: Any]
        if provider == .ollama {
            guard response["done"] as? Bool == true,
                  let value = response["message"] as? [String: Any],
                  response["done_reason"] == nil || response["done_reason"] as? String == "stop" else {
                throw AIProviderError.invalidResponse("The answer was not completed.")
            }
            message = value
        } else {
            guard let choices = response["choices"] as? [[String: Any]], choices.count == 1,
                  choices[0]["finish_reason"] as? String == "stop",
                  let value = choices[0]["message"] as? [String: Any] else {
                throw AIProviderError.invalidResponse("The answer was not completed.")
            }
            message = value
        }
        guard message["role"] as? String == "assistant",
              message["function_call"] == nil || message["function_call"] is NSNull,
              message["tool_calls"] == nil || message["tool_calls"] is NSNull || (message["tool_calls"] as? [Any])?.isEmpty == true,
              message["refusal"] == nil || message["refusal"] is NSNull,
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumAnswerBytes, !text.contains("\0") else {
            throw AIProviderError.invalidResponse("Expected a bounded final text answer without tool requests.")
        }
        return text
    }
}

/// Incremental byte framing avoids decoding incomplete UTF-8 scalars. Limits
/// apply to the whole stream, each line/event, and the final accumulated answer.
private struct ProviderStreamParser {
    let provider: AIProvider
    let model: String
    private(set) var text = ""
    private(set) var isComplete = false
    private var line = Data()
    private var eventData = Data()
    private var receivedBytes = 0
    private var answerBytes = 0
    private var finishedChoice = false
    private var assistantRole = false
    private let maximumEventBytes = 128 * 1024

    init(provider: AIProvider, model: String) { self.provider = provider; self.model = model }

    mutating func append(_ byte: UInt8) throws -> [String] {
        receivedBytes += 1
        guard receivedBytes <= 2 * 1024 * 1024, line.count < maximumEventBytes else { throw invalid("The stream exceeds its size limit.") }
        if byte != 10 { line.append(byte); return [] }
        return try consumeLine()
    }

    mutating func finish() throws -> [String] {
        var deltas: [String] = []
        if !line.isEmpty { deltas += try consumeLine() }
        if provider == .lmStudio, !eventData.isEmpty { deltas += try consumeEvent() }
        guard isComplete, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("The streamed answer was interrupted or not completed.")
        }
        return deltas
    }

    private mutating func consumeLine() throws -> [String] {
        if line.last == 13 { line.removeLast() }
        let bytes = line; line.removeAll(keepingCapacity: true)
        guard let value = String(data: bytes, encoding: .utf8) else { throw invalid("The stream is not valid UTF-8.") }
        if provider == .ollama {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
            return try consumeJSON(bytes)
        }
        if value.isEmpty { return try consumeEvent() }
        if value.hasPrefix(":") { return [] }
        // Only data fields carry completion payloads. Standard SSE metadata
        // fields (event/id/retry) are intentionally not interpreted as text.
        if value == "data" || value.hasPrefix("data:") {
            var content = value == "data" ? "" : String(value.dropFirst(5))
            if content.first == " " { content.removeFirst() }
            if !eventData.isEmpty { eventData.append(10) }
            eventData.append(Data(content.utf8))
            guard eventData.count <= maximumEventBytes else { throw invalid("A stream event exceeds its size limit.") }
        }
        return []
    }

    private mutating func consumeEvent() throws -> [String] {
        guard !eventData.isEmpty else { return [] }
        let data = eventData; eventData.removeAll(keepingCapacity: true)
        if data == Data("[DONE]".utf8) {
            guard finishedChoice else { throw invalid("The streamed answer was not completed.") }
            isComplete = true
            return []
        }
        return try consumeJSON(data)
    }

    private mutating func consumeJSON(_ data: Data) throws -> [String] {
        guard !isComplete, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil,
              object["model"] as? String == model else {
            throw invalid("Expected a stream event confirming the selected model without a service error.")
        }
        let delta: String
        if provider == .ollama {
            guard let done = Self.boolean(object["done"]), let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant", Self.safeMessage(message),
                  let content = message["content"] as? String else {
                throw invalid("Expected assistant text without tool requests.")
            }
            if done {
                guard object["done_reason"] == nil || object["done_reason"] as? String == "stop" else {
                    throw invalid("The streamed answer was not completed.")
                }
                isComplete = true
            }
            delta = content
        } else {
            guard !finishedChoice, let choices = object["choices"] as? [[String: Any]], choices.count == 1,
                  (choices[0]["index"] as? Int ?? 0) == 0,
                  let message = choices[0]["delta"] as? [String: Any], Self.safeMessage(message) else {
                throw invalid("Expected one assistant text choice without tool requests.")
            }
            if let role = message["role"] {
                guard role as? String == "assistant" else { throw invalid("The stream returned an unexpected role.") }
                assistantRole = true
            }
            guard assistantRole, message["content"] == nil || message["content"] is NSNull || message["content"] is String else {
                throw invalid("Expected assistant text content.")
            }
            if let reason = choices[0]["finish_reason"], !(reason is NSNull) {
                guard reason as? String == "stop" else { throw invalid("The streamed answer was not completed.") }
                finishedChoice = true
            }
            delta = message["content"] as? String ?? ""
        }
        guard !delta.contains("\0"), answerBytes + delta.utf8.count <= 96 * 1024 else {
            throw invalid("The streamed answer exceeds its text size limit or contains null characters.")
        }
        answerBytes += delta.utf8.count; text += delta
        return delta.isEmpty ? [] : [delta]
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func safeMessage(_ message: [String: Any]) -> Bool {
        (message["function_call"] == nil || message["function_call"] is NSNull) &&
        (message["tool_calls"] == nil || message["tool_calls"] is NSNull || (message["tool_calls"] as? [Any])?.isEmpty == true) &&
        (message["refusal"] == nil || message["refusal"] is NSNull)
    }
    private func invalid(_ detail: String) -> AIProviderError { .invalidResponse(detail) }
}

private final class RefuseAIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Even a local server cannot redirect a user's selected text to another host.
        completionHandler(nil)
    }
}
