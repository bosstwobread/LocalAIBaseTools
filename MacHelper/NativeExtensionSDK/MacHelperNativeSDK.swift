import Foundation
import Darwin

/// Native extensions execute trusted Swift code in their own process. The host
/// owns shared UI/settings and brokers AI; process separation is not a sandbox.
public enum MacHelperNative {
    public typealias Command = @MainActor (MacHelperNativeInput) async throws -> [String: Any]
    public typealias Start = @MainActor ([String: Any]) async throws -> Void
    public typealias Stop = @MainActor () async -> Void

    /// Call once from your extension's @main entry point. Standard output is
    /// reserved for bounded protocol frames; do not use print() in extension code.
    public static func run(commands: [String: Command], start: Start? = nil, stop: Stop? = nil) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let parent = getppid()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        watchdog.setEventHandler { if getppid() != parent || getppid() == 1 { _exit(0) } }
        watchdog.resume()
        let transport = NativeExtensionTransport()
        Task { @MainActor in
            let worker = NativeExtensionWorker(commands: commands, start: start, stop: stop, transport: transport)
            transport.onMessage = { message in worker.receive(message) }
            transport.start()
        }
        withExtendedLifetime(watchdog) { dispatchMain() }
    }
}

/// One command's immutable data and invocation-scoped capability methods.
@MainActor
public final class MacHelperNativeInput {
    public let text: String
    public let sentence: String?
    public let settings: [String: Any]
    private weak var worker: NativeExtensionWorker?
    private let invocation: String

    fileprivate init(value: [String: Any], invocation: String, worker: NativeExtensionWorker) {
        text = value["text"] as? String ?? ""
        sentence = value["sentence"] as? String
        settings = value["settings"] as? [String: Any] ?? [:]
        self.invocation = invocation; self.worker = worker
    }

    public func readText(_ path: String) throws -> String {
        guard let worker, worker.isInvoking(invocation), let value = worker.resources[path] else {
            throw NativeExtensionError.invalid("The packaged resource is unavailable for this invocation.")
        }
        return value
    }

    /// The request, including systemPrompt, is forwarded without rewriting.
    public func transform(request: [String: Any], onProgress: (@MainActor ([String: Any]) -> Void)? = nil) async throws -> [String: Any] {
        guard let worker else { throw CancellationError() }
        return try await worker.transform(request: request, invocation: invocation, onProgress: onProgress)
    }

    public func reportProgress(text: String, title: String? = nil) throws {
        guard let worker else { throw CancellationError() }
        try worker.progress(invocation: invocation, text: text, title: title)
    }
}

private enum NativeExtensionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

@MainActor
private final class NativeExtensionWorker {
    private let commands: [String: MacHelperNative.Command]
    private let start: MacHelperNative.Start?
    private let stop: MacHelperNative.Stop?
    private let transport: NativeExtensionTransport
    private var generation: String?
    private var loaded = false
    private var stopping = false
    private var permissions = Set<String>()
    private(set) var resources: [String: String] = [:]
    private var invocations: [String: Task<Void, Never>] = [:]
    private var capabilities: [String: Capability] = [:]

    private struct Capability {
        let invocation: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let onProgress: (@MainActor ([String: Any]) -> Void)?
    }

    init(commands: [String: MacHelperNative.Command], start: MacHelperNative.Start?, stop: MacHelperNative.Stop?, transport: NativeExtensionTransport) {
        self.commands = commands; self.start = start; self.stop = stop; self.transport = transport
    }

    func receive(_ message: [String: Any]) {
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let method = message["method"] as? String,
              let requestedGeneration = message["generation"] as? String,
              !requestedGeneration.isEmpty, requestedGeneration.utf8.count <= 128 else { return }
        if method == "load" {
            guard generation == nil else { respond(id, ok: false, error: "A worker can load only one generation."); return }
            generation = requestedGeneration
            guard let resources = message["resources"] as? [String: String], resources.count <= 128,
                  resources.values.reduce(0, { $0 + $1.utf8.count }) <= 96 * 1024,
                  let settings = message["settings"] as? [String: Any],
                  let declared = message["permissions"] as? [String], Set(declared).count == declared.count,
                  declared.contains("native.execute"), declared.count <= 32,
                  !commands.isEmpty, commands.count <= 16,
                  commands.keys.allSatisfy({ $0.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil }) else {
                respond(id, ok: false, error: "The native extension load request is invalid."); return
            }
            self.resources = resources; permissions = Set(declared)
            Task { @MainActor in
                do {
                    try await start?(settings)
                    guard !stopping else { return }
                    loaded = true
                    respond(id, ok: true, result: ["__loaded": true, "commands": commands.keys.sorted()])
                } catch { respond(id, ok: false, error: "The native extension could not be initialized.") }
            }
            return
        }
        guard requestedGeneration == generation else { return }
        switch method {
        case "invoke":
            guard loaded, !stopping, invocations.count < 8, invocations[id] == nil,
                  let name = message["command"] as? String, let command = commands[name],
                  let value = message["input"] as? [String: Any] else {
                respond(id, ok: false, error: "The native extension command request is invalid."); return
            }
            let input = MacHelperNativeInput(value: value, invocation: id, worker: self)
            invocations[id] = Task { @MainActor in
                do {
                    let result = try await command(input)
                    try Task.checkCancellation()
                    guard isInvoking(id) else { return }
                    respond(id, ok: true, result: result)
                } catch {
                    if isInvoking(id) { respond(id, ok: false, error: String(error.localizedDescription.prefix(2048))) }
                }
                invocations.removeValue(forKey: id)
                cancelCapabilities(for: id)
            }
        case "capabilityProgress":
            guard !stopping, let capability = capabilities[id], isInvoking(capability.invocation),
                  let progress = message["progress"] as? [String: Any],
                  validProgress(progress, requireDelta: true) else { return }
            capability.onProgress?(progress)
        case "capabilityResult":
            guard let ok = message["ok"] as? Bool, let capability = capabilities.removeValue(forKey: id) else { return }
            if ok, let result = message["result"] as? [String: Any] { capability.continuation.resume(returning: result) }
            else { capability.continuation.resume(throwing: NativeExtensionError.invalid(String((message["error"] as? String ?? "The capability failed.").prefix(2048)))) }
        case "stop":
            guard !stopping else { return }
            stopping = true; loaded = false
            invocations.values.forEach { $0.cancel() }; invocations.removeAll()
            cancelCapabilities()
            Task { @MainActor in
                await stop?()
                respond(id, ok: true, result: ["stopped": true])
            }
        default: respond(id, ok: false, error: "Unsupported native worker method.")
        }
    }

