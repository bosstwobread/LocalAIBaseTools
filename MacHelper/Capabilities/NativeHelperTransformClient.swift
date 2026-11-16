import Foundation
import Darwin

public enum CapabilityError: LocalizedError, Equatable {
    case unavailable
    case invalid(String)
    case failed(String)
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "MacHelper is not installed at the shared helper location. Run the LocalAIBaseTools installer, then try again."
        case .invalid(let reason), .failed(let reason): return reason
        case .timedOut: return "MacHelper took too long to respond. Check your local AI connection and try again."
        case .cancelled: return "Request cancelled."
        }
    }
}

public struct CapabilityAIRequest: Encodable, Sendable {
    public let id: String
    public let action: String
    public let text: String
    public let targetLanguage: String?
    public let tone: String?
    /// Empty means use the provider/model chosen in the independent MacHelper app.
    public let model: String
    public let guidance: String?
    public let systemPrompt: String?

    public init(id: String = UUID().uuidString, action: String, text: String,
                targetLanguage: String? = nil, tone: String? = nil, model: String = "", guidance: String? = nil, systemPrompt: String? = nil) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CapabilityError.invalid("A valid request ID is required.")
        }
        guard action.range(of: "^[A-Za-z][A-Za-z0-9_]{0,39}$", options: .regularExpression) != nil else {
            throw CapabilityError.invalid("The AI action identifier is invalid.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapabilityError.invalid("Select some text first.")
        }
        if systemPrompt != nil {
            guard text.utf8.count <= 192_000 else {
                throw CapabilityError.invalid("Extension input data must contain at most 192,000 UTF-8 bytes.")
            }
        } else {
            guard text.count <= 24_000, text.utf8.count <= 96_000 else {
                throw CapabilityError.invalid("Select at most 24,000 characters at a time.")
            }
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CapabilityError.invalid("This selection contains an unsupported null character.")
        }
        for value in [targetLanguage, tone, Optional(model)].compactMap({ $0 }) {
            guard value.utf8.count <= 200,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CapabilityError.invalid("An AI request option is invalid.")
            }
        }
        if let guidance {
            guard guidance.count <= 12_000, guidance.utf8.count <= 48_000,
                  !guidance.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw CapabilityError.invalid("Tool guidance must contain at most 12,000 characters and no null characters.")
            }
        }
        if let systemPrompt {
            guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  systemPrompt.count <= 12_000, systemPrompt.utf8.count <= 48_000,
                  !systemPrompt.contains("\0") else {
                throw CapabilityError.invalid("The system prompt must be nonempty, contain at most 12,000 characters/48,000 UTF-8 bytes, and contain no null characters.")
            }
        }
        self.id = id
        self.action = action
        self.text = text
        self.targetLanguage = targetLanguage
        self.tone = tone
        self.model = model
        self.guidance = guidance
        self.systemPrompt = systemPrompt
    }
}

public struct CapabilityAIResponse: Decodable, Equatable, Sendable {
    public let id: String
    public let ok: Bool
    public let text: String?
    public let model: String?
    public let error: String?
}

enum CapabilityFrame {
    static let maximumBytes = 256 * 1024

    static func encode<T: Encodable>(_ request: T) throws -> Data {
        let payload = try JSONEncoder().encode(request)
        guard !payload.isEmpty, payload.count <= maximumBytes else {
            throw CapabilityError.invalid("The selected text is too large for MacHelper.")
        }
        let count = UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
        frame.append(payload)
        return frame
    }

    static func encodeRequest(_ request: CapabilityAIRequest, streaming: Bool) throws -> Data {
        try encode(WireRequest(request: request, streaming: streaming))
    }

    private struct WireRequest: Encodable {
        let request: CapabilityAIRequest
        let streaming: Bool
        enum CodingKeys: String, CodingKey { case stream }
        func encode(to encoder: Encoder) throws {
            try request.encode(to: encoder)
            if streaming {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(true, forKey: .stream)
            }
        }
    }

    static func payloadLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw CapabilityError.invalid("MacHelper returned an incomplete message header.") }
        let size = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        guard size > 0, size <= maximumBytes else {
            throw CapabilityError.invalid("MacHelper returned an invalid message size.")
        }
        return Int(size)
    }

    static func decode(_ payload: Data, expectedID: String) throws -> CapabilityAIResponse {
        let response: CapabilityAIResponse
        do { response = try JSONDecoder().decode(CapabilityAIResponse.self, from: payload) }
        catch { throw CapabilityError.invalid("MacHelper returned an unreadable response.") }
        guard response.id == expectedID else { throw CapabilityError.invalid("MacHelper returned a response for another request.") }
        guard response.ok else { throw CapabilityError.failed(response.error ?? "MacHelper could not complete this request.") }
        guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CapabilityError.invalid("MacHelper returned an empty result.")
        }
        return response
    }
}

/// A progress frame is never a successful result. Only the normal terminal
/// response can complete a request, even after one or more readable deltas.
struct CapabilityStreamDecoder {
    enum Event: Equatable {
        case progress(delta: String, model: String?)
        case complete(CapabilityAIResponse)
    }

    private let expectedID: String
    private let permitsProgress: Bool
    private var receivedDeltaBytes = 0
    private var progressFrames = 0
    private(set) var completed = false

