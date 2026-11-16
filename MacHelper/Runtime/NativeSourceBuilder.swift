import Foundation
import Darwin

public enum NativeSourceBuildError: LocalizedError, Equatable {
    case invalid(String)
    case compilerUnavailable
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .failed(let message): return message
        case .compilerUnavailable: return "Native source needs Apple's Swift command-line tools. Install them with Xcode or xcode-select --install, then reload this extension."
        case .timedOut: return "The native extension build took too long and was stopped. The last working version was preserved."
        }
    }
}

/// Builds a native source generation without reading its mutable working copy.
/// Only the fixed Swift toolchain and code-signing tools run; manifests cannot
/// inject compiler flags, shell commands, dependency installers or build hooks.
public struct NativeSourceBuilder: Sendable {
    public let sdkURL: URL
    public let cacheDirectory: URL
    private let timeout: TimeInterval

    public init(sdkURL: URL, cacheDirectory: URL, timeout: TimeInterval = 90) {
        self.sdkURL = sdkURL; self.cacheDirectory = cacheDirectory
        self.timeout = timeout.isFinite ? min(300, max(0.1, timeout)) : 90
    }

    public func build(snapshot: SourcePackageSnapshot) async throws -> URL {
        try Task.checkCancellation()
        let operation = NativeBuildOperation(sdkURL: sdkURL, cacheDirectory: cacheDirectory, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try operation.build(snapshot) }.value
        } onCancel: { operation.cancel() }
    }
}

private final class NativeBuildOperation: @unchecked Sendable {
    private let sdkURL: URL
    private let cacheDirectory: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var processID: pid_t?

    private struct Receipt: Codable {
        let schemaVersion: Int
        let key: String
        let binarySHA256: String
    }

    init(sdkURL: URL, cacheDirectory: URL, timeout: TimeInterval) {
        self.sdkURL = sdkURL; self.cacheDirectory = cacheDirectory; self.timeout = timeout
    }

    func cancel() {
        lock.lock(); cancelled = true; let current = processID; lock.unlock()
        if let current, current > 1 { _ = kill(-current, SIGTERM) }
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    func build(_ snapshot: SourcePackageSnapshot) throws -> URL {
        try checkCancellation()
        guard snapshot.manifest.runtime == "native", snapshot.manifest.permissions.contains("native.execute"),
              snapshot.manifest.entryPoint.hasSuffix(".swift"),
              snapshot.resources[snapshot.manifest.entryPoint]?.utf8.elementsEqual(snapshot.entrySource.utf8) == true else {
            throw NativeSourceBuildError.invalid("Only a validated native Swift source package can be compiled.")
        }
        guard snapshot.resources.keys.filter({ $0.hasSuffix(".swift") }).count == 1 else {
            throw NativeSourceBuildError.invalid("This native SDK version supports one Swift entry file. Keep the native implementation in its declared entryPoint.")
        }
        let sdkData = try regularData(sdkURL, maximum: 512 * 1024)
        guard String(data: sdkData, encoding: .utf8) != nil else { throw NativeSourceBuildError.invalid("The bundled native SDK is not valid UTF-8.") }
        let toolchain: Data
        do {
            let check = try command("/usr/bin/xcrun", ["swiftc", "--version"], timeout: min(15, timeout))
            guard check.status == 0, !check.output.isEmpty else { throw NativeSourceBuildError.compilerUnavailable }
            toolchain = check.output
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeSourceBuildError where error == .timedOut { throw error }
        catch { throw NativeSourceBuildError.compilerUnavailable }
        var keyData = Data("MacHelperNativeSDK-v1\0".utf8)
        keyData.append(Data(snapshot.entrySource.utf8)); keyData.append(0)
        keyData.append(sdkData); keyData.append(0); keyData.append(toolchain)
        #if arch(arm64)
        keyData.append(Data("arm64".utf8))
        #elseif arch(x86_64)
        keyData.append(Data("x86_64".utf8))
        #else
        throw NativeSourceBuildError.invalid("This Mac architecture is not supported by the native source builder.")
        #endif
        let key = SourcePackageRules.digest(keyData)
        try privateDirectory(cacheDirectory)
        let destination = cacheDirectory.appendingPathComponent(key, isDirectory: true)
        let executable = destination.appendingPathComponent("MacHelperNativeWorker")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try cachedExecutable(at: destination, key: key) else {
                throw NativeSourceBuildError.invalid("A cached native executable failed validation. Remove this extension's native build cache and reload; your editable source was preserved.")
            }
            return executable
        }
        let stage = cacheDirectory.appendingPathComponent(".build-" + UUID().uuidString, isDirectory: true)
        try privateDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let sdk = stage.appendingPathComponent("MacHelperNativeSDK.swift")
        let source = stage.appendingPathComponent("Extension.swift")
        let binary = stage.appendingPathComponent("MacHelperNativeWorker")
        try sdkData.write(to: sdk, options: [.atomic])
        try Data(snapshot.entrySource.utf8).write(to: source, options: [.atomic])
        for url in [sdk, source] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let build = try command("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-swift-version", "5",
            "-module-cache-path", stage.appendingPathComponent("ModuleCache").path,
            sdk.path, source.path, "-o", binary.path], timeout: timeout)
        guard build.status == 0 else {
            let diagnostic = compilerDiagnostic(build.output)
            throw NativeSourceBuildError.failed("The native extension could not compile. " + diagnostic)
        }
        try checkCancellation()
        _ = try regularData(binary, maximum: 64 * 1024 * 1024)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let signed = try command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", binary.path], timeout: min(15, timeout))
        guard signed.status == 0 else { throw NativeSourceBuildError.failed("The native worker could not be signed. The last working version was preserved.") }
        let verified = try command("/usr/bin/codesign", ["--verify", "--strict", binary.path], timeout: min(15, timeout))
        guard verified.status == 0 else { throw NativeSourceBuildError.failed("The native worker signature could not be verified.") }
        let receipt = Receipt(schemaVersion: 1, key: key, binarySHA256: SourcePackageRules.digest(try regularData(binary, maximum: 64 * 1024 * 1024)))
        let ready = stage.appendingPathComponent("ready", isDirectory: true)
        try privateDirectory(ready)
        try FileManager.default.moveItem(at: binary, to: ready.appendingPathComponent("MacHelperNativeWorker"))
        let receiptURL = ready.appendingPathComponent("receipt.json")
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        try checkCancellation()
        do { try FileManager.default.moveItem(at: ready, to: destination) }
        catch {
            // Two immutable generations may compile identical code concurrently.
            // Reuse only a completed independently verified cache entry.
            if FileManager.default.fileExists(atPath: destination.path), try cachedExecutable(at: destination, key: key) { return executable }
            throw error
        }
        return executable
    }

