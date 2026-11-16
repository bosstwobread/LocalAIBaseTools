import Foundation

/// Public metadata only. Website locations come from the installed app, never
/// from a browser search request or an AI answer.
public struct DiscoveryConfiguration: Codable, Sendable {
    public let schemaVersion: Int
    public let websiteURL: String
    public static let defaultWebsite = "https://local-ai-extension.nelson007.com/"

    public init(websiteURL: String = Self.defaultWebsite) { schemaVersion = 1; self.websiteURL = websiteURL }

    public func validatedURL(allowLocalDevelopment: Bool = false) throws -> URL {
        guard schemaVersion == 1, websiteURL.utf8.count <= 2048,
              let parts = URLComponents(string: websiteURL), let url = parts.url,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !websiteURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw DiscoveryError.invalidCatalog }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host ?? "")
        guard (parts.scheme == "https" && parts.host?.isEmpty == false) ||
              (allowLocalDevelopment && ((parts.scheme == "http" && local) || url.isFileURL)) else { throw DiscoveryError.invalidCatalog }
        return url
    }

    static var installedDirectories: [URL] {
        var paths = [URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()]
        if let resources = Bundle.main.resourceURL { paths.append(resources.appendingPathComponent("Discovery")) }
        paths.append(paths[0].deletingLastPathComponent().appendingPathComponent("Resources/Discovery"))
        return paths
    }

    static func installed() throws -> DiscoveryConfiguration {
        for directory in installedDirectories {
            let file = directory.appendingPathComponent("discovery-config.json")
            if FileManager.default.fileExists(atPath: file.path) {
                return try JSONDecoder().decode(Self.self, from: SourcePackageRules.boundedData(file, maximum: 64 * 1024))
            }
        }
        return Self()
    }
}

public actor DiscoveryCatalogStore {
    public static let maximumIndexBytes = 16 * 1024 * 1024
    public static let maximumManifestBytes = 8 * 1024
    public static var defaultCacheDirectory: URL {
        HelperSettingsStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("Discovery", isDirectory: true)
    }
    private let manifestURL: URL?
    private let cacheDirectory: URL
    private let seedDirectories: [URL]
    private let transport: SourceDownloadTransport
    private var stale = true
    private var current: (DiscoveryIndex, Data, Data)?

    public init(manifestURL: URL? = nil, cacheDirectory: URL = DiscoveryCatalogStore.defaultCacheDirectory,
                seedDirectory: URL? = nil, session: URLSession = .shared, allowLocalDevelopment: Bool = false) {
        self.cacheDirectory = cacheDirectory
        seedDirectories = seedDirectory.map { [$0] } ?? DiscoveryConfiguration.installedDirectories
        transport = SourceDownloadTransport(session: session)
        do {
            if let manifestURL {
                var parts = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)
                guard manifestURL.lastPathComponent == "discovery-manifest.json", parts?.query == nil, parts?.fragment == nil else { throw DiscoveryError.invalidCatalog }
                parts?.path = manifestURL.deletingLastPathComponent().path + "/"
                _ = try DiscoveryConfiguration(websiteURL: parts?.url?.absoluteString ?? "").validatedURL(allowLocalDevelopment: allowLocalDevelopment)
                self.manifestURL = manifestURL
            } else {
                self.manifestURL = try DiscoveryConfiguration.installed().validatedURL().appendingPathComponent("discovery-manifest.json")
            }
        } catch { self.manifestURL = nil }
    }

    /// Refresh just the small revision manifest first. Reuse verified bytes if
    /// unchanged; a broken network update never replaces the last good index.
    public func load(refresh: Bool = true) async throws -> DiscoveryCatalogSnapshot {
        try Task.checkCancellation()
        if current == nil {
            if let candidate = try? Self.readCache(cacheDirectory) { current = candidate }
            for directory in seedDirectories {
                if let candidate = try? Self.readPair(directory) {
                    if current == nil || candidate.0.updatedAt > current!.0.updatedAt { current = candidate }
                }
            }
        }
        guard refresh else {
            guard let current else { throw DiscoveryError.unavailable }
            return .init(index: current.0, stale: stale)
        }
        do {
            guard let manifestURL else { throw DiscoveryError.invalidCatalog }
            let manifestBytes = try await transport.read(manifestURL, maximumBytes: Self.maximumManifestBytes)
            let manifest = try JSONDecoder().decode(DiscoveryManifest.self, from: manifestBytes)
            try manifest.validate()
            try Task.checkCancellation()
            if let current, manifest.revision == current.0.revision,
               manifest.sha256 == SourcePackageRules.digest(current.1), manifest.size == current.1.count,
               manifest.updatedAt == current.0.updatedAt { stale = false; return .init(index: current.0, stale: false) }
            let indexBytes = try await transport.read(manifestURL.deletingLastPathComponent().appendingPathComponent("discovery-index.json"), maximumBytes: Self.maximumIndexBytes)
            let candidate = try Self.decode(indexBytes, manifestBytes)
            try Task.checkCancellation()
            // Cache failure must not discard a valid in-memory download.
            try? persist(indexBytes, manifestBytes)
            current = candidate
            stale = false
            return .init(index: candidate.0, stale: false)
        } catch {
            try Task.checkCancellation()
            stale = true
            if let current { return .init(index: current.0, stale: true) }
            throw DiscoveryError.unavailable
        }
    }

    private static func readPair(_ directory: URL) throws -> (DiscoveryIndex, Data, Data) {
        try decode(SourcePackageRules.boundedData(directory.appendingPathComponent("discovery-index.json"), maximum: maximumIndexBytes),
                   SourcePackageRules.boundedData(directory.appendingPathComponent("discovery-manifest.json"), maximum: maximumManifestBytes))
    }
    private static func decode(_ bytes: Data, _ manifestBytes: Data) throws -> (DiscoveryIndex, Data, Data) {
        let manifest = try JSONDecoder().decode(DiscoveryManifest.self, from: manifestBytes)
        try manifest.validate()
        guard bytes.count == manifest.size, SourcePackageRules.digest(bytes) == manifest.sha256 else { throw DiscoveryError.invalidCatalog }
        let index = try JSONDecoder().decode(DiscoveryIndex.self, from: bytes)
        try index.validate()
        guard index.revision == manifest.revision, index.updatedAt == manifest.updatedAt else { throw DiscoveryError.invalidCatalog }
        return (index, bytes, manifestBytes)
    }
    private static func readCache(_ directory: URL) throws -> (DiscoveryIndex, Data, Data) {
        let bytes = try SourcePackageRules.boundedData(directory.appendingPathComponent("catalog-cache.bin"), maximum: maximumIndexBytes + maximumManifestBytes + 4)
        guard bytes.count >= 4 else { throw DiscoveryError.invalidCatalog }
        let length = bytes.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard length > 0, length <= maximumManifestBytes, bytes.count > 4 + length else { throw DiscoveryError.invalidCatalog }
        return try decode(Data(bytes.dropFirst(4 + length)), Data(bytes.dropFirst(4).prefix(length)))
    }
    private func persist(_ bytes: Data, _ manifestBytes: Data) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // One atomic envelope commits the hash manifest and its exact index
        // bytes together. Concurrent app/host writers cannot create torn pairs.
        var data = Data((0..<4).map { UInt8(truncatingIfNeeded: manifestBytes.count >> ($0 * 8)) })
        data.append(manifestBytes); data.append(bytes)
        let path = cacheDirectory.appendingPathComponent("catalog-cache.bin")
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
