import Foundation
import Darwin
import MacHelper

struct SettingsModelCatalog: Sendable {
    struct Model: Decodable, Sendable {
        let model: String
        let displayName: String
    }
    let models: [Model]
}

enum SettingsHostError: LocalizedError {
    case missingHost
    case invalidResponse
    case timedOut
    case host(String)

    var errorDescription: String? {
        switch self {
        case .missingHost: return "MacHelper is not installed. Run the LocalAIBaseTools installer first."
        case .invalidResponse: return "MacHelper did not return a complete model list. Check that the selected AI service is running and try again."
        case .timedOut: return "MacHelper took too long to respond. Check that the selected AI service is running and try again."
        case .host(let message): return message
        }
    }
}

/// This UI is an independent native-host client, just like the tools that use MacHelper.
enum SettingsHostClient {
    static func listModels(settings: HelperSettings, executableURL: URL? = nil,
                           timeout: TimeInterval = 45) async throws -> SettingsModelCatalog {
        let settings = try settings.validated()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try requestModels(settings: settings, executableURL: executableURL, timeout: timeout)
                })
            }
        }
    }

    private struct Request: Encodable {
        let id: String
        let action = "listModels"
        let provider: String
        let model: String
        let baseURL: String
    }

    private struct Response: Decodable {
        let id: String
        let ok: Bool
        let models: [SettingsModelCatalog.Model]?
        let error: String?
    }

    private static func requestModels(settings: HelperSettings, executableURL: URL?,
                                      timeout: TimeInterval) throws -> SettingsModelCatalog {
        let installedHost = HelperSettingsStore.defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent("mac-helper-host")
        let developmentHost = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("mac-helper-host")
        let candidates = executableURL.map { [$0] } ?? [installedHost, developmentHost].compactMap { $0 }
        let executable = candidates
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { throw SettingsHostError.missingHost }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            // EOF lets the host cancel its active request and disconnect its AI child.
            // Keep stdout open during that grace period so teardown can finish normally.
            try? input.fileHandleForWriting.close()
            waitForExit(process, seconds: 0.3)
            if process.isRunning {
                process.terminate()
                waitForExit(process, seconds: 0.3)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        let id = UUID().uuidString
        let request = Request(id: id, provider: settings.provider.rawValue,
                              model: settings.model, baseURL: settings.baseURL)
        let deadline = DispatchTime.now() + (timeout.isFinite ? max(0.05, min(timeout, 45)) : 45)
        try writeAll(NativeFrameEncoder.encode(request), to: input.fileHandleForWriting.fileDescriptor,
                     deadline: deadline)
        let header = try readExactly(4, from: output.fileHandleForReading.fileDescriptor, deadline: deadline)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= NativeFrameDecoder.maximumFrameBytes else {
            throw SettingsHostError.invalidResponse
        }
        let data = try readExactly(Int(length), from: output.fileHandleForReading.fileDescriptor, deadline: deadline)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.id == id else { throw SettingsHostError.invalidResponse }
        guard response.ok else { throw SettingsHostError.host(response.error ?? "The AI service could not be reached.") }
        guard let models = response.models else { throw SettingsHostError.invalidResponse }
        return SettingsModelCatalog(models: models)
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) {
        let deadline = DispatchTime.now() + seconds
        while process.isRunning, DispatchTime.now() < deadline { usleep(10_000) }
    }

    private static func waitForIO(_ descriptor: Int32, events: Int16, deadline: DispatchTime) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw SettingsHostError.timedOut }
            let milliseconds = max(1, min(200, (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000))
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, Int32(milliseconds))
            if result < 0 {
                if errno == EINTR { continue }
                throw SettingsHostError.invalidResponse
            }
            if result == 0 { continue }
            guard pollDescriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw SettingsHostError.invalidResponse
            }
            // A hung-up read pipe must still be drained; read() then reports EOF.
            if pollDescriptor.revents & (events | Int16(POLLHUP)) != 0 { return }
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32,
                                    deadline: DispatchTime) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 16_384))
        while result.count < count {
            try waitForIO(descriptor, events: Int16(POLLIN), deadline: deadline)
            let needed = min(count - result.count, buffer.count)
            let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, needed) }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SettingsHostError.invalidResponse
            }
            guard received > 0 else { throw SettingsHostError.invalidResponse }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }

    private static func writeAll(_ data: Data, to descriptor: Int32,
                                 deadline: DispatchTime) throws {
        // A stalled helper may not read stdin. Nonblocking writes keep that path bounded too.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw SettingsHostError.invalidResponse
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                try waitForIO(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SettingsHostError.invalidResponse
                }
                guard written > 0 else { throw SettingsHostError.invalidResponse }
                offset += written
            }
        }
    }
}
