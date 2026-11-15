import Darwin
import Foundation

public enum BrowserSupportError: LocalizedError, Equatable {
    case notInstalled
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Move MacHelper.app into Applications or Applications/LocalAIBaseTools, then open it again to install browser support. The app will not move itself."
        case .invalid(let text): return text
        }
    }
}

public struct BrowserSupportInstallation: Sendable {
    public let binaryURL: URL
    public let manifestURLs: [URL]
    public let extensionIDs: [String]
}

/// Installs the embedded native host for this user without a repository, Python,
/// Xcode, or administrator privileges. AI settings are never read or modified.
public struct BrowserSupportInstaller: Sendable {
    public static let hostName = "com.localaibasetools.mac_helper"
    public static let legacyHostName = "com.messagehelper.gpt"
    public static let defaultExtensionID = "fmhfobfddchbeibojepeocgfemkpcklo"
    private static let supportPath = "Library/Application Support"
    private static let helperPath = supportPath + "/LocalAIBaseTools/MacHelper"
    private static let browserPaths = [supportPath + "/Google/Chrome/NativeMessagingHosts", supportPath + "/Microsoft Edge/NativeMessagingHosts"]
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public static func isInstalledApplication(_ appURL: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let app = appURL.standardizedFileURL
        guard app.pathExtension == "app" else { return false }
        let parent = app.deletingLastPathComponent()
        return [homeDirectory.appendingPathComponent("Applications"), homeDirectory.appendingPathComponent("Applications/LocalAIBaseTools"),
                URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/LocalAIBaseTools")]
            .map { $0.standardizedFileURL.path }.contains(parent.path)
    }

    public func install(from appURL: URL, additionalExtensionIDs: [String] = []) throws -> BrowserSupportInstallation {
        guard Self.isInstalledApplication(appURL, homeDirectory: homeDirectory) else { throw BrowserSupportError.notInstalled }
        guard additionalExtensionIDs.count <= 128, additionalExtensionIDs.allSatisfy(Self.validID) else {
            throw BrowserSupportError.invalid("A browser extension ID must contain exactly 32 lowercase letters from a through p.")
        }
        let app = appURL.standardizedFileURL
        let applications: URL
        let relativeApp: String
        let homeApps = homeDirectory.appendingPathComponent("Applications").standardizedFileURL
        if app.path.hasPrefix(homeApps.path + "/") {
            applications = homeApps
            relativeApp = String(app.path.dropFirst(homeApps.path.count + 1))
        } else {
            applications = URL(fileURLWithPath: "/Applications")
            relativeApp = String(app.path.dropFirst(applications.path.count + 1))
        }
        let sourceRoot = try BrowserSafeDirectory(root: applications)
        guard let source = try sourceRoot.read(relativeApp + "/Contents/MacOS/mac-helper-host", maximum: 64 * 1024 * 1024, requireUserOwner: false, executable: true) else {
            throw BrowserSupportError.invalid("This MacHelper app does not contain its browser helper. Download a complete MacHelper release.")
        }
        let home = try BrowserSafeDirectory(root: homeDirectory)
        let currentConfig = Self.helperPath + "/allowed-extension-ids.json"
        let legacyConfig = Self.supportPath + "/MessageHelper/allowed-extension-ids.json"
        var ids = Set([Self.defaultExtensionID] + additionalExtensionIDs)
        let current = try home.read(currentConfig, maximum: 64 * 1024)
        let previous = try current ?? home.read(legacyConfig, maximum: 64 * 1024)
        if let data = previous {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String], existing.count <= 128,
                  existing.allSatisfy(Self.validID) else {
                throw BrowserSupportError.invalid("The existing browser extension allowlist is invalid. It was preserved; review it before installing browser support.")
            }
            ids.formUnion(existing)
        }
        let binaryURL = homeDirectory.appendingPathComponent(Self.helperPath + "/mac-helper-host")
        let ownedPaths = Set([binaryURL.path,
            homeDirectory.appendingPathComponent(Self.supportPath + "/MessageHelper/messagehelper-host").path,
            homeDirectory.appendingPathComponent(Self.supportPath + "/MessageHelper/message-helper-host").path,
            homeDirectory.appendingPathComponent(Self.supportPath + "/MessageHelper/MessageHelperHost").path])
        let manifestPaths = Self.browserPaths.flatMap { folder in
            [Self.hostName, Self.legacyHostName].map { (folder + "/" + $0 + ".json", $0) }
        }
        // Preflight every registration before replacing a binary or allowlist.
        // A dedicated filename alone does not establish ownership of custom code.
        for (path, name) in manifestPaths {
            if let data = try home.read(path, maximum: 64 * 1024) {
                guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["name"] as? String == name, value["type"] as? String == "stdio",
                      let executable = value["path"] as? String, ownedPaths.contains(executable),
                      let origins = value["allowed_origins"] as? [String], origins.count <= 128 else {
                    throw BrowserSupportError.invalid("An existing browser registration uses a custom or unrelated helper. It was preserved; review it before installing browser support.")
                }
                for origin in origins {
                    guard origin.hasPrefix("chrome-extension://"), origin.hasSuffix("/") else {
                        throw BrowserSupportError.invalid("An existing browser registration has invalid allowed origins. It was preserved.")
                    }
                    let id = String(origin.dropFirst("chrome-extension://".count).dropLast())
                    guard Self.validID(id) else { throw BrowserSupportError.invalid("An existing browser registration has invalid allowed origins. It was preserved.") }
                }
            }
        }
        guard ids.count <= 128 else { throw BrowserSupportError.invalid("The browser extension allowlist exceeds its size limit.") }
        // Validate the old destination too, even though rename never follows a
        // final symlink. No registration can redirect writes outside this home.
        _ = try home.read(Self.helperPath + "/mac-helper-host", maximum: 64 * 1024 * 1024)
        let orderedIDs = ids.sorted()
        let allowed = try JSONSerialization.data(withJSONObject: orderedIDs, options: [.prettyPrinted, .sortedKeys])
        var registrations: [(String, Data)] = []
        for (path, name) in manifestPaths {
            let value: [String: Any] = ["name": name, "description": "LocalAIBaseTools MacHelper shared local AI bridge",
                "path": binaryURL.path, "type": "stdio", "allowed_origins": orderedIDs.map { "chrome-extension://" + $0 + "/" }]
            registrations.append((path, try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])))
        }
        try home.makePrivateDirectory(Self.helperPath)
        try home.write(source, path: Self.helperPath + "/mac-helper-host", mode: 0o700)
        try home.write(allowed, path: currentConfig, mode: 0o600)
        for (path, data) in registrations { try home.write(data, path: path, mode: 0o600) }
        return BrowserSupportInstallation(binaryURL: binaryURL, manifestURLs: manifestPaths.map { homeDirectory.appendingPathComponent($0.0) }, extensionIDs: orderedIDs)
    }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }
}

