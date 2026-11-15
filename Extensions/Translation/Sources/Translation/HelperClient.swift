import Foundation
import Darwin

enum TranslationError: LocalizedError, Equatable {
    case unavailable
    case invalid(String)
    case failed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "MacHelper is not installed at the shared helper location. Run the LocalAIBaseTools installer, then try again."
        case .invalid(let reason), .failed(let reason): return reason
        case .timedOut: return "MacHelper took too long to respond. Check your local AI connection and try again."
        case .cancelled: return "Translation cancelled."
        }
    }
}

struct TranslationRequest: Encodable {
    let id: String
    let action = "translate"
    let text: String
    let targetLanguage: String
    /// Empty means use the provider/model chosen in the independent MacHelper app.
    let model = ""

    init(id: String = UUID().uuidString, text: String, targetLanguage: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalid("Select some text to translate first.")
        }
        guard text.count <= 24_000, text.utf8.count <= 96_000 else {
            throw TranslationError.invalid("Select at most 24,000 characters at a time.")
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TranslationError.invalid("This selection contains an unsupported null character.")
        }
        guard TranslationLanguage.all.contains(where: { $0.code == targetLanguage }) else {
            throw TranslationError.invalid("Choose a supported target language in Translation settings.")
        }
        self.id = id
        self.text = text
        self.targetLanguage = targetLanguage
    }
}

struct TranslationResponse: Decodable, Equatable {
    let id: String
    let ok: Bool
    let text: String?
    let model: String?
    let error: String?
}

enum TranslationFrame {
    static let maximumBytes = 256 * 1024

    static func encode<T: Encodable>(_ request: T) throws -> Data {
        let payload = try JSONEncoder().encode(request)
        guard !payload.isEmpty, payload.count <= maximumBytes else {
            throw TranslationError.invalid("The selected text is too large for MacHelper.")
        }
        let count = UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
        frame.append(payload)
        return frame
    }

    static func payloadLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw TranslationError.invalid("MacHelper returned an incomplete message header.") }
        let size = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        guard size > 0, size <= maximumBytes else {
            throw TranslationError.invalid("MacHelper returned an invalid message size.")
        }
        return Int(size)
    }

    static func decode(_ payload: Data, expectedID: String) throws -> TranslationResponse {
        let response: TranslationResponse
        do { response = try JSONDecoder().decode(TranslationResponse.self, from: payload) }
        catch { throw TranslationError.invalid("MacHelper returned an unreadable response.") }
        guard response.id == expectedID else { throw TranslationError.invalid("MacHelper returned a response for another request.") }
        guard response.ok else { throw TranslationError.failed(response.error ?? "MacHelper could not translate this text.") }
        guard let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalid("MacHelper returned an empty translation.")
        }
        return response
    }
}

struct TranslationLanguage: Equatable {
    let code: String
    let title: String
    static let all = [
        TranslationLanguage(code: "zh-CN", title: "简体中文"),
        TranslationLanguage(code: "zh-TW", title: "繁體中文"),
        TranslationLanguage(code: "en", title: "English"),
        TranslationLanguage(code: "ja", title: "日本語"),
        TranslationLanguage(code: "ko", title: "한국어"),
        TranslationLanguage(code: "fr", title: "Français"),
        TranslationLanguage(code: "de", title: "Deutsch"),
        TranslationLanguage(code: "es", title: "Español"),
        TranslationLanguage(code: "pt", title: "Português"),
        TranslationLanguage(code: "it", title: "Italiano")
    ]
}

struct NativeHelperClient {
    static let installedHostURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host")

    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval

    init(executableURL: URL = installedHostURL, arguments: [String] = [], timeout: TimeInterval = 180) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    func translate(text: String, targetLanguage: String) async throws -> TranslationResponse {
        let request = try TranslationRequest(text: text, targetLanguage: targetLanguage)
        let operation = HelperOperation(executableURL: executableURL, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try operation.run(request)) }
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

    func run(_ request: TranslationRequest) throws -> TranslationResponse {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw TranslationError.unavailable }
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
        guard !alreadyCancelled else { throw TranslationError.cancelled }
        do { try child.run() }
        catch { throw TranslationError.unavailable }

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
        try write(TranslationFrame.encode(request), to: input.fileHandleForWriting.fileDescriptor, deadline: deadline)
        let header = try readExactly(4, from: output.fileHandleForReading.fileDescriptor, deadline: deadline)
        let size = try TranslationFrame.payloadLength(header)
        let payload = try readExactly(size, from: output.fileHandleForReading.fileDescriptor, deadline: deadline)
        try checkCancellation()
        return try TranslationFrame.decode(payload, expectedID: request.id)
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw TranslationError.cancelled }
    }

    private func readExactly(_ count: Int, from fd: Int32, deadline: Date) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 8192))
        while data.count < count {
            try checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TranslationError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let status = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
            if status < 0 {
                if errno == EINTR { continue }
                throw TranslationError.failed("The connection to MacHelper was interrupted.")
            }
            if status == 0 { continue }
            let amount = Darwin.read(fd, &buffer, min(buffer.count, count - data.count))
            guard amount > 0 else {
                try checkCancellation()
                if amount < 0 && errno == EINTR { continue }
                throw TranslationError.failed("MacHelper closed the connection before returning a translation.")
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
            guard remaining > 0 else { throw TranslationError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT | POLLHUP), revents: 0)
            let status = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
            if status < 0 {
                if errno == EINTR { continue }
                throw TranslationError.failed("The connection to MacHelper was interrupted.")
            }
            if status == 0 { continue }
            let amount = data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if amount < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard amount > 0 else {
                try checkCancellation()
                throw TranslationError.failed("MacHelper could not receive the selected text.")
            }
            offset += amount
        }
    }
}
