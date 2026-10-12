import Foundation
import MessageHelperCore

@main
struct MessageHelperHost {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let allowedFile = binary.deletingLastPathComponent().appendingPathComponent("allowed-extension-ids.json")
            let allowedIDs: [String]
            if let data = try? Data(contentsOf: allowedFile), let values = try? JSONDecoder().decode([String].self, from: data) {
                allowedIDs = values
            } else {
                allowedIDs = ["fmhfobfddchbeibojepeocgfemkpcklo"]
            }
            try NativeHostOrigin.validate(arguments: CommandLine.arguments, allowedExtensionIDs: allowedIDs)
            let host = NativeHost()
            await host.run()
        } catch {
            // Native messaging stdout is reserved exclusively for framed JSON.
            try? FileHandle.standardError.write(contentsOf: Data("MessageHelper could not start: \(error.localizedDescription)\n".utf8))
        }
    }
}

@MainActor
private final class NativeHost {
    private let client = LocalGPTClient()
    private var decoder = NativeFrameDecoder()
    private var queue: [HelperRequest] = []
    private var activeTask: Task<Void, Never>?
    private var ended = false
    private var exitContinuation: CheckedContinuation<Void, Never>?
    private let workingDirectory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        workingDirectory = support.appendingPathComponent("MessageHelper/Runtime", isDirectory: true)
    }

    func run() async {
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return }
        await withCheckedContinuation { continuation in
            exitContinuation = continuation
            // File I/O occurs on Foundation's reader thread. Only bounded chunks and EOF
            // are dispatched to the actor; the main actor remains available for GPT events.
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async { [weak self] in self?.receive(bytes) }
            }
        }
    }

    private func receive(_ bytes: Data) {
        guard !ended else { return }
        if bytes.isEmpty {
            do { try decoder.finish() } catch { write(.init(id: "unknown", error: error.localizedDescription)) }
            end()
            return
        }
        do {
            for frame in try decoder.append(bytes) {
                let request: HelperRequest
                do {
                    request = try JSONDecoder().decode(HelperRequest.self, from: frame)
                    try request.validate()
                } catch {
                    let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
                    let id = object?["id"] as? String ?? "unknown"
                    let detail = error is DecodingError ? "The request must have a valid ID and supported action." : error.localizedDescription
                    write(.init(id: String(id.prefix(128)), error: detail))
                    continue
                }
                if request.action == .ping {
                    write(.init(id: request.id))
                } else if activeTask != nil || !queue.isEmpty {
                    write(.init(id: request.id, error: "MessageHelper is busy. Wait for the current requests to finish."))
                } else {
                    queue.append(request)
                    startNext()
                }
            }
        } catch {
            write(.init(id: "unknown", error: error.localizedDescription))
            end()
        }
    }

    private func startNext() {
        guard !ended, activeTask == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if request.action == .listModels {
                    let catalog = try await self.client.listModels(workingDirectory: self.workingDirectory)
                    if !self.ended { self.write(.init(id: request.id, catalog: catalog)) }
                } else {
                    // Never resume another message's thread or share client context.
                    let connection = try await self.client.connect(threadID: nil, workingDirectory: self.workingDirectory,
                                                                   model: request.model)
                    try Task.checkCancellation()
                    let result = try await self.client.answer(prompt: request.prompt(), requestID: UUID(), onDelta: { _ in })
                    if !self.ended { self.write(.init(id: request.id, text: result.text, model: connection.model)) }
                }
            } catch {
                if !self.ended { self.write(.init(id: request.id, error: error.localizedDescription)) }
            }
            await self.client.disconnect()
            self.activeTask = nil
            self.startNext()
        }
    }

    private func write(_ response: HelperResponse) {
        do {
            let bytes: Data
            do { bytes = try NativeFrameEncoder.encode(response) }
            catch { bytes = try NativeFrameEncoder.encode(HelperResponse(id: response.id, error: error.localizedDescription)) }
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch { end() }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        FileHandle.standardInput.readabilityHandler = nil
        queue.removeAll()
        activeTask?.cancel()
        Task { [self] in
            await client.disconnect()
            let continuation = exitContinuation
            exitContinuation = nil
            continuation?.resume()
        }
    }
}