/// Descriptor-relative traversal rejects symlinks at every directory/file edge.
/// Atomic rename publishes each complete file while existing browser processes
/// can finish using the previous executable. No subprocess is launched here.
private final class BrowserSafeDirectory {
    private let descriptor: Int32
    private let url: URL
    init(root: URL) throws {
        url = root.standardizedFileURL
        descriptor = Darwin.open(root.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("open directory for search", at: root, code: errno) }
    }
    private init(descriptor: Int32, url: URL) { self.descriptor = descriptor; self.url = url }
    deinit { Darwin.close(descriptor) }

    private static func failure(_ operation: String, at url: URL, code: Int32? = nil, reason: String? = nil) -> BrowserSupportError {
        var message = "Browser support could not \(operation).\nPath: \(url.path)"
        if let code { message += "\nmacOS error \(code): \(String(cString: strerror(code)))" }
        if let reason { message += "\n" + reason }
        if code == EPERM || code == EACCES {
            message += "\nmacOS or folder permissions denied this access. Translation can continue without browser support; no privacy permission has been changed."
        }
        return .invalid(message)
    }

    private func directory(_ pieces: ArraySlice<String>, create: Bool) throws -> BrowserSafeDirectory? {
        defer { withExtendedLifetime(self) {} }
        var current = Darwin.dup(descriptor)
        guard current >= 0 else { throw Self.failure("duplicate directory handle", at: url, code: errno) }
        var currentURL = url
        defer { Darwin.close(current) }
        for piece in pieces {
            guard !piece.isEmpty, piece != ".", piece != "..", !piece.contains("/") else {
                throw Self.failure("validate directory path", at: currentURL, reason: "The directory path contains an unsafe component.")
            }
            let nextURL = currentURL.appendingPathComponent(piece, isDirectory: true)
            // Traversal needs search permission, not permission to read a
            // browser's profile directory or enumerate any of its contents.
            var next = Darwin.openat(current, piece, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { return nil }
                guard Darwin.mkdirat(current, piece, 0o700) == 0 || errno == EEXIST else {
                    throw Self.failure("create directory", at: nextURL, code: errno)
                }
                next = Darwin.openat(current, piece, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw Self.failure("open directory for search without following links", at: nextURL, code: errno) }
            Darwin.close(current); current = next
            currentURL = nextURL
        }
        let result = Darwin.dup(current)
        guard result >= 0 else { throw Self.failure("duplicate directory handle", at: currentURL, code: errno) }
        _ = fcntl(result, F_SETFD, FD_CLOEXEC)
        return BrowserSafeDirectory(descriptor: result, url: currentURL)
    }

    func makePrivateDirectory(_ path: String) throws {
        defer { withExtendedLifetime(self) {} }
        let target = url.appendingPathComponent(path, isDirectory: true)
        guard let directory = try directory(path.split(separator: "/").map(String.init)[...], create: true) else {
            throw Self.failure("create private helper directory", at: target)
        }
        defer { withExtendedLifetime(directory) {} }
        var attributes = stat()
        guard fstat(directory.descriptor, &attributes) == 0 else { throw Self.failure("inspect helper directory", at: target, code: errno) }
        guard attributes.st_uid == geteuid() else {
            throw Self.failure("validate helper directory ownership", at: target, reason: "The directory must be owned by the current user.")
        }
        guard fchmod(directory.descriptor, 0o700) == 0 else { throw Self.failure("set private helper directory permissions", at: target, code: errno) }
    }

    func read(_ path: String, maximum: Int, requireUserOwner: Bool = true, executable: Bool = false) throws -> Data? {
        defer { withExtendedLifetime(self) {} }
        let pieces = path.split(separator: "/").map(String.init)
        let target = url.appendingPathComponent(path)
        guard let name = pieces.last, let parent = try directory(pieces.dropLast(), create: false) else { return nil }
        // A copied Int32 descriptor does not retain the object that owns it.
        // Keep that owner alive across native calls in optimized app builds.
        defer { withExtendedLifetime(parent) {} }
        let file = Darwin.openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw Self.failure("open file without following links", at: target, code: errno) }
        defer { Darwin.close(file) }
        var attributes = stat()
        guard fstat(file, &attributes) == 0 else { throw Self.failure("inspect file", at: target, code: errno) }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw Self.failure("validate file type", at: target, reason: "Only a regular file is permitted.")
        }
        guard !requireUserOwner || attributes.st_uid == geteuid() else {
            throw Self.failure("validate file ownership", at: target, reason: "The file must be owned by the current user.")
        }
        guard attributes.st_size >= 0, attributes.st_size <= maximum else {
            throw Self.failure("validate file size", at: target, reason: "The file exceeds the supported size limit.")
        }
        guard !executable || attributes.st_mode & 0o111 != 0 else {
            throw Self.failure("validate helper executable", at: target, reason: "The embedded helper is not executable.")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(file, &buffer, min(buffer.count, maximum + 1 - result.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.failure("read file", at: target, code: errno) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximum else { throw Self.failure("read bounded file", at: target, reason: "The file grew beyond the supported size limit.") }
        }
    }

    func write(_ data: Data, path: String, mode: mode_t) throws {
        defer { withExtendedLifetime(self) {} }
        let pieces = path.split(separator: "/").map(String.init)
        let target = url.appendingPathComponent(path)
        guard let name = pieces.last, let parent = try directory(pieces.dropLast(), create: true) else {
            throw Self.failure("create destination directory", at: target)
        }
        defer { withExtendedLifetime(parent) {} }
        var existing = stat()
        if fstatat(parent.descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == geteuid() else {
                throw Self.failure("validate existing destination", at: target, reason: "The destination must be a regular file owned by the current user.")
            }
        } else if errno != ENOENT { throw Self.failure("inspect existing destination", at: target, code: errno) }
        let temporary = ".mac-helper-install-" + UUID().uuidString
        let file = Darwin.openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else { throw Self.failure("create temporary destination file", at: target, code: errno) }
        defer { Darwin.close(file); _ = Darwin.unlinkat(parent.descriptor, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { bytes in Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw Self.failure("write temporary destination file", at: target, code: errno) }
            offset += amount
        }
        guard fchmod(file, mode) == 0 else { throw Self.failure("set private file permissions", at: target, code: errno) }
        guard fsync(file) == 0 else { throw Self.failure("flush temporary destination file", at: target, code: errno) }
        guard Darwin.renameat(parent.descriptor, temporary, parent.descriptor, name) == 0 else {
            throw Self.failure("atomically replace destination file", at: target, code: errno)
        }
    }
}
