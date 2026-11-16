import Foundation

public struct AppLanguage: Equatable, Sendable {
    public let code: String
    public let name: String
    public init(code: String, name: String) { self.code = code; self.name = name }
}

public extension Notification.Name {
    static let macHelperLanguageDidChange = Notification.Name("MacHelperInterfaceLanguageDidChange")
}

/// Interface language is independent of the AI provider and translation target.
/// Catalogs are shipped with the app; selecting a language never sends text to AI.
public final class AppLocalization: @unchecked Sendable {
    public static let supportedLanguages: [AppLanguage] = [
        .init(code: "en", name: "English"), .init(code: "zh-Hans", name: "简体中文"),
        .init(code: "zh-Hant", name: "繁體中文"), .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"), .init(code: "de", name: "Deutsch"),
        .init(code: "ja", name: "日本語"), .init(code: "ko", name: "한국어"),
        .init(code: "pt", name: "Português"), .init(code: "ar", name: "العربية"),
        .init(code: "hi", name: "हिन्दी"), .init(code: "ru", name: "Русский"),
        .init(code: "it", name: "Italiano")
    ]
    public static let shared = AppLocalization()
    private static let preferenceKey = "MacHelperInterfaceLanguage"
    private let defaults: UserDefaults
    private let directory: URL
    private let preferredLanguages: () -> [String]
    private let environmentLanguage: String?
    private let lock = NSRecursiveLock()
    private var catalogs: [String: [String: String]] = [:]

    public init(defaults: UserDefaults = UserDefaults(suiteName: "com.localaibasetools.mac-helper") ?? .standard,
                catalogDirectoryURL: URL? = nil,
                preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
                environmentLanguage: String? = ProcessInfo.processInfo.environment["MACHELPER_INTERFACE_LANGUAGE"]) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        self.environmentLanguage = environmentLanguage.flatMap(Self.match)
        if let catalogDirectoryURL { directory = catalogDirectoryURL }
        else if let appResources = Bundle.main.resourceURL?.appendingPathComponent("Localization"),
                FileManager.default.fileExists(atPath: appResources.path) { directory = appResources }
        else { directory = Bundle.module.resourceURL!.appendingPathComponent("Localization") }
    }

    public var language: String {
        get { lock.withLock { defaults.string(forKey: Self.preferenceKey).flatMap { value in
            value == "system" || Self.supportedLanguages.contains(where: { $0.code == value }) ? value : nil
        } ?? "system" } }
        set {
            let value = newValue == "system" ? "system" : Self.match(newValue) ?? "system"
            let changed: Bool = lock.withLock {
                guard language != value else { return false }
                defaults.set(value, forKey: Self.preferenceKey)
                return true
            }
            guard changed else { return }
            let post = { NotificationCenter.default.post(name: .macHelperLanguageDidChange, object: self) }
            if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
        }
    }

    public var resolvedLanguage: String {
        if let environmentLanguage { return environmentLanguage }
        let selected = language
        return selected == "system" ? Self.resolve(preferredLanguages()) : selected
    }
    public var isRightToLeft: Bool { resolvedLanguage == "ar" }

    public static func match(_ language: String) -> String? {
        let value = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let pieces = value.split(separator: "-").map(String.init)
        guard let base = pieces.first else { return nil }
        if base == "zh" {
            if pieces.contains("hant") { return "zh-Hant" }
            if pieces.contains("hans") { return "zh-Hans" }
            return pieces.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
        }
        return supportedLanguages.first { $0.code.lowercased() == base }?.code
    }
    public static func resolve(_ preferred: [String]) -> String { preferred.compactMap(match).first ?? "en" }

    public func localized(_ key: String) -> String {
        lock.withLock {
            let locale = resolvedLanguage
            if catalogs[locale] == nil {
                let data = try? Data(contentsOf: directory.appendingPathComponent(locale + ".json"))
                catalogs[locale] = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            }
            guard let value = catalogs[locale]?[key], !value.isEmpty,
                  Self.formatSpecifiers(value) == Self.formatSpecifiers(key) else { return key }
            return value
        }
    }
    public func text(_ key: String, _ arguments: CVarArg...) -> String { format(key, arguments: arguments) }
    public func format(_ key: String, arguments: [CVarArg]) -> String {
        let value = localized(key)
        guard !arguments.isEmpty else { return value }
        guard Self.formatSpecifiers(key).count == arguments.count else { return key }
        return String(format: value, locale: Locale(identifier: resolvedLanguage), arguments: arguments)
    }

    /// Format parameters must retain their count, order and type in every catalog.
    public static func formatSpecifiers(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(?:hh|ll|h|l|z|t|j)?[@diuoxXfFeEgGaAcCsSpn%]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }.filter { $0 != "%%" }
    }
}

public func L(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.shared.format(key, arguments: arguments)
}
