import Foundation
import MachO
import XCTest
@testable import MacHelper

final class NativePrebuiltWorkerLoaderTests: XCTestCase {
    private let source = Data("// Public synthetic Swift entry fixture\n".utf8)
    private let team = "EXAMPLE123"

    func testManifestAndInstalledSourceSelection() throws {
        let root = try makeDirectory()
        let descriptor = worker(for: artifact())
        let authored = try package(in: root, descriptor: descriptor)
        XCTAssertEqual(authored.matchingPrebuiltWorker, descriptor)
        XCTAssertThrowsError(try manifest(descriptor, runtime: "javascript").validate())
        XCTAssertThrowsError(try worker(for: artifact(), version: "14.x").validate())
        XCTAssertThrowsError(try worker(for: artifact(), protocolVersion: 2).validate())
        XCTAssertThrowsError(try worker(for: artifact(), sourceHash: String(repeating: "A", count: 64)).validate())
        for url in ["https://example.com/worker", descriptor.url + "?q=1", descriptor.url + "/..",
                    descriptor.url.replacingOccurrences(of: "/fixture/", with: "/fixture.git/"),
                    descriptor.url.replacingOccurrences(of: String(repeating: "a", count: 40), with: "main")] {
            XCTAssertThrowsError(try worker(for: artifact(), url: url).validate())
        }

        let installed = try SourcePackageStore(directory: root.appendingPathComponent("Installed")).importSource(from: authored.rootURL)
        let prompt = installed.rootURL.appendingPathComponent("prompt.txt")
        try Data("A local prompt edit.\n".utf8).write(to: prompt)
        XCTAssertEqual(try SourcePackageInspector.snapshot(at: installed.rootURL).matchingPrebuiltWorker, descriptor)
        let edited = Data("// A local Swift edit.\n".utf8)
        try edited.write(to: installed.rootURL.appendingPathComponent("Main.swift"))
        XCTAssertNil(try SourcePackageInspector.snapshot(at: installed.rootURL).matchingPrebuiltWorker)

        try edited.write(to: authored.rootURL.appendingPathComponent("Main.swift"))
        XCTAssertThrowsError(try SourcePackageInspector.snapshot(at: authored.rootURL), "A release with an incorrect entry digest must not select compilation.")
    }