    init(expectedID: String, permitsProgress: Bool) {
        self.expectedID = expectedID
        self.permitsProgress = permitsProgress
    }

    mutating func decode(_ payload: Data) throws -> Event {
        guard !completed else { throw CapabilityError.invalid("MacHelper sent data after completing the request.") }
        guard payload.count <= CapabilityFrame.maximumBytes else { throw CapabilityError.invalid("MacHelper returned an oversized response.") }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: payload) }
        catch { throw CapabilityError.invalid("MacHelper returned an unreadable response.") }
        guard envelope.id == expectedID else { throw CapabilityError.invalid("MacHelper returned a response for another request.") }
        if let event = envelope.event {
            guard permitsProgress, event == "delta", envelope.ok == nil, let delta = envelope.delta else {
                throw CapabilityError.invalid("MacHelper returned an invalid progress event.")
            }
            receivedDeltaBytes += delta.utf8.count
            progressFrames += 1
            guard receivedDeltaBytes <= CapabilityFrame.maximumBytes, progressFrames <= 100_000 else {
                throw CapabilityError.invalid("MacHelper returned too much streamed output.")
            }
            return .progress(delta: delta, model: envelope.model)
        }
        completed = true
        let response = try CapabilityFrame.decode(payload, expectedID: expectedID)
        return .complete(response)
    }

    private struct Envelope: Decodable {
        let id: String
        let event: String?
        let delta: String?
        let model: String?
        let ok: Bool?
    }
}

public struct NativeHelperTransformClient: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let timeout: TimeInterval

    public init(executableURL: URL, arguments: [String] = [], timeout: TimeInterval = 180) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    public func transform(_ request: CapabilityAIRequest,
                          onProgress: (@Sendable (String, String?) -> Void)? = nil) async throws -> CapabilityAIResponse {
        guard timeout.isFinite, timeout > 0 else { throw CapabilityError.invalid("The AI request timeout must be a positive finite duration.") }
        let operation = HelperOperation(executableURL: executableURL, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try operation.run(request, onProgress: onProgress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { operation.cancel() }
    }
}

/// Blocking pipe work lives off the UI thread. Text travels only in the framed
/// stdin payload; it never appears in command arguments, logs, or saved files.
private final class HelperOperation: @unchecked Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    init(executableURL: URL, arguments: [String], timeout: TimeInterval) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        // The pipe loop sees this within 100 ms and closes stdin first. EOF lets
        // both new and older MacHelper hosts disconnect their AI subprocess.
    }

    func run(_ request: CapabilityAIRequest, onProgress: (@Sendable (String, String?) -> Void)?) throws -> CapabilityAIResponse {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw CapabilityError.unavailable }
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        let alreadyCancelled = cancelled
        lock.unlock()
        guard !alreadyCancelled else { throw CapabilityError.cancelled }
        do { try child.run() }
        catch { throw CapabilityError.unavailable }

        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            // Give the host a moment to disconnect its provider after EOF.
            let cleanupDeadline = Date().addingTimeInterval(0.6)
            while child.isRunning && Date() < cleanupDeadline { usleep(10_000) }
            if child.isRunning {
                child.terminate()
                usleep(20_000)
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            child.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(timeout)
        try checkCancellation()
        try write(CapabilityFrame.encodeRequest(request, streaming: onProgress != nil),
                  to: input.fileHandleForWriting.fileDescriptor, deadline: deadline)
        var decoder = CapabilityStreamDecoder(expectedID: request.id, permitsProgress: onProgress != nil)
        while true {
            let header = try readExactly(4, from: output.fileHandleForReading.fileDescriptor, deadline: deadline)
            let size = try CapabilityFrame.payloadLength(header)
            let payload = try readExactly(size, from: output.fileHandleForReading.fileDescriptor, deadline: deadline)
            try checkCancellation()
            switch try decoder.decode(payload) {
            case .progress(let delta, let model):
                // Ordered callbacks run on this background pipe reader. The
                // caller chooses how to deliver them to its own actor or UI.
                onProgress?(delta, model)
                try checkCancellation()
            case .complete(let response): return response
            }
        }
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CapabilityError.cancelled }
    }

    private func readExactly(_ count: Int, from fd: Int32, deadline: Date) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 8192))
        while data.count < count {
            try checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CapabilityError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let status = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
            if status < 0 {
                if errno == EINTR { continue }
                throw CapabilityError.failed("The connection to MacHelper was interrupted.")
            }
            if status == 0 { continue }
            let amount = Darwin.read(fd, &buffer, min(buffer.count, count - data.count))
            guard amount > 0 else {
                try checkCancellation()
                if amount < 0 && errno == EINTR { continue }
                throw CapabilityError.failed("MacHelper closed the connection before returning a result.")
            }
            data.append(contentsOf: buffer.prefix(amount))
        }
        return data
    }

    private func write(_ data: Data, to fd: Int32, deadline: Date) throws {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var offset = 0
        while offset < data.count {
            try checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CapabilityError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT | POLLHUP), revents: 0)
            let status = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
            if status < 0 {
                if errno == EINTR { continue }
                throw CapabilityError.failed("The connection to MacHelper was interrupted.")
            }
            if status == 0 { continue }
            let amount = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if amount < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard amount > 0 else {
                try checkCancellation()
                throw CapabilityError.failed("MacHelper could not receive the selected text.")
            }
            offset += amount
        }
    }
}
