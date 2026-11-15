import Foundation
import Darwin

public enum ScriptWorkerError: LocalizedError, Equatable {
    case unavailable
    case invalid(String)
    case failed(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The MacHelper script worker is unavailable. Reinstall the MacHelper app."
        case .invalid(let message), .failed(let message): return message
        case .timedOut: return "The extension took too long to respond. Its worker was stopped."
        case .cancelled: return "The extension request was cancelled."
        }
    }
}

/// One replaceable JS process per source generation. Messages and selected text
/// use bounded stdin/stdout frames, never command arguments or diagnostic logs.
@MainActor
public final class ScriptWorkerClient {
    public typealias CapabilityHandler = @MainActor ([String: Any]) async throws -> [String: Any]
    public typealias ProgressHandler = @MainActor ([String: Any]) -> Void
    public typealias StreamingCapabilityHandler = @MainActor ([String: Any], @escaping ProgressHandler) async throws -> [String: Any]
    public private(set) var generation: String?
    public var processIdentifier: Int32? { connection?.process.processIdentifier }
    private let executableURL: URL
    private let requestTimeout: TimeInterval
    private let loadTimeout: TimeInterval
    private var connection: ScriptWorkerConnection?
    private var sessionID = UUID()
    private var decoder = NativeFrameDecoder()
    private var pending: [String: Pending] = [:]
    private var capabilityTasks: [String: Task<Void, Never>] = [:]
    private var capabilityHandler: CapabilityHandler?
    private var streamingCapabilityHandler: StreamingCapabilityHandler?
    private var permissions = Set<String>()
    private var cleanupTask: Task<Void, Never>?
    private var stopping = false

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
        let onProgress: ProgressHandler?
    }

    public init(executableURL: URL, requestTimeout: TimeInterval = 180, loadTimeout: TimeInterval = 5) {
        self.executableURL = executableURL
        self.requestTimeout = requestTimeout.isFinite ? min(3600, max(0.05, requestTimeout)) : 180
        self.loadTimeout = loadTimeout.isFinite ? min(60, max(0.05, loadTimeout)) : 5
    }

    deinit { connection?.terminateWithoutWaiting() }

    @discardableResult
    public func load(entrySource: String, resources: [String: String] = [:], settings: [String: Any] = [:],
                     permissions: [String], generation: String = UUID().uuidString,
                     streamingCapabilityHandler: StreamingCapabilityHandler? = nil,
                     capabilityHandler: @escaping CapabilityHandler) async throws -> [String] {
        guard !stopping else { throw ScriptWorkerError.invalid("Wait for the current worker to stop.") }
        await stop()
        try Task.checkCancellation()
        guard !generation.isEmpty, generation.utf8.count <= 128,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw ScriptWorkerError.unavailable }
        let session = UUID()
        let connection = try ScriptWorkerConnection(executableURL: executableURL)
        self.sessionID = session
        self.connection = connection
        self.generation = generation
        self.capabilityHandler = capabilityHandler
        self.streamingCapabilityHandler = streamingCapabilityHandler
        self.permissions = Set(permissions)
        decoder = NativeFrameDecoder()
        connection.output.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.receive(bytes, session: session) }
        }
        do {
            let response = try await request(method: "load", payload: ["entrySource": entrySource,
                "resources": resources, "settings": settings, "permissions": permissions], timeout: loadTimeout)
            guard response["__loaded"] as? Bool == true, let commands = response["commands"] as? [String],
                  !commands.isEmpty, commands.count <= 32,
                  Set(commands).count == commands.count,
                  commands.allSatisfy({ $0.range(of: #"^[a-z][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil }) else {
                throw ScriptWorkerError.invalid("The extension did not return a valid command list.")
            }
            return commands
        } catch {
            await stop()
            throw error
        }
    }

    public func invoke(command: String, input: [String: Any], onProgress: ProgressHandler? = nil) async throws -> [String: Any] {
        guard connection != nil, !stopping else { throw ScriptWorkerError.cancelled }
        return try await request(method: "invoke", payload: ["command": command, "input": input], timeout: requestTimeout, onProgress: onProgress)
    }

    /// A short lifecycle grace is followed by bounded process termination. This
    /// also cancels host-side capabilities and rejects all old-generation work.
    public func stop() async {
        guard !stopping else { return }
        guard let current = connection else {
            if let cleanupTask { await cleanupTask.value }
            return
        }
        stopping = true
        let session = sessionID
        cancelCapabilities()
        rejectPending(ScriptWorkerError.cancelled)
        _ = try? await request(method: "stop", payload: [:], timeout: 0.25)
        if sessionID == session { failConnection(ScriptWorkerError.cancelled) }
        if let cleanupTask { await cleanupTask.value }
        stopping = false
        _ = current
    }

    public func cancel() async { await stop() }

    private func request(method: String, payload: [String: Any], timeout: TimeInterval,
                         onProgress: ProgressHandler? = nil) async throws -> [String: Any] {
        guard let connection, let generation else { throw ScriptWorkerError.cancelled }
        let session = sessionID
        let id = UUID().uuidString
        var envelope = payload
        envelope["id"] = id; envelope["method"] = method; envelope["generation"] = generation
        let bytes = try Self.frame(envelope)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.sessionID == session, self.pending[id] != nil else { return }
                    self.failConnection(ScriptWorkerError.timedOut)
                }
                pending[id] = Pending(method: method, continuation: continuation, timeout: timer, onProgress: onProgress)
                connection.write(bytes, timeout: min(timeout, 2)) { [weak self] error in
                    guard let error else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionID == session else { return }
                        self.failConnection(error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionID == session else { return }
                self.failConnection(ScriptWorkerError.cancelled)
            }
        }
    }

    private func receive(_ bytes: Data, session: UUID) {
        guard session == sessionID, connection != nil else { return }
        if bytes.isEmpty { failConnection(ScriptWorkerError.failed("The extension worker closed its connection.")); return }
        do {
            for frame in try decoder.append(bytes) {
                guard let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                      let returnedGeneration = message["generation"] as? String else {
                    throw ScriptWorkerError.invalid("The extension worker returned an invalid response.")
                }
                // Reader callbacks from a disposed process cannot affect its replacement.
                guard returnedGeneration == generation else { continue }
                if message["type"] as? String == "capability" { receiveCapability(message, id: id, session: session); continue }
                if message["type"] as? String == "progress" {
                    guard !stopping, permissions.contains("ui.panel"), let request = pending[id], request.method == "invoke",
                          let result = message["result"] as? [String: Any], let progress = Self.toolProgress(result) else { continue }
                    request.onProgress?(progress)
                    continue
                }
                guard let request = pending.removeValue(forKey: id) else { continue }
                request.timeout.cancel()
                if request.method == "invoke", !pending.values.contains(where: { $0.method == "invoke" }) {
                    // A script may throw from a streaming callback or return
                    // without awaiting AI. Its terminal action must not leave
                    // an unrelated provider task consuming usage in background.
                    cancelCapabilities()
                }
                guard let ok = message["ok"] as? Bool else {
                    request.continuation.resume(throwing: ScriptWorkerError.invalid("The worker response has no success flag.")); continue
                }
                if !ok {
                    request.continuation.resume(throwing: ScriptWorkerError.failed(String((message["error"] as? String ?? "The extension failed.").prefix(2048))))
                } else if let result = message["result"] as? [String: Any] {
                    request.continuation.resume(returning: result)
                } else {
                    request.continuation.resume(throwing: ScriptWorkerError.invalid("Extension commands must return an object."))
                }
            }
        } catch { failConnection(error) }
    }

    private func receiveCapability(_ message: [String: Any], id: String, session: UUID) {
        guard let payload = message["payload"] as? [String: Any], message["capability"] as? String == "ai.transform",
              permissions.contains("ai.transform"), pending.values.contains(where: { $0.method == "invoke" }),
              !stopping, capabilityTasks[id] == nil, capabilityTasks.count < 8, let handler = capabilityHandler else {
            sendCapabilityResult(id, ok: false, result: nil, error: "AI access requires a permitted, explicit command invocation.", session: session)
            return
        }
        capabilityTasks[id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let result: [String: Any]
                if let streaming = self?.streamingCapabilityHandler {
                    result = try await streaming(payload) { [weak self] progress in
                        self?.sendCapabilityProgress(id, progress: progress, session: session)
                    }
                } else { result = try await handler(payload) }
                guard !Task.isCancelled else { return }
                self?.sendCapabilityResult(id, ok: true, result: result, error: nil, session: session)
            } catch {
                guard !Task.isCancelled else { return }
                self?.sendCapabilityResult(id, ok: false, result: nil,
                                           error: String(error.localizedDescription.prefix(2048)), session: session)
            }
            if self?.sessionID == session { self?.capabilityTasks.removeValue(forKey: id) }
        }
    }

    private func sendCapabilityProgress(_ id: String, progress: [String: Any], session: UUID) {
        guard sessionID == session, let connection, let generation, !stopping,
              permissions.contains("ai.transform"), capabilityTasks[id] != nil,
              pending.values.contains(where: { $0.method == "invoke" }),
              let value = Self.aiProgress(progress) else { return }
        let message: [String: Any] = ["id": id, "method": "capabilityProgress", "generation": generation, "progress": value]
        do { connection.write(try Self.frame(message), timeout: 2) { _ in } }
        catch { failConnection(error) }
    }

    private func sendCapabilityResult(_ id: String, ok: Bool, result: [String: Any]?, error: String?, session: UUID) {
        guard sessionID == session, let connection, let generation else { return }
        var object: [String: Any] = ["id": id, "method": "capabilityResult", "ok": ok, "generation": generation]
        if let result { object["result"] = result }
        if let error { object["error"] = error }
        do { connection.write(try Self.frame(object), timeout: 2) { _ in } }
        catch { failConnection(error) }
    }

    private func rejectPending(_ error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.timeout.cancel(); request.continuation.resume(throwing: error) }
    }

    private func cancelCapabilities() {
        capabilityTasks.values.forEach { $0.cancel() }
        capabilityTasks.removeAll()
    }

    private func failConnection(_ error: Error) {
        guard let connection else { return }
        self.connection = nil
        generation = nil
        sessionID = UUID()
        capabilityHandler = nil
        streamingCapabilityHandler = nil
        cancelCapabilities()
        rejectPending(error)
        cleanupTask = Task { await connection.closeAndTerminate() }
    }

    private static func toolProgress(_ value: [String: Any]) -> [String: Any]? {
        guard let text = value["text"] as? String, text.utf8.count <= 96_000, !text.contains("\0") else { return nil }
        var result: [String: Any] = ["text": text]
        if let title = value["title"] {
            guard let title = title as? String, title.count <= 120, !title.contains("\0") else { return nil }
            result["title"] = title
        }
        return result
    }

    private static func aiProgress(_ value: [String: Any]) -> [String: Any]? {
        guard let text = value["text"] as? String, text.utf8.count <= 96_000, !text.contains("\0"),
              let delta = value["delta"] as? String, delta.utf8.count <= 96_000, !delta.contains("\0") else { return nil }
        var result: [String: Any] = ["text": text, "delta": delta]
        if let model = value["model"], !(model is NSNull) {
            guard let model = model as? String, model.count <= 256, !model.contains("\0") else { return nil }
            result["model"] = model
        }
        return result
    }

    private static func frame(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw ScriptWorkerError.invalid("The extension request is not valid JSON.") }
        let payload = try JSONSerialization.data(withJSONObject: value)
        guard !payload.isEmpty, payload.count <= NativeFrameDecoder.maximumFrameBytes else {
            throw ScriptWorkerError.invalid("The extension request exceeds the 256 KiB frame limit.")
        }
        let size = UInt32(payload.count)
        var data = Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        data.append(payload)
        return data
    }
}

