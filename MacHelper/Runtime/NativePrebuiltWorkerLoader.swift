import Darwin
import Foundation
import MachO

public enum NativePrebuiltWorkerError: LocalizedError, Equatable {
    case incompatible
    case download
    case verification

    public var errorDescription: String? {
        switch self {
        case .incompatible: return L("The prebuilt native worker is incompatible with this Mac.")
        case .download: return L("The prebuilt native worker could not be downloaded.")
        case .verification: return L("The prebuilt native worker could not be verified.")
        }
    }
}

/// Verifies the immutable publisher artifact before allowing the shared worker
/// lifecycle to launch it. The editable source remains a regular source package.
public struct NativePrebuiltWorkerLoader: Sendable {
    private let cacheDirectory: URL
    private let download: @Sendable (URL, Int) async throws -> Data
    private let verifySignature: @Sendable (URL, String) async throws -> Void

    public init(cacheDirectory: URL, session: URLSession = .shared) {
        let transport = SourceDownloadTransport(session: session)
        self.init(cacheDirectory: cacheDirectory, download: { try await transport.read($0, maximumBytes: $1) },
                  verifySignature: { try await Self.verifyAppleSignature($0, teamIdentifier: $1) })
    }

    init(cacheDirectory: URL, download: @escaping @Sendable (URL, Int) async throws -> Data,
         verifySignature: @escaping @Sendable (URL, String) async throws -> Void) {
        self.cacheDirectory = cacheDirectory
        self.download = download
        self.verifySignature = verifySignature
    }

    public func load(snapshot: SourcePackageSnapshot) async throws -> URL {
        try Task.checkCancellation()
        guard snapshot.manifest.runtime == "native", snapshot.manifest.permissions.contains("native.execute"),
              let descriptor = snapshot.matchingPrebuiltWorker, let address = URL(string: descriptor.url) else {
            throw NativePrebuiltWorkerError.verification
        }
        try descriptor.validate()
        guard descriptor.architecture == Self.architecture, let minimum = descriptor.packedMinimumOSVersion,
              minimum <= Self.currentOSVersion else { throw NativePrebuiltWorkerError.incompatible }

        try prepareCacheDirectory()
        let destination = cacheDirectory.appendingPathComponent(descriptor.sha256, isDirectory: true)
        let executable = destination.appendingPathComponent("MacHelperNativeWorker")
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            try verifyPrivateDirectory(destination)
            try await verifyCached(executable, descriptor: descriptor)
            return executable
        }
        guard errno == ENOENT else { throw NativePrebuiltWorkerError.verification }

        let bytes: Data
        do { bytes = try await download(address, descriptor.size) }
        catch {
            try Task.checkCancellation()
            throw NativePrebuiltWorkerError.download
        }
        try Task.checkCancellation()
        try Self.verifyArtifact(bytes, descriptor: descriptor)

        let stage = cacheDirectory.appendingPathComponent(".candidate-" + UUID().uuidString, isDirectory: true)
        let temporary = stage.appendingPathComponent("MacHelperNativeWorker")
        guard mkdir(stage.path, 0o700) == 0 else { throw NativePrebuiltWorkerError.verification }
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            try bytes.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temporary.path)
        } catch { throw NativePrebuiltWorkerError.verification }
        try await verifySignature(temporary, descriptor.teamIdentifier)
        try Task.checkCancellation()
        if renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return executable }
        guard errno == EEXIST else { throw NativePrebuiltWorkerError.verification }
        try verifyPrivateDirectory(destination)
        try await verifyCached(executable, descriptor: descriptor)
        return executable
    }

    private func prepareCacheDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw NativePrebuiltWorkerError.verification }
        guard mkdir(cacheDirectory.path, 0o700) == 0 || errno == EEXIST else {
            throw NativePrebuiltWorkerError.verification
        }
        try verifyPrivateDirectory(cacheDirectory)
    }

    private func verifyPrivateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700 else {
            throw NativePrebuiltWorkerError.verification
        }
    }

    private func verifyCached(_ executable: URL, descriptor: SourcePrebuiltWorker) async throws {
        let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativePrebuiltWorkerError.verification }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o500,
              info.st_size == descriptor.size,
              let bytes = try? file.read(upToCount: descriptor.size + 1) else {
            throw NativePrebuiltWorkerError.verification
        }
        try Self.verifyArtifact(bytes, descriptor: descriptor)
        try await verifySignature(executable, descriptor.teamIdentifier)
        try Task.checkCancellation()
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }

    private static var currentOSVersion: UInt32 {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return UInt32(clamping: version.majorVersion) << 16 | UInt32(clamping: version.minorVersion) << 8 |
            UInt32(clamping: version.patchVersion)
    }

    static func verifyArtifact(_ data: Data, descriptor: SourcePrebuiltWorker) throws {
        guard data.count == descriptor.size, SourcePackageRules.digest(data) == descriptor.sha256,
              let version = embeddedMinimumVersion(in: data, architecture: descriptor.architecture),
              version == descriptor.packedMinimumOSVersion else { throw NativePrebuiltWorkerError.verification }
    }

    private static func embeddedMinimumVersion(in data: Data, architecture: String) -> UInt32? {
        // The descriptor names one architecture. Reject universal binaries,
        // non-executables, and load commands for a different Apple platform.
        let headerSize = MemoryLayout<mach_header_64>.size
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { bytes -> UInt32? in
            func word(at offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard word(at: 0) == MH_MAGIC_64, word(at: 12) == MH_EXECUTE else { return nil }
            let cpu = architecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
            guard word(at: 4) == UInt32(bitPattern: cpu) else { return nil }
            let count = Int(word(at: 16)), size = Int(word(at: 20))
            guard size <= data.count - headerSize, count <= size / 8 else { return nil }
            let end = headerSize + size
            var offset = headerSize
            var minimum: UInt32?
            for _ in 0..<count {
                guard offset <= end - 8 else { return nil }
                let command = word(at: offset), length = Int(word(at: offset + 4))
                guard length >= 8, length.isMultiple(of: 8), length <= end - offset else { return nil }
                switch command {
                case UInt32(LC_BUILD_VERSION):
                    guard length >= 24, minimum == nil, word(at: offset + 8) == UInt32(PLATFORM_MACOS) else { return nil }
                    minimum = word(at: offset + 12)
                case UInt32(LC_VERSION_MIN_MACOSX):
                    guard length == 16, minimum == nil else { return nil }
                    minimum = word(at: offset + 8)
                default: break
                }
                offset += length
            }
            return offset == end ? minimum : nil
        }
    }

    static func verifyAppleSignature(_ executable: URL, teamIdentifier: String) async throws {
        // Apple documents the `notarized` requirement for standalone command-line
        // tools, whose tickets cannot be stapled to the executable itself.
        let requirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\" and notarized"
        let runner = NativeWorkerCommand()
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try runner.run("/usr/bin/codesign", ["--verify", "--strict", "-R=" + requirement, executable.path], timeout: 30)
                }.value
            } onCancel: { runner.cancel() }
            try Task.checkCancellation()
            guard result.status == 0 else { throw NativePrebuiltWorkerError.verification }
        } catch {
            try Task.checkCancellation()
            throw NativePrebuiltWorkerError.verification
        }
    }
}
