import Foundation

public enum MarketplaceError: LocalizedError, Equatable {
    case invalidLink(String)
    case notConfigured
    case existingSourceChanged

    public var errorDescription: String? {
        switch self {
        case .invalidLink(let message): return message
        case .notConfigured: return "The marketplace website is not configured in this MacHelper build. Install a current MacHelper release and try again."
        case .existingSourceChanged: return "A local source copy appeared while this installation was being reviewed. Its source and enabled state were preserved."
        }
    }
}

/// A website can request an installation review. Parsing this URL never installs
/// source, grants permissions, or enables a tool.
public struct MarketplaceInstallRequest: Equatable, Sendable {
    public let catalogURL: URL
    public let extensionID: String
    public let allowsLocalDevelopment: Bool

    public init(url: URL, allowLocalDevelopment: Bool = false) throws {
        guard url.absoluteString.utf8.count <= 8192, url.absoluteString.lowercased().hasPrefix("machelper://install?"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "machelper", components.host?.lowercased() == "install",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 2,
              Set(items.map(\.name)) == ["catalog", "extension"],
              let catalog = items.first(where: { $0.name == "catalog" })?.value,
              let identifier = items.first(where: { $0.name == "extension" })?.value,
              let catalogURL = URL(string: catalog), catalogURL.baseURL == nil else {
            throw MarketplaceError.invalidLink("This marketplace link is invalid. Use an Install in MacHelper link from the marketplace.")
        }
        try self.init(catalogURL: catalogURL, extensionID: identifier, allowLocalDevelopment: allowLocalDevelopment)
    }

    public init(catalogURL: URL, extensionID: String, allowLocalDevelopment: Bool = false) throws {
        try SourcePackageRules.validateIdentifier(extensionID)
        try MarketplaceURLRules.validate(catalogURL, allowLocalDevelopment: allowLocalDevelopment)
        self.catalogURL = catalogURL
        self.extensionID = extensionID
        allowsLocalDevelopment = allowLocalDevelopment
    }
}

public enum MarketplaceConfiguration {
    public static let websiteKey = "MacHelperMarketplaceURL"
    public static let developmentKey = "MacHelperAllowsLocalMarketplaceDevelopment"

    public static func websiteURL(bundle: Bundle = .main) throws -> URL {
        try websiteURL(info: bundle.infoDictionary ?? [:])
    }

    public static func websiteURL(info: [String: Any]) throws -> URL {
        guard let text = info[websiteKey] as? String, let url = URL(string: text) else { throw MarketplaceError.notConfigured }
        let development = info[developmentKey] as? Bool == true
        do { try MarketplaceURLRules.validate(url, allowLocalDevelopment: development) }
        catch { throw MarketplaceError.notConfigured }
        let host = url.host?.lowercased() ?? ""
        guard !host.hasSuffix(".example"), !["example.com", "example.org", "example.net", "example"].contains(host) else {
            throw MarketplaceError.notConfigured
        }
        return url
    }
}

private enum MarketplaceURLRules {
    static func validate(_ url: URL, allowLocalDevelopment: Bool) throws {
        guard url.absoluteString.utf8.count <= 2048,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !(url.absoluteString.removingPercentEncoding ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MarketplaceError.invalidLink("Marketplace URLs must be absolute HTTPS URLs without credentials, fragments, or control characters.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (allowLocalDevelopment && scheme == "http" && loopback) else {
            throw MarketplaceError.invalidLink("Marketplace catalogs and source downloads require HTTPS. Loopback HTTP is available only in development builds.")
        }
    }
}

/// Verified metadata for a native review dialog. Only catalog JSON and its
/// hash-pinned manifest are fetched; executable code waits for user approval.
public struct MarketplaceInstallPreview: Sendable {
    public let request: MarketplaceInstallRequest
    public let entry: SourceCatalogEntry
    public let manifest: SourceExtensionManifest
}

public enum MarketplaceReviewLoader {
    public static func load(_ request: MarketplaceInstallRequest, session: URLSession = .shared) async throws -> MarketplaceInstallPreview {
        let catalog = try await SourceCatalogLoader.load(from: request.catalogURL, session: session)
        guard let entry = catalog.extensions.first(where: { $0.identifier == request.extensionID }) else {
            throw MarketplaceError.invalidLink("The requested tool is not listed in this catalog.")
        }
        for file in entry.files {
            guard let url = URL(string: file.url, relativeTo: request.catalogURL)?.absoluteURL else {
                throw MarketplaceError.invalidLink("The catalog contains an invalid source URL.")
            }
            try MarketplaceURLRules.validate(url, allowLocalDevelopment: request.allowsLocalDevelopment)
        }
        let manifest = try await SourceCatalogLoader.loadManifest(for: entry, relativeTo: request.catalogURL, session: session)
        return MarketplaceInstallPreview(request: request, entry: entry, manifest: manifest)
    }
}
