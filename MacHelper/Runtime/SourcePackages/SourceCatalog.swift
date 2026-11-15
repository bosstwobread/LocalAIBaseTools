import Foundation

public struct SourceCatalogFile: Codable, Equatable, Sendable {
    public let path: String
    public let url: String
    public let sha256: String
    public let size: Int?
    public init(path: String, url: String? = nil, sha256: String, size: Int? = nil) {
        self.path = path; self.url = url ?? path; self.sha256 = sha256; self.size = size
    }
}

public struct SourceCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let displayName: String
    public let version: String
    public let summary: String
    public let files: [SourceCatalogFile]
    public init(identifier: String, displayName: String, version: String, summary: String, files: [SourceCatalogFile]) {
        self.identifier = identifier; self.displayName = displayName; self.version = version
        self.summary = summary; self.files = files
    }
    public func validate() throws {
        try SourcePackageRules.validateIdentifier(identifier)
        guard SourcePackageRules.validText(displayName, limit: 256), SourcePackageRules.validText(summary, limit: 2000),
              SourcePackageRules.validVersion(version), !files.isEmpty, files.count <= SourcePackageRules.maximumFiles,
              files.contains(where: { $0.path == "extension.json" }),
              Set(files.map { $0.path.lowercased() }).count == files.count else {
            throw SourcePackageError.invalid("The source catalog's metadata or complete file inventory is invalid.")
        }
        var declaredBytes = 0
        for file in files {
            try SourcePackageRules.validatePath(file.path)
            guard !file.url.isEmpty, file.url.utf8.count <= 2048,
                  file.sha256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
                  file.size.map({ $0 >= 0 && $0 <= SourcePackageRules.maximumFileBytes }) ?? true else {
                throw SourcePackageError.invalid("A source catalog file has an invalid URL, SHA-256, or size.")
            }
            declaredBytes += file.size ?? 0
        }
        guard declaredBytes <= SourcePackageRules.maximumPackageBytes else { throw SourcePackageError.invalid("The catalog package exceeds its size limit.") }
        let paths = Set(files.map { $0.path.lowercased() })
        for file in files {
            let parts = file.path.lowercased().split(separator: "/")
            if parts.count > 1 {
                for count in 1..<parts.count where paths.contains(parts.prefix(count).joined(separator: "/")) {
                    throw SourcePackageError.invalid("A catalog file path conflicts with a directory.")
                }
            }
        }
    }
}

public struct SourceCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let extensions: [SourceCatalogEntry]
    public init(schemaVersion: Int = 1, extensions: [SourceCatalogEntry]) { self.schemaVersion = schemaVersion; self.extensions = extensions }
    public func validate() throws {
        guard schemaVersion == 1, extensions.count <= 256,
              Set(extensions.map(\.identifier)).count == extensions.count else {
            throw SourcePackageError.invalid("The source catalog version, size, or extension identifiers are invalid.")
        }
        try extensions.forEach { try $0.validate() }
    }
}

public enum SourceCatalogLoader {
    public static func load(from url: URL, session: URLSession = .shared) async throws -> SourceCatalog {
        let transport = SourceDownloadTransport(session: session)
        let data = try await transport.read(url, maximumBytes: 1024 * 1024)
        let catalog = try JSONDecoder().decode(SourceCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }
}

/// Downloads source only. It has no credential, cookie, proxy, cache, or redirect
/// access, and imposes a bounded streaming response limit before activation.
final class SourceDownloadTransport: @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession) {
        let configuration = session.configuration
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration, delegate: SourceDownloadRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    static func validateURL(_ url: URL, localBaseAllowed: Bool = true) throws {
        guard let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else {
            throw SourcePackageError.invalid("Choose a source catalog URL without embedded credentials.")
        }
        if scheme == "file", localBaseAllowed { return }
        let host = url.host?.lowercased()
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "")
        guard host != nil, (scheme == "https" || (scheme == "http" && local && localBaseAllowed)) else {
            throw SourcePackageError.invalid("Source downloads require HTTPS. Local files and loopback HTTP are supported for development.")
        }
    }

    func read(_ url: URL, maximumBytes: Int) async throws -> Data {
        try Self.validateURL(url)
        try Task.checkCancellation()
        if url.isFileURL { return try SourcePackageRules.boundedData(url, maximum: maximumBytes) }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream, application/json, text/plain", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), response.url == url else {
            throw SourcePackageError.invalid("A source download failed or tried to redirect. The extension was not installed.")
        }
        guard response.expectedContentLength <= maximumBytes else { throw SourcePackageError.invalid("A source download exceeds its size limit.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw SourcePackageError.invalid("A source download exceeds its size limit.") }
            data.append(byte)
        }
        return data
    }
}

private final class SourceDownloadRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
