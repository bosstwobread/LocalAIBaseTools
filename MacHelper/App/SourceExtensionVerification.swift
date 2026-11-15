import Darwin
import Foundation
import MacHelper

/// Exercises the real manager, source watcher, and replaceable JavaScript
/// processes without starting selection monitoring, showing windows, or touching
/// the user's extension directory. The Python driver owns the loopback catalog.
@MainActor
enum SourceExtensionVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class AIProbe {
        var calls = 0
        var latest: [String: Any] = [:]
        var blockNext = false
        var blocked = false
        var releaseBlocked = false
        var cancellations = 0

        func transform(_ payload: [String: Any]) async throws -> [String: Any] {
            calls += 1
            latest = payload
            if blockNext {
                blockNext = false
                blocked = true
                releaseBlocked = false
                defer { blocked = false }
                do {
                    let deadline = Date().addingTimeInterval(30)
                    while !releaseBlocked && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                    guard releaseBlocked else { throw Failure(message: "The blocked test capability was not released.") }
                }
                catch { cancellations += 1; throw error }
            }
            guard let text = payload["text"] as? String else { throw Failure(message: "AI received no text.") }
            return ["text": "AI:" + text, "model": "fixture-model"]
        }
    }

    /// CLI: --verify-source-extensions --catalog-url URL --workspace-root DIR
    ///      --worker PATH --helper PATH [--live]
    /// The workspace must have the Python driver's marker and no existing state.
    static func run() async -> Int32 {
        var managers: [SourceExtensionManager] = []
        var workerPIDs: [Int32] = []
        var checks: [String] = []
        let hostPID = getpid()
        var report: [String: Any] = ["hostPID": Int(hostPID)]
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(message: message) }
        }
        func remember(_ pid: Int32?) throws -> Int32 {
            guard let pid, pid > 1, pid != hostPID else { throw Failure(message: "Expected an independent live worker process.") }
            if !workerPIDs.contains(pid) { workerPIDs.append(pid) }
            return pid
        }
        func note(_ value: String) { checks.append(value) }
        do {
            let args = CommandLine.arguments
            func option(_ key: String) throws -> String {
                guard let index = args.firstIndex(of: key), args.indices.contains(index + 1),
                      !args[index + 1].hasPrefix("--") else { throw Failure(message: "Missing verification argument: " + key) }
                return args[index + 1]
            }
            guard let catalogURL = URL(string: try option("--catalog-url")),
                  catalogURL.scheme == "http", ["127.0.0.1", "localhost"].contains(catalogURL.host ?? "") else {
                throw Failure(message: "The verification catalog must use loopback HTTP.")
            }
            let workspace = URL(fileURLWithPath: try option("--workspace-root"), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let marker = workspace.appendingPathComponent(".mac-helper-source-verification")
            try check((try? String(contentsOf: marker, encoding: .utf8)) == "isolated-test-workspace\n", "Refusing to use an unmarked verification workspace.")
            let state = workspace.appendingPathComponent("state", isDirectory: true)
            let sources = workspace.appendingPathComponent("extensions", isDirectory: true)
            try check(!FileManager.default.fileExists(atPath: state.path) && !FileManager.default.fileExists(atPath: sources.path), "Verification state must start empty.")
            let worker = URL(fileURLWithPath: try option("--worker"))
            let helper = URL(fileURLWithPath: try option("--helper"))
            try check(FileManager.default.isExecutableFile(atPath: worker.path), "The script worker executable is missing.")
            try check(FileManager.default.isExecutableFile(atPath: helper.path), "The helper executable is missing.")
            let requestLogURL = catalogURL.deletingLastPathComponent().appendingPathComponent("__requests")
            let catalog = try await SourceCatalogLoader.load(from: catalogURL)
            let id = SourceExtensionManager.translationID
            guard let entry = catalog.extensions.first(where: { $0.identifier == id }) else { throw Failure(message: "The fixture must contain Translation.") }
            let expectedPaths = Set(entry.files.map { "/Translation/" + $0.path })
            let probe = AIProbe()
            func makeManager(live: Bool = false) -> SourceExtensionManager {
                let transform: (([String: Any]) async throws -> [String: Any])? = live ? nil : { payload in try await probe.transform(payload) }
                let manager = SourceExtensionManager(workerExecutableURL: worker, helperExecutableURL: helper,
                    bundledCatalogURL: catalogURL, stateDirectory: state, sourceDirectory: sources,
                    headless: true, testTransform: transform)
                managers.append(manager)
                return manager
            }
            func info(_ manager: SourceExtensionManager) throws -> SourceToolInfo {
                guard let value = manager.tools.first(where: { $0.id == id }) else { throw Failure(message: "Translation disappeared from the catalog.") }
                return value
            }
            let manager = makeManager()
            await manager.start()
            let metadata = try info(manager)
            try check(!metadata.isEnabled && !metadata.isRunning && metadata.sourceURL == nil && manager.workerPID(for: id) == nil,
                      "Reading catalog metadata must not install or enable a tool.")
            let metadataRequests = try await requests(requestLogURL)
            try check(metadataRequests.allSatisfy { $0 == "/catalog.json" }, "Catalog discovery downloaded source before enable.")
            try check(probe.calls == 0, "Discovery must not call AI.")
            note("catalog discovery downloads metadata only and leaves Translation disabled")

            try await manager.setEnabled(true, for: id)
            let firstPID = try remember(manager.workerPID(for: id))
            guard let source = manager.sourceURL(for: id) else { throw Failure(message: "Enabled source is missing.") }
            let snapshot = try SourcePackageInspector.snapshot(at: source)
            let expectedHashes = Dictionary(uniqueKeysWithValues: entry.files.map { ($0.path, $0.sha256) })
            try check(snapshot.fileHashes == expectedHashes, "Enable did not download the complete verified source inventory.")
            let installedRequests = try await requests(requestLogURL).filter { $0.hasPrefix("/Translation/") }
            try check(Set(installedRequests) == expectedPaths && installedRequests.count == expectedPaths.count,
                      "Every catalog source file must be downloaded exactly once on enable.")
            try check(probe.calls == 0 && (try info(manager)).isRunning, "Enabling must start the worker without running AI.")
            report["sourceFileCount"] = expectedPaths.count
            note("enable downloads every verified source file and starts a separate worker")

            let sample = "A public synthetic test message. Keep $125.50 and https://example.com."
            let initial = try await manager.performCommand(for: id, text: sample)
            try check(initial.text == "AI:" + sample && initial.model == "fixture-model", "Translation did not round-trip through the AI capability bridge.")
            try check(probe.latest["text"] as? String == sample && probe.latest["targetLanguage"] as? String == "zh-CN",
                      "The actual Translation source did not receive its text or default settings.")
            note("actual Translation JavaScript invokes the explicit AI bridge and returns model metadata")

            let mainURL = source.appendingPathComponent(snapshot.manifest.entryPoint)
            let originalMain = try String(contentsOf: mainURL, encoding: .utf8)
            let outputNeedle = "text: response.text"
            try check(originalMain.contains(outputNeedle), "The Translation test expects its documented response formatting line.")
            let editedMain = originalMain.replacingOccurrences(of: outputNeedle, with: "text: \"Edited: \" + response.text")
            let initialCount = try info(manager).reloadCount
            let callsBeforeEdit = probe.calls
            try editedMain.write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("A saved JavaScript edit did not hot reload.") {
                ((try? info(manager).reloadCount) ?? 0) > initialCount && manager.workerPID(for: id) != firstPID
            }
            let editedPID = try remember(manager.workerPID(for: id))
            try await eventually("The previous JavaScript worker was not reaped after reload.") { !processExists(firstPID) }
            try check(getpid() == hostPID && probe.calls == callsBeforeEdit, "Reload restarted the host or ran AI without a user action.")
            try check(try await manager.performCommand(for: id, text: sample).text == "Edited: AI:" + sample,
                      "A saved source edit did not change Translation output.")
            note("saving JavaScript changes behavior, replaces/reaps its worker, and keeps the host alive")

            let promptURL = source.appendingPathComponent("prompts/translate.txt")
            let prompt = try String(contentsOf: promptURL, encoding: .utf8)
            let markerText = "PUBLIC_FIXTURE_GUIDANCE_MARKER"
            let countBeforePrompt = try info(manager).reloadCount
            try (prompt + "\n" + markerText + "\n").write(to: promptURL, atomically: true, encoding: .utf8)
            try await eventually("A nested prompt resource did not hot reload.") { ((try? info(manager).reloadCount) ?? 0) > countBeforePrompt }
            let promptPID = try remember(manager.workerPID(for: id))
            try check(promptPID != editedPID, "Prompt reload reused the old worker.")
            _ = try await manager.performCommand(for: id, text: sample)
            try check((probe.latest["guidance"] as? String)?.contains(markerText) == true, "The new prompt did not reach the AI capability.")
            note("saving nested prompt resources updates the next AI request")

            let countBeforeSyntaxError = try info(manager).reloadCount
            try (editedMain + "\nMacHelper.define({\n").write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("An invalid JavaScript save did not report a reload error.") { (try? info(manager).error) != nil }
            try check(manager.workerPID(for: id) == promptPID && (try info(manager)).reloadCount == countBeforeSyntaxError,
                      "An invalid edit replaced the last working worker.")
            try check(try await manager.performCommand(for: id, text: sample).text == "Edited: AI:" + sample,
                      "The last working version stopped serving results after a syntax error.")
            note("syntax errors are visible while the last working generation remains usable")

            let recoveredMain = originalMain.replacingOccurrences(of: outputNeedle, with: "text: \"Recovered: \" + response.text")
            try recoveredMain.write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("Fixing invalid source did not recover automatically.") {
                guard let value = try? info(manager) else { return false }
                return value.error == nil && value.reloadCount > countBeforeSyntaxError
            }
            _ = try remember(manager.workerPID(for: id))
            try check(try await manager.performCommand(for: id, text: sample).text == "Recovered: AI:" + sample,
                      "The repaired source did not become active.")
            note("fixing source clears the reload error and activates the repaired version")

            try await manager.updateSetting("targetLanguage", value: "en", for: id)
            try await manager.updateSetting("style", value: "formal", for: id)
            _ = try remember(manager.workerPID(for: id))
            _ = try await manager.performCommand(for: id, text: sample)
            try check(probe.latest["targetLanguage"] as? String == "en" && (probe.latest["guidance"] as? String)?.contains("Writing style: formal") == true,
                      "Updated per-extension settings did not reach JavaScript.")
            let settingsFile = state.appendingPathComponent("ExtensionSettings/" + id + "/settings.json")
            let savedSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any]
            try check(savedSettings?["targetLanguage"] as? String == "en" && savedSettings?["style"] as? String == "formal",
                      "Per-extension settings were not persisted.")
            try check(try privatePermissions(settingsFile) == 0o600, "Extension settings must be private on disk.")
            note("extension settings update live, persist independently, and use private file permissions")

            let busyPID = try remember(manager.workerPID(for: id))
            probe.blockNext = true
            let inFlight = Task { try await manager.performCommand(for: id, text: sample) }
            try await eventually("The overlap test did not enter its first AI capability.") { probe.blocked }
            let callsBeforeOverlap = probe.calls
            var overlapRejected = false
            do { _ = try await manager.performCommand(for: id, text: sample) }
            catch { overlapRejected = true }
            try check(overlapRejected && probe.calls == callsBeforeOverlap && probe.blocked && manager.workerPID(for: id) == busyPID,
                      "Overlapping actions must be rejected before a second AI request without interrupting the first action.")
            probe.releaseBlocked = true
            let completedFirst = try await inFlight.value
            try check(completedFirst.text == "Recovered: AI:" + sample && completedFirst.model == "fixture-model",
                      "Rejecting an overlapping action corrupted the first action or its model metadata.")
            note("overlapping actions are rejected without extra AI calls or corrupting the active result")

            let cancelledPID = try remember(manager.workerPID(for: id))
            probe.blockNext = true
            let operation = Task { () -> Bool in
                do { _ = try await manager.performCommand(for: id, text: sample); return false }
                catch { return true }
            }
            try await eventually("The cancellation test did not enter its AI capability.") { probe.blocked }
            operation.cancel()
            try await eventually("Cancelling Translation did not cancel AI and stop its worker.") {
                probe.cancellations > 0 && manager.workerPID(for: id) == nil && !processExists(cancelledPID)
            }
            try check(await operation.value, "A cancelled translation returned a result.")
            try check(try await manager.performCommand(for: id, text: sample).text == "Recovered: AI:" + sample,
                      "A new user action did not recreate the worker after cancellation.")
            let afterCancellationPID = try remember(manager.workerPID(for: id))
            try check(afterCancellationPID != cancelledPID, "Cancellation recovery reused the stopped process.")
            note("cancellation cancels AI and reaps the worker; the next action recreates it")

            let invalidMain = recoveredMain + "\nMacHelper.define({\n"
            try invalidMain.write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("The invalid restart fixture did not trigger a reload error.") { (try? info(manager).error) != nil }
            await manager.stopAll()
            try await eventually("Shutdown left a JavaScript worker running.") { workerPIDs.allSatisfy { !processExists($0) } }
            let restarted = makeManager()
            await restarted.start()
            _ = try remember(restarted.workerPID(for: id))
            try check((try info(restarted)).isEnabled && (try info(restarted)).isRunning && (try info(restarted)).error != nil,
                      "Restart with an invalid local edit did not recover its last good cache and show the error.")
            try check(try String(contentsOf: mainURL, encoding: .utf8) == invalidMain, "Recovery overwrote the user's invalid local edit.")
            try check(restarted.settings(for: id)["targetLanguage"] as? String == "en" && restarted.settings(for: id)["style"] as? String == "formal",
                      "Settings were lost when restarting the manager.")
            try check(try await restarted.performCommand(for: id, text: sample).text == "Recovered: AI:" + sample,
                      "The last good cached generation did not serve a translation after restart.")
            note("restart preserves invalid local edits and settings while running the last good cached source")

            let restartedCount = try info(restarted).reloadCount
            try recoveredMain.write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("The restarted manager stopped watching invalid local source.") {
                guard let value = try? info(restarted) else { return false }
                return value.error == nil && value.reloadCount > restartedCount
            }
            // A deliberately pending old stop hook makes the reentrancy window
            // deterministic: activate has published its candidate but is still
            // awaiting bounded disposal of the previous process.
            let slowStopMain = recoveredMain.replacingOccurrences(of: "MacHelper.define({",
                with: "MacHelper.define({\n  async stop() { return new Promise(() => {}); },")
            let beforeSlowStop = try info(restarted).reloadCount
            try slowStopMain.write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("The slow-stop regression fixture did not reload.") {
                ((try? info(restarted).reloadCount) ?? 0) > beforeSlowStop
            }
            let slowStopPID = try remember(restarted.workerPID(for: id))
            let countBeforeEnableRace = try info(restarted).reloadCount
            var enablingFinished = false
            let enabling = Task { () -> Bool in
                defer { enablingFinished = true }
                do { try await restarted.setEnabled(true, for: id); return true }
                catch { return false }
            }
            try await eventually("The enable/disable race did not reach candidate disposal.") {
                let pid = restarted.workerPID(for: id)
                return pid != nil && pid != slowStopPID && !enablingFinished
            }
            let disabledPID = try remember(restarted.workerPID(for: id))
            try await restarted.setEnabled(false, for: id)
            try check(!(await enabling.value), "A stale pending enable completed successfully after disable.")
            try await eventually("Disable did not reap the active and retiring workers.") {
                !processExists(disabledPID) && !processExists(slowStopPID)
            }
            let persistedState = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent("source-extensions.json"))) as? [String: Any]
            try check(restarted.workerPID(for: id) == nil && !(try info(restarted)).isEnabled &&
                      (try info(restarted)).reloadCount == countBeforeEnableRace &&
                      (persistedState?["enabled"] as? [String: Bool])?[id] == false,
                      "A stale enable changed disabled state, reload count, or preferences after yielding to disable.")
            note("disable wins over a pending enable while its old worker is being disposed")
            let disabledCount = try info(restarted).reloadCount
            let callsBeforeDisableEdit = probe.calls
            try (recoveredMain + "\n// A source edit made while disabled.\n").write(to: mainURL, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try check(restarted.workerPID(for: id) == nil && !(try info(restarted)).isEnabled && !(try info(restarted)).isRunning &&
                      (try info(restarted)).reloadCount == disabledCount && probe.calls == callsBeforeDisableEdit,
                      "Editing disabled source unexpectedly restarted its watcher, worker, or AI.")
            var disabledRejected = false
            do { _ = try await restarted.performCommand(for: id, text: sample) }
            catch { disabledRejected = true }
            try check(disabledRejected, "A disabled tool accepted a command.")
            note("disable stops the worker and watcher; later source edits do not restart the tool")

            let finalDownloads = try await requests(requestLogURL).filter { $0.hasPrefix("/Translation/") }
            try check(finalDownloads.count == expectedPaths.count, "Reload or restart unexpectedly redownloaded or overwrote local source.")
            for url in [state.appendingPathComponent("source-extensions.json"), settingsFile] {
                let contents = try String(contentsOf: url, encoding: .utf8)
                try check(!contents.contains(sample) && !contents.contains("fixture-model") && !contents.contains("AI:"),
                          "Preferences retained message content or an AI result.")
            }
            note("reload/restart preserve editable files and never persist selected text or AI results in preferences")
            await restarted.stopAll()

            if args.contains("--live") {
                let live = makeManager(live: true)
                await live.start()
                try await live.setEnabled(true, for: id)
                try await live.updateSetting("targetLanguage", value: "zh-CN", for: id)
                _ = try remember(live.workerPID(for: id))
                let response = try await live.performCommand(for: id, text: "Hello! The project is ready for review. The amount is $125.50.")
                try check(!response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && response.text.contains("125.50"),
                          "The optional local AI smoke test returned no translation or lost the amount.")
                try check(response.text.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }, "The optional live translation did not include Chinese text.")
                report["liveModel"] = response.model ?? ""
                report["liveAI"] = true
                note("synthetic public text translates through the real local helper without any Upwork interaction")
                await live.stopAll()
            } else { report["liveAI"] = false }
            for manager in managers { await manager.stopAll() }
            try await eventually("Final cleanup left worker processes running.") { workerPIDs.allSatisfy { !processExists($0) } }
            try check(getpid() == hostPID, "The verification host unexpectedly changed.")
            report["success"] = true
            report["checks"] = checks
            report["workerPIDs"] = workerPIDs.map(Int.init)
            emit(report)
            return 0
        } catch {
            for manager in managers { await manager.stopAll() }
            report["success"] = false
            report["checks"] = checks
            report["workerPIDs"] = workerPIDs.map(Int.init)
            report["error"] = error.localizedDescription
            emit(report)
            return 1
        }
    }

    private static func eventually(_ message: String, timeout: TimeInterval = 8,
                                   _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        } while Date() < deadline
        throw Failure(message: message)
    }

    private static func requests(_ url: URL) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["paths"] as? [String] else { throw Failure(message: "The fixture request log could not be read.") }
        return paths
    }

    private static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private static func privatePermissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func emit(_ report: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }
}