    private func cachedExecutable(at directory: URL, key: String) throws -> Bool {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let binary = directory.appendingPathComponent("MacHelperNativeWorker")
        let receipt = try JSONDecoder().decode(Receipt.self, from: regularData(directory.appendingPathComponent("receipt.json"), maximum: 8192))
        guard receipt.schemaVersion == 1, receipt.key == key,
              FileManager.default.isExecutableFile(atPath: binary.path),
              SourcePackageRules.digest(try regularData(binary, maximum: 64 * 1024 * 1024)) == receipt.binarySHA256 else { return false }
        return try command("/usr/bin/codesign", ["--verify", "--strict", binary.path], timeout: min(15, timeout)).status == 0
    }

    private func regularData(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximum else {
            throw NativeSourceBuildError.invalid("A native build input or executable is not a bounded regular file.")
        }
        let result = try Data(contentsOf: url)
        guard result.count <= maximum else { throw NativeSourceBuildError.invalid("A native build file exceeds its size limit.") }
        return result
    }

    private func privateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw NativeSourceBuildError.invalid("The native build cache must be an ordinary private directory.") }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func compilerDiagnostic(_ data: Data) -> String {
        // Retain a short reason, never source excerpts or the local build path.
        let text = String(data: data, encoding: .utf8) ?? ""
        let reasons = text.split(separator: "\n").compactMap { line -> String? in
            guard let marker = line.range(of: ": error: ") else { return nil }
            return String(line[marker.upperBound...].prefix(240))
        }
        return reasons.prefix(3).joined(separator: " ")
    }

    private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: Data) {
        try checkCancellation()
        let output = Pipe(), collector = NativeBuildOutput()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw NativeSourceBuildError.failed("The native build process could not be configured.")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let input = open("/dev/null", O_RDONLY)
        guard input >= 0 else { throw NativeSourceBuildError.failed("The native build input could not be configured.") }
        defer { _ = close(input) }
        posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, output.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, input)
        // The compiler driver may spawn frontend/linker children. A dedicated
        // process group makes cancellation terminate that whole build tree.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var pid: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        let launch = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        if launch == 0 { processID = pid }
        lock.unlock()
        guard launch == 0 else { throw NativeSourceBuildError.failed("The native build tool could not start.") }
        try? output.fileHandleForWriting.close()
        let readGroup = DispatchGroup(); readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                collector.append(data)
            }
            readGroup.leave()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var expired = false
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { break }
            lock.lock(); let isCancelled = cancelled; lock.unlock()
            if isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                expired = !isCancelled
                _ = kill(-pid, SIGTERM)
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                var reaped = false
                while ProcessInfo.processInfo.systemUptime < grace {
                    if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                _ = kill(-pid, SIGKILL)
                if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR { } }
                break
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
        lock.lock(); processID = nil; let wasCancelled = cancelled; lock.unlock()
        // No compiler subprocess may keep our capture pipe alive after exit.
        if kill(-pid, 0) == 0 { _ = kill(-pid, SIGKILL) }
        _ = readGroup.wait(timeout: .now() + 2)
        try? output.fileHandleForReading.close()
        if wasCancelled { throw CancellationError() }
        if expired { throw NativeSourceBuildError.timedOut }
        let code = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
        return (code, collector.data)
    }
}

private final class NativeBuildOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if value.count < 64 * 1024 { value.append(data.prefix(64 * 1024 - value.count)) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return value }
}
