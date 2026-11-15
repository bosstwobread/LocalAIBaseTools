import Foundation

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

    public func answer(request: HelperRequest, workingDirectory: URL,
                       settings: HelperSettings) async throws -> AIProviderAnswer {
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
                let answer = try await chatGPTClient.answer(prompt: prompt, requestID: UUID(), onDelta: { _ in })
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
            "stream": false,
            "messages": [
                ["role": "system", "content": LocalGPTClient.answerInstructions],
                ["role": "user", "content": prompt]
            ]
        ]
        // No tools, function definitions, or commands are sent to any provider.
        let path = settings.provider == .ollama ? "api/chat" : "chat/completions"
        let response = try await send(settings: settings, path: path, body: body)
        let text = try Self.answerText(response, provider: settings.provider, selectedModel: selectedModel)
        return AIProviderAnswer(text: text, model: selectedModel)
    }

    public func disconnect() async {
        pendingHTTP?.cancel()
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
        var base = URL(string: settings.baseURL)!
        if settings.provider == .lmStudio, base.lastPathComponent != "v1" {
            base.appendPathComponent("v1", isDirectory: true)
        }
        let url = path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let maximumBytes = Self.maximumResponseBytes
        let task = Task.detached(priority: .userInitiated) { [session] () throws -> (Data, HTTPURLResponse) in
            let (bytes, response) = try await session.bytes(for: request)
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

private final class RefuseAIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Even a local server cannot redirect a user's selected text to another host.
        completionHandler(nil)
    }
}
