import Darwin
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
    private static let updateCommitLock = NSLock()

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
        let candidate = try await download(entry: entry, baseURL: baseURL, to: stage)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { return try snapshot(for: entry.identifier) }
        return try activate(stage: stage, destination: destination, identifier: entry.identifier, hashes: candidate.fileHashes)
    }

    /// Staging leaves the installed working folder available while the caller
    /// validates settings, reviews permissions, and prepares the new worker.
    public func stageUpdate(entry: SourceCatalogEntry, baseURL: URL) async throws -> SourcePackageSnapshot {
        try entry.validate()
        let stage = try createStage(prefix: ".source-update-")
        do {
            let candidate = try await download(entry: entry, baseURL: baseURL, to: stage)
            try writeReceipt(for: candidate)
            try Task.checkCancellation()
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    public func discardStagedUpdate(_ staged: SourcePackageSnapshot) {
        guard ownsUpdateStage(staged.rootURL) else { return }
        try? FileManager.default.removeItem(at: staged.rootURL)
    }

    /// Replace the complete directory atomically and retain the previous source.
    /// `persist` must write the updated approvals atomically or throw.
    public func commitUpdate(_ staged: SourcePackageSnapshot, replacing expected: SourcePackageSnapshot,
                             persist: () throws -> Void) throws -> (snapshot: SourcePackageSnapshot, backupURL: URL) {
        Self.updateCommitLock.lock()
        defer { Self.updateCommitLock.unlock() }

        let identifier = staged.manifest.identifier
        let destination = try installedURL(for: identifier)
        guard ownsUpdateStage(staged.rootURL),
              expected.manifest.identifier == identifier,
              expected.rootURL.path == destination.standardizedFileURL.resolvingSymlinksInPath().path
        else { throw SourcePackageError.invalid("The update does not match this installed extension.") }
        guard SourcePackageRules.isNewerVersion(staged.manifest.version, than: expected.manifest.version) else {
            throw SourcePackageError.invalid("The catalog does not have a newer version of this extension.")
        }
        try Task.checkCancellation()
        _ = try verifiedUpdate(at: staged.rootURL, matching: staged)
        guard try snapshot(for: identifier).fingerprint == expected.fingerprint else {
            throw SourcePackageError.invalid("Installed source changed during the update. Try again after saving your files.")
        }

        // Move the candidate first so the stage path can never refer to the
        // user's previous working copy, even if rollback fails.
        let backup = directory.appendingPathComponent(".source-backup-" + identifier + "-" + UUID().uuidString,
                                                       isDirectory: true)
        let files = FileManager.default
        try files.moveItem(at: staged.rootURL, to: backup)
        var keepBackup = false
        defer { if !keepBackup { try? files.removeItem(at: backup) } }
        try swapSource(backup, destination)
        keepBackup = true
        do {
            let previous = try SourcePackageInspector.snapshot(at: backup)
            guard previous.fingerprint == expected.fingerprint else {
                throw SourcePackageError.invalid("Installed source changed during the update. Try again after saving your files.")
            }
            let installed = try verifiedUpdate(at: destination, matching: staged)
            try persist()
            return (installed, previous.rootURL)
        } catch {
            do {
                try swapSource(backup, destination)
                keepBackup = false
            } catch {
                throw SourcePackageError.invalid("The previous source could not be restored automatically. Its backup is at \(backup.path).")
            }
            throw error
        }
    }

    private func ownsUpdateStage(_ root: URL) -> Bool {
        let prefix = ".source-update-"
        return root.deletingLastPathComponent().path == directory.standardizedFileURL.resolvingSymlinksInPath().path
            && root.lastPathComponent.hasPrefix(prefix)
            && UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil
    }

    private func verifiedUpdate(at root: URL, matching staged: SourcePackageSnapshot) throws -> SourcePackageSnapshot {
        let candidate = try SourcePackageInspector.snapshot(at: root)
        let receiptURL = root.appendingPathComponent(SourcePackageRules.receiptName)
        let receipt = try JSONDecoder().decode(SourcePackageReceipt.self,
            from: SourcePackageRules.boundedData(receiptURL, maximum: 128 * 1024))
        guard candidate.manifest.identifier == staged.manifest.identifier,
              candidate.fingerprint == staged.fingerprint,
              receipt.identifier == candidate.manifest.identifier,
              receipt.version == candidate.manifest.version,
              receipt.hashes == candidate.fileHashes
        else { throw SourcePackageError.invalid("The downloaded update changed before it could be installed.") }
        return candidate
    }

    private func swapSource(_ first: URL, _ second: URL) throws {
        guard Darwin.renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func download(entry: SourceCatalogEntry, baseURL: URL, to stage: URL) async throws -> SourcePackageSnapshot {
        var hashes: [String: String] = [:]
        var total = 0
        for file in entry.files {
            try Task.checkCancellation()
            let data = try await transport.readSourceFile(file, relativeTo: baseURL, maximumBytes: SourcePackageRules.maximumFileBytes)
            total += data.count
            guard total <= SourcePackageRules.maximumPackageBytes else {
                throw SourcePackageError.invalid("The source package is too large.")
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
        return candidate
    }

    private func createStage(prefix: String = ".source-install-") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = directory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }
    private func activate(stage: URL, destination: URL, identifier: String, hashes: [String: String]) throws -> SourcePackageSnapshot {
        let candidate = try SourcePackageInspector.snapshot(at: stage)
        guard candidate.manifest.identifier == identifier, candidate.fileHashes == hashes else {
            throw SourcePackageError.invalid("The source package changed during installation.")
        }
        try writeReceipt(for: candidate)
        try FileManager.default.moveItem(at: stage, to: destination)
        return try SourcePackageInspector.snapshot(at: destination)
    }

    private func writeReceipt(for snapshot: SourcePackageSnapshot) throws {
        let receipt = SourcePackageReceipt(identifier: snapshot.manifest.identifier, version: snapshot.manifest.version,
                                           hashes: snapshot.fileHashes)
        let url = snapshot.rootURL.appendingPathComponent(SourcePackageRules.receiptName)
        try JSONEncoder().encode(receipt).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
