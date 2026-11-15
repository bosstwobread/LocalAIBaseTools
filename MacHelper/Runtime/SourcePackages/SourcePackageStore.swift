import Foundation

public struct SourcePackageDiscoveryIssue: Sendable {
    public let rootURL: URL
    public let identifier: String?
    public let message: String
}

public struct SourcePackageDiscovery: Sendable {
    public let packages: [SourcePackageSnapshot]
    public let issues: [SourcePackageDiscoveryIssue]
}

public struct SourcePackageStore: @unchecked Sendable {
    public static var defaultUserDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalAIBaseTools/Extensions", isDirectory: true)
    }
    public let directory: URL
    private let transport: SourceDownloadTransport
    public init(directory: URL = Self.defaultUserDirectory, session: URLSession = .shared) {
        self.directory = directory; transport = SourceDownloadTransport(session: session)
    }
    public func installedURL(for identifier: String) throws -> URL {
        try SourcePackageRules.validateIdentifier(identifier)
        return directory.appendingPathComponent(identifier + ".macsource", isDirectory: true)
    }
    public func snapshot(for identifier: String) throws -> SourcePackageSnapshot {
        let result = try SourcePackageInspector.snapshot(at: installedURL(for: identifier))
        guard result.manifest.identifier == identifier else { throw SourcePackageError.invalid("The installed source package identifier changed. Restore its original identifier.") }
        return result
    }
    public func installedPackages() throws -> [SourcePackageSnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "macsource" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try SourcePackageInspector.snapshot(at: $0) }
    }

    /// An in-progress or broken edit in one package must not hide other tools.
    public func discoverInstalled() -> SourcePackageDiscovery {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .init(packages: [], issues: []) }
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "macsource" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch { return .init(packages: [], issues: [.init(rootURL: directory, identifier: nil, message: error.localizedDescription)]) }
        var packages: [SourcePackageSnapshot] = []
        var issues: [SourcePackageDiscoveryIssue] = []
        for root in candidates {
            let folderID = root.deletingPathExtension().lastPathComponent
            let identifier = (try? SourcePackageRules.validateIdentifier(folderID)) != nil ? folderID : nil
            do {
                let package = try SourcePackageInspector.snapshot(at: root)
                guard package.manifest.identifier == folderID else {
                    throw SourcePackageError.invalid("The source folder name no longer matches its extension identifier.")
                }
                packages.append(package)
            } catch { issues.append(.init(rootURL: root, identifier: identifier, message: error.localizedDescription)) }
        }
        return .init(packages: packages, issues: issues)
    }

    /// Imports an entire source tree without replacing an existing editable copy.
    public func importSource(from input: URL) throws -> SourcePackageSnapshot {
        let source = try SourcePackageInspector.snapshot(at: input)
        let destination = try installedURL(for: source.manifest.identifier)
        if source.rootURL == destination.standardizedFileURL.resolvingSymlinksInPath() { return source }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SourcePackageError.invalid("This extension already has editable source installed. Your changes were preserved; open its source folder instead.")
        }
        let stage = try createStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        for path in source.fileHashes.keys.sorted() {
            let target = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let original = try SourcePackageRules.containedURL(path, root: source.rootURL)
            let data = try SourcePackageRules.boundedData(original)
            guard SourcePackageRules.digest(data) == source.fileHashes[path] else {
                throw SourcePackageError.invalid("The source changed during import. Try again after saving your files.")
            }
            try data.write(to: target, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        return try activate(stage: stage, destination: destination, identifier: source.manifest.identifier, hashes: source.fileHashes)
    }

    /// Enabling an unavailable tool materializes every catalog file first. An
    /// existing copy is always retained, even if upstream version/hash changed.
    public func materialize(entry: SourceCatalogEntry, baseURL: URL) async throws -> SourcePackageSnapshot {
        try entry.validate()
        let destination = try installedURL(for: entry.identifier)
        if FileManager.default.fileExists(atPath: destination.path) { return try snapshot(for: entry.identifier) }
        let stage = try createStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        var hashes: [String: String] = [:]
        var total = 0
        for file in entry.files {
            try Task.checkCancellation()
            guard let url = URL(string: file.url, relativeTo: baseURL)?.absoluteURL else { throw SourcePackageError.invalid("A catalog file URL is invalid.") }
            if !baseURL.isFileURL {
                guard !url.isFileURL else { throw SourcePackageError.invalid("A remote catalog cannot read local files.") }
                let localBase = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host?.lowercased() ?? "")
                try SourceDownloadTransport.validateURL(url, localBaseAllowed: localBase)
            }
            let data = try await transport.read(url, maximumBytes: SourcePackageRules.maximumFileBytes)
            total += data.count
            guard total <= SourcePackageRules.maximumPackageBytes,
                  SourcePackageRules.digest(data) == file.sha256.lowercased(), file.size.map({ $0 == data.count }) ?? true else {
                throw SourcePackageError.invalid("A downloaded source file failed its SHA-256/size check. No partial extension was installed.")
            }
            let target = stage.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: target, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            hashes[file.path] = file.sha256.lowercased()
        }
        let candidate = try SourcePackageInspector.snapshot(at: stage)
        guard candidate.manifest.identifier == entry.identifier, candidate.manifest.version == entry.version,
              candidate.manifest.displayName == entry.displayName, candidate.manifest.summary == entry.summary,
              candidate.fileHashes == hashes else { throw SourcePackageError.invalid("The downloaded source manifest does not match its catalog entry.") }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { return try snapshot(for: entry.identifier) }
        return try activate(stage: stage, destination: destination, identifier: entry.identifier, hashes: hashes)
    }

    private func createStage() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = directory.appendingPathComponent(".source-install-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }
    private func activate(stage: URL, destination: URL, identifier: String, hashes: [String: String]) throws -> SourcePackageSnapshot {
        let candidate = try SourcePackageInspector.snapshot(at: stage)
        guard candidate.manifest.identifier == identifier, candidate.fileHashes == hashes else {
            throw SourcePackageError.invalid("The source package changed during installation.")
        }
        let receipt = SourcePackageReceipt(identifier: identifier, version: candidate.manifest.version, hashes: hashes)
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent(SourcePackageRules.receiptName), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(SourcePackageRules.receiptName).path)
        try FileManager.default.moveItem(at: stage, to: destination)
        return try SourcePackageInspector.snapshot(at: destination)
    }
}
