import Foundation
import MacHelper

@main
struct MacHelperHost {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let allowedFile = binary.deletingLastPathComponent().appendingPathComponent("allowed-extension-ids.json")
            let allowedIDs: [String]
            if FileManager.default.fileExists(atPath: allowedFile.path) {
                allowedIDs = try JSONDecoder().decode([String].self, from: Data(contentsOf: allowedFile))
                guard !allowedIDs.isEmpty, allowedIDs.allSatisfy({ $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil }) else {
                    throw MacHelperError.invalid("The native host extension allowlist is invalid. Reinstall MacHelper.")
                }
            } else {
                allowedIDs = BrowserSupportInstaller.defaultExtensionIDs
            }
            try NativeHostOrigin.validate(arguments: CommandLine.arguments, allowedExtensionIDs: allowedIDs)
            let host = NativeHost()
            await host.run()
        } catch {
            // Native messaging stdout is reserved exclusively for framed JSON.
            try? FileHandle.standardError.write(contentsOf: Data("MacHelper could not start: \(error.localizedDescription)\n".utf8))
        }
    }
}

@MainActor
private final class NativeHost {
    private let client = AIProviderClient()
    private let discovery = DiscoverySearchEngine()
    private let settingsStore = HelperSettingsStore()
    private var decoder = NativeFrameDecoder()
    private var activeTask: Task<Void, Never>?
    private var ended = false
    private var exitContinuation: CheckedContinuation<Void, Never>?
    private var terminationSources: [DispatchSourceSignal] = []
    private let workingDirectory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        workingDirectory = support.appendingPathComponent("LocalAIBaseTools/MacHelper/Runtime", isDirectory: true)
    }

    func run() async {
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return }
        // Browser disconnects use EOF. Native clients can also cancel with
        // SIGTERM; route it through the same provider teardown before exiting.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.end() }
            source.resume()
            terminationSources.append(source)
        }
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
        terminationSources.forEach { $0.cancel() }
        terminationSources.removeAll()
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
                } else if activeTask != nil {
                    write(.init(id: request.id, error: "MacHelper is busy. Wait for the current requests to finish."))
                } else {
                    start(request)
                }
            }
        } catch {
            write(.init(id: "unknown", error: error.localizedDescription))
            end()
        }
    }

    private func start(_ request: HelperRequest) {
        guard !ended, activeTask == nil else { return }
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if request.action == .searchExtensions {
                    let result = try await self.discovery.search(query: request.text ?? "", language: request.interfaceLanguage ?? "en")
                    if !self.ended { self.write(.init(id: request.id, search: result)) }
                } else if request.action == .listModels {
                    let settings = try request.resolvedSettings(from: self.settingsStore)
                    let catalog = try await self.client.listModels(workingDirectory: self.workingDirectory, settings: settings)
                    if !self.ended { self.write(.init(id: request.id, catalog: catalog)) }
                } else {
                    let settings = try request.resolvedSettings(from: self.settingsStore)
                    let progress: (@Sendable (String, String) -> Void)?
                    if request.stream == true {
                        progress = { [weak self] delta, model in
                            // AIProviderClient delivers ordered callbacks on the
                            // main actor. Completion cannot overtake this write.
                            MainActor.assumeIsolated {
                                guard let self, !self.ended else { return }
                                self.writeDelta(delta, model: model, id: request.id)
                            }
                        }
                    } else { progress = nil }
                    let result = try await self.client.answer(request: request, workingDirectory: self.workingDirectory,
                                                              settings: settings, onDelta: progress)
                    if !self.ended { self.write(.init(id: request.id, text: result.text, model: result.model)) }
                }
            } catch {
                if !self.ended { self.write(.init(id: request.id, error: error.localizedDescription)) }
            }
            await self.client.disconnect()
            self.activeTask = nil
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

    private func writeDelta(_ delta: String, model: String, id: String) {
        // A provider may deliver a large delta. Bound each native frame even
        // when JSON escaping expands its text; preserve Unicode scalar order.
        var part = "", size = 0
        func flush() throws {
            guard !part.isEmpty else { return }
            try FileHandle.standardOutput.write(contentsOf: NativeFrameEncoder.encode(HelperStreamUpdate(id: id, delta: part, model: model)))
            part = ""; size = 0
        }
        do {
            for scalar in delta.unicodeScalars {
                let value = String(scalar), bytes = value.utf8.count
                if size + bytes > 8 * 1024 { try flush() }
                part += value; size += bytes
            }
            try flush()
        } catch { end() }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        FileHandle.standardInput.readabilityHandler = nil
        activeTask?.cancel()
        Task { [self] in
            await discovery.cancel()
            await client.disconnect()
            let continuation = exitContinuation
            exitContinuation = nil
            continuation?.resume()
        }
    }
}
