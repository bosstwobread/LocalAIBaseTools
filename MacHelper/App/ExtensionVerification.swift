import AppKit
import MacHelper

/// A headless integration check. State and settings are isolated in a temporary
/// folder; no real extension is installed or enabled and no window is shown.
@MainActor
enum ExtensionVerification {
    static func run() {
        let args = CommandLine.arguments
        func option(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacHelperVerification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let directory = option("--extension-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? temp.appendingPathComponent("Extensions")
            let registry = ExtensionRegistry(bundledDirectory: Bundle.main.builtInPlugInsURL,
                                             userDirectory: directory,
                                             stateFileURL: temp.appendingPathComponent("extensions.json"))
            defer { registry.stopAll() }
            registry.refresh()
            if let id = option("--enable-test-extension") { try registry.setEnabled(true, for: id) }
            var entries: [[String: Any]] = []
            for item in registry.extensions {
                var settingsLoaded = false
                if registry.isRunning(item.id) {
                    let controller = try registry.settingsViewController(for: item.id)
                    controller.loadViewIfNeeded()
                    settingsLoaded = true
                }
                entries.append(["identifier": item.id, "displayName": item.manifest.displayName,
                                "isBundled": item.isBundled, "enabled": registry.isEnabled(item.id),
                                "running": registry.isRunning(item.id), "settingsLoaded": settingsLoaded])
            }
            let output: [String: Any] = ["extensions": entries, "issues": registry.issues.map(\.message),
                                          "errors": registry.runtimeErrors]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
            print(String(decoding: data ?? Data("{}".utf8), as: UTF8.self))
            exit(1)
        }
    }
}