/// Pipe writes and child reaping are outside the main actor. A lock protects FD
/// closure/reuse while a cancelled writer finishes its nonblocking write loop.
private final class ScriptWorkerConnection: @unchecked Sendable {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    private let lock = NSLock()
    private var closed = false
    private let writes = DispatchQueue(label: "com.localaibasetools.script-worker.write")

    init(executableURL: URL) throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        do { try process.run() }
        catch { throw ScriptWorkerError.unavailable }
        _ = fcntl(self.input.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(self.input.fileDescriptor, F_SETFL, fcntl(self.input.fileDescriptor, F_GETFL) | O_NONBLOCK)
    }

    func write(_ bytes: Data, timeout: TimeInterval, completion: @escaping @Sendable (Error?) -> Void) {
        writes.async { [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var offset = 0
            while offset < bytes.count {
                lock.lock()
                if closed { lock.unlock(); completion(ScriptWorkerError.cancelled); return }
                let descriptor = input.fileDescriptor
                let amount = bytes.withUnsafeBytes { buffer in
                    Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                let savedErrno = errno
                lock.unlock()
                if amount > 0 { offset += amount; continue }
                if amount < 0 && savedErrno == EINTR { continue }
                guard amount < 0 && savedErrno == EAGAIN else {
                    completion(ScriptWorkerError.failed("The script worker connection was interrupted.")); return
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { completion(ScriptWorkerError.timedOut); return }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT | POLLHUP), revents: 0)
                _ = Darwin.poll(&pollDescriptor, 1, Int32(min(remaining * 1000, 50)))
            }
            completion(nil)
        }
    }

    private func closeHandles() -> Bool {
        lock.lock()
        if closed { lock.unlock(); return false }
        closed = true
        output.readabilityHandler = nil
        try? input.close()
        try? output.close()
        lock.unlock()
        return true
    }

    func terminateWithoutWaiting() {
        guard closeHandles() else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).async { [process] in Self.reap(process) }
    }

    private static func reap(_ process: Process) {
        if process.isRunning {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    func closeAndTerminate() async {
        guard closeHandles() else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [process] in
                if process.isRunning {
                    process.terminate()
                }
                Self.reap(process)
                continuation.resume()
            }
        }
    }
}