    func testVerifiedArtifactCommitsAtomicallyAndCacheHitRechecksSignatureAndBytes() async throws {
        let root = try makeDirectory()
        let bytes = artifact(), descriptor = worker(for: bytes)
        let snapshot = try package(in: root, descriptor: descriptor)
        let probe = Probe(bytes: bytes)
        let cache = root.appendingPathComponent("Prebuilt")
        let loader = NativePrebuiltWorkerLoader(cacheDirectory: cache, download: { try await probe.download($0, limit: $1) },
                                               verifySignature: { try await probe.verify($0, team: $1) })
        let executable = try await loader.load(snapshot: snapshot)
        let cached = try await loader.load(snapshot: snapshot)
        XCTAssertEqual(cached, executable)
        XCTAssertEqual(try Data(contentsOf: executable), bytes)
        XCTAssertEqual(executable.lastPathComponent, "MacHelperNativeWorker")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [descriptor.sha256])
        let downloads = await probe.downloads
        let signatures = await probe.signatures
        XCTAssertEqual(downloads, [descriptor.url])
        XCTAssertEqual(signatures, [team, team])

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        try Data(repeating: 0, count: bytes.count).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: executable.path)
        await assertLoadFailure(loader, snapshot: snapshot, error: .verification)
        let afterTamper = await probe.downloads
        XCTAssertEqual(afterTamper, downloads)
    }

    func testRejectsIncompatibleHostAndFailsClosedOnVerificationError() async throws {
        let root = try makeDirectory()
        let bytes = artifact(), descriptor = worker(for: bytes)
        let probe = Probe(bytes: bytes, signatureValid: false)
        let cache = root.appendingPathComponent("Prebuilt")
        let loader = NativePrebuiltWorkerLoader(cacheDirectory: cache, download: { try await probe.download($0, limit: $1) },
                                               verifySignature: { try await probe.verify($0, team: $1) })
        let incompatible = try package(in: root, descriptor: worker(for: bytes, version: "99.0"))
        await assertLoadFailure(loader, snapshot: incompatible, error: .incompatible)
        let calls = await probe.downloads
        XCTAssertEqual(calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let unsigned = try package(in: root, descriptor: descriptor)
        await assertLoadFailure(loader, snapshot: unsigned, error: .verification)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testMachOChecksRejectWrongCPUPlatformDeploymentTargetAndMalformedCommand() throws {
        let cpu = NativePrebuiltWorkerLoader.architecture == "arm64" ? CPU_TYPE_X86_64 : CPU_TYPE_ARM64
        for bytes in [artifact(cpu: cpu), artifact(platform: UInt32(PLATFORM_IOS)), artifact(minimum: 13 << 16),
                      artifact(commandSize: 4), Data(repeating: 0, count: 40)] {
            XCTAssertThrowsError(try NativePrebuiltWorkerLoader.verifyArtifact(bytes, descriptor: worker(for: bytes)))
        }
    }

    func testAppleVerificationRejectsExecutableWithoutMatchingNotarizedDeveloperID() async throws {
        do {
            try await NativePrebuiltWorkerLoader.verifyAppleSignature(URL(fileURLWithPath: "/usr/bin/true"), teamIdentifier: team)
            XCTFail("An unrelated Apple executable must fail the exact signer and notarization requirement.")
        } catch { XCTAssertEqual(error as? NativePrebuiltWorkerError, .verification) }
    }

    private func assertLoadFailure(_ loader: NativePrebuiltWorkerLoader, snapshot: SourcePackageSnapshot,
                                   error expected: NativePrebuiltWorkerError, line: UInt = #line) async {
        do { _ = try await loader.load(snapshot: snapshot); XCTFail("A worker passed validation unexpectedly.", line: line) }
        catch { XCTAssertEqual(error as? NativePrebuiltWorkerError, expected, line: line) }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func package(in root: URL, descriptor: SourcePrebuiltWorker) throws -> SourcePackageSnapshot {
        let package = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try source.write(to: package.appendingPathComponent("Main.swift"))
        try JSONEncoder().encode(manifest(descriptor)).write(to: package.appendingPathComponent("extension.json"))
        return try SourcePackageInspector.snapshot(at: package)
    }

    private func manifest(_ descriptor: SourcePrebuiltWorker, runtime: String = "native") -> SourceExtensionManifest {
        SourceExtensionManifest(runtime: runtime, identifier: "com.example.prebuilt-test", displayName: "Fixture",
            version: "1.0.0", summary: "Synthetic worker fixture", entryPoint: runtime == "native" ? "Main.swift" : "main.js",
            permissions: runtime == "native" ? ["native.execute"] : [],
            commands: [.init(identifier: "status", title: "Status", trigger: "manual")], prebuiltWorker: descriptor)
    }

    private func worker(for bytes: Data, version: String = "14.0", protocolVersion: Int = 1,
                        sourceHash: String? = nil, url: String? = nil) -> SourcePrebuiltWorker {
        SourcePrebuiltWorker(url: url ?? "https://raw.githubusercontent.com/example/fixture/\(String(repeating: "a", count: 40))/worker",
            sha256: SourcePackageRules.digest(bytes), size: bytes.count, sourceSHA256: sourceHash ?? SourcePackageRules.digest(source),
            teamIdentifier: team, architecture: NativePrebuiltWorkerLoader.architecture,
            minimumOSVersion: version, protocolVersion: protocolVersion)
    }

    private func artifact(cpu: cpu_type_t? = nil, platform: UInt32 = UInt32(PLATFORM_MACOS),
                          minimum: UInt32 = 14 << 16, commandSize: UInt32 = 24) -> Data {
        let host = NativePrebuiltWorkerLoader.architecture == "arm64" ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
        let words: [UInt32] = [MH_MAGIC_64, UInt32(bitPattern: cpu ?? host), 0, UInt32(MH_EXECUTE), 1, 24, 0, 0,
                               UInt32(LC_BUILD_VERSION), commandSize, platform, minimum, 0, 0]
        return words.reduce(into: Data()) { data, word in
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    private actor Probe {
        let bytes: Data
        let signatureValid: Bool
        var downloads: [String] = []
        var signatures: [String] = []

        init(bytes: Data, signatureValid: Bool = true) { self.bytes = bytes; self.signatureValid = signatureValid }

        func download(_ address: URL, limit: Int) throws -> Data {
            downloads.append(address.absoluteString)
            guard limit == bytes.count else { throw NativePrebuiltWorkerError.download }
            return bytes
        }

        func verify(_ url: URL, team: String) throws {
            signatures.append(team)
            guard signatureValid, try Data(contentsOf: url) == bytes else { throw NativePrebuiltWorkerError.verification }
        }
    }
}
