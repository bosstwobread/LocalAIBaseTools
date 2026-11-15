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
    init(root: URL) throws {
        descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure() }
    }
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    private static func failure() -> BrowserSupportError {
        .invalid("Browser support could not safely access its files. Check permissions and remove symbolic links from the browser support paths, then try again.")
    }

    private func directory(_ pieces: ArraySlice<String>, create: Bool) throws -> BrowserSafeDirectory? {
        var current = Darwin.dup(descriptor)
        guard current >= 0 else { throw Self.failure() }
        defer { Darwin.close(current) }
        for piece in pieces {
            guard !piece.isEmpty, piece != ".", piece != "..", !piece.contains("/") else { throw Self.failure() }
            var next = Darwin.openat(current, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { return nil }
                guard Darwin.mkdirat(current, piece, 0o700) == 0 || errno == EEXIST else { throw Self.failure() }
                next = Darwin.openat(current, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw Self.failure() }
            Darwin.close(current); current = next
        }
        let result = Darwin.dup(current)
        guard result >= 0 else { throw Self.failure() }
        _ = fcntl(result, F_SETFD, FD_CLOEXEC)
        return BrowserSafeDirectory(descriptor: result)
    }

    func makePrivateDirectory(_ path: String) throws {
        guard let directory = try directory(path.split(separator: "/").map(String.init)[...], create: true) else { throw Self.failure() }
        var attributes = stat()
        guard fstat(directory.descriptor, &attributes) == 0, attributes.st_uid == geteuid(),
              fchmod(directory.descriptor, 0o700) == 0 else { throw Self.failure() }
    }

    func read(_ path: String, maximum: Int, requireUserOwner: Bool = true, executable: Bool = false) throws -> Data? {
        let pieces = path.split(separator: "/").map(String.init)
        guard let name = pieces.last, let parent = try directory(pieces.dropLast(), create: false) else { return nil }
        let file = Darwin.openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file) }
        var attributes = stat()
        guard fstat(file, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              !requireUserOwner || attributes.st_uid == geteuid(),
              attributes.st_size >= 0, attributes.st_size <= maximum,
              !executable || attributes.st_mode & 0o111 != 0 else { throw Self.failure() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(file, &buffer, min(buffer.count, maximum + 1 - result.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.failure() }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximum else { throw Self.failure() }
        }
    }

    func write(_ data: Data, path: String, mode: mode_t) throws {
        let pieces = path.split(separator: "/").map(String.init)
        guard let name = pieces.last, let parent = try directory(pieces.dropLast(), create: true) else { throw Self.failure() }
        var existing = stat()
        if fstatat(parent.descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == geteuid() else { throw Self.failure() }
        } else if errno != ENOENT { throw Self.failure() }
        let temporary = ".mac-helper-install-" + UUID().uuidString
        let file = Darwin.openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else { throw Self.failure() }
        defer { Darwin.close(file); _ = Darwin.unlinkat(parent.descriptor, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { bytes in Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw Self.failure() }
            offset += amount
        }
        guard fchmod(file, mode) == 0, fsync(file) == 0,
              Darwin.renameat(parent.descriptor, temporary, parent.descriptor, name) == 0 else { throw Self.failure() }
    }
}