    func isInvoking(_ id: String) -> Bool { loaded && !stopping && invocations[id] != nil }

    func transform(request: [String: Any], invocation: String,
                   onProgress: (@MainActor ([String: Any]) -> Void)?) async throws -> [String: Any] {
        guard isInvoking(invocation), permissions.contains("ai.transform"), capabilities.count < 8,
              JSONSerialization.isValidJSONObject(request) else {
            throw NativeExtensionError.invalid("AI access requires an explicit command and ai.transform permission.")
        }
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                capabilities[id] = Capability(invocation: invocation, continuation: continuation, onProgress: onProgress)
                do { try send(["type": "capability", "id": id, "capability": "ai.transform", "payload": request]) }
                catch { capabilities.removeValue(forKey: id); continuation.resume(throwing: error) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.capabilities.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func progress(invocation: String, text: String, title: String?) throws {
        guard isInvoking(invocation), permissions.contains("ui.panel") else {
            throw NativeExtensionError.invalid("Command progress requires an active invocation and ui.panel permission.")
        }
        var result: [String: Any] = ["text": text]
        if let title { result["title"] = title }
        guard validProgress(result, requireDelta: false) else { throw NativeExtensionError.invalid("The native extension progress is invalid.") }
        try send(["type": "progress", "id": invocation, "result": result])
    }

    private func validProgress(_ value: [String: Any], requireDelta: Bool) -> Bool {
        guard let text = value["text"] as? String, text.utf8.count <= 96_000, !text.contains("\0") else { return false }
        if requireDelta {
            guard let delta = value["delta"] as? String, delta.utf8.count <= 96_000, !delta.contains("\0") else { return false }
        }
        if let title = value["title"] { guard let title = title as? String, title.count <= 120, !title.contains("\0") else { return false } }
        if let model = value["model"], !(model is NSNull) { guard let model = model as? String, model.count <= 256, !model.contains("\0") else { return false } }
        return true
    }

    private func cancelCapabilities(for invocation: String? = nil) {
        let ids = capabilities.keys.filter { invocation == nil || capabilities[$0]?.invocation == invocation }
        for id in ids { capabilities.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    }

    private func respond(_ id: String, ok: Bool, result: [String: Any]? = nil, error: String? = nil) {
        var value: [String: Any] = ["id": id, "ok": ok]
        if let result { value["result"] = result }
        if let error { value["error"] = error }
        do { try send(value) }
        catch { _exit(1) }
    }

    private func send(_ object: [String: Any]) throws {
        var value = object; value["generation"] = generation ?? ""
        try transport.send(value)
    }
}

/// A serial reader never blocks the main actor while a command awaits an AI
/// capability reply. Only this transport writes framed data to standard output.
private final class NativeExtensionTransport: @unchecked Sendable {
    @MainActor var onMessage: (([String: Any]) -> Void)?
    private let writeLock = NSLock()

    @MainActor func start() {
        DispatchQueue(label: "com.localaibasetools.native-worker.read").async { [self] in
            do {
                while let message = try readFrame() {
                    DispatchQueue.main.async { [self] in onMessage?(message) }
                }
            } catch { }
            // EOF/invalid framing means the host is gone or the channel failed.
            _exit(0)
        }
    }

    func send(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else { throw NativeExtensionError.invalid("The native extension returned invalid JSON.") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard !data.isEmpty, data.count <= 256 * 1024 else { throw NativeExtensionError.invalid("The native extension frame exceeds 256 KiB.") }
        let length = UInt32(data.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }); frame.append(data)
        writeLock.lock(); defer { writeLock.unlock() }
        try FileHandle.standardOutput.write(contentsOf: frame)
    }

    private func readExactly(_ count: Int, allowEOF: Bool = false) throws -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
            if chunk.isEmpty {
                if allowEOF && data.isEmpty { return nil }
                throw NativeExtensionError.invalid("Incomplete native frame.")
            }
            data.append(chunk)
        }
        return data
    }

    private func readFrame() throws -> [String: Any]? {
        guard let header = try readExactly(4, allowEOF: true) else { return nil }
        let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 256 * 1024,
              let data = try readExactly(Int(length)),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeExtensionError.invalid("Invalid native frame.") }
        return object
    }
}
