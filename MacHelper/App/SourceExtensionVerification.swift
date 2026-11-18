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

    @MainActor
    private final class AIProbe {
        var calls = 0
        var latest: [String: Any] = [:]
        var blockNext = false
        var blocked = false
        var releaseBlocked = false
        var cancellations = 0
        var streamNext = false
        var streaming = false
        var releaseStream = false
        var failStreamNext = false
        var lateProgress: (@MainActor ([String: Any]) -> Void)?

        func transformStreaming(_ payload: [String: Any], onProgress: @escaping @MainActor ([String: Any]) -> Void) async throws -> [String: Any] {
            let result = try await transform(payload)
            guard streamNext else { return result }
            streamNext = false
            let failAfterProgress = failStreamNext; failStreamNext = false
            streaming = true
            defer { streaming = false }
            let text = result["text"] as? String ?? ""
            lateProgress = onProgress
            onProgress(["text": "AI:", "delta": "AI:", "model": "fixture-model"])
            while !releaseStream { try await Task.sleep(nanoseconds: 20_000_000) }
            try Task.checkCancellation()
            if failAfterProgress { throw Failure(message: "Synthetic streaming failure after partial text.") }
            let middle = String(text.prefix(max(3, text.count / 2)))
            onProgress(["text": middle, "delta": String(middle.dropFirst(3)), "model": "fixture-model"])
            try await Task.sleep(nanoseconds: 40_000_000)
            onProgress(["text": text, "delta": String(text.dropFirst(middle.count)), "model": "fixture-model"])
            return result
        }

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
                    headless: true, testTransform: transform,
                    testStreamingTransform: live ? nil : { payload, onProgress in
                        try await probe.transformStreaming(payload, onProgress: onProgress)
                    })
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
            let quotedSample = String(decoding: try JSONSerialization.data(withJSONObject: sample, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
            var samplePayload = "{\"text\":" + quotedSample + ",\"targetLanguage\":\"zh-CN\"}"
            let initial = try await manager.performCommand(for: id, text: sample)
            try check(initial.text == "AI:" + samplePayload && initial.model == "fixture-model", "Translation did not round-trip through the AI capability bridge.")
            try check(probe.latest["text"] as? String == samplePayload && probe.latest["targetLanguage"] as? String == "zh-CN",
                      "The actual Translation source did not receive its text or default settings.")
            try check(Data((probe.latest["systemPrompt"] as? String ?? "").utf8) == Data((snapshot.resources["prompts/translate.txt"] ?? "").utf8) &&
                      probe.latest["guidance"] == nil,
                      "Normal translation did not send the exact extension-owned prompt independently of user data.")
            note("actual Translation JavaScript invokes the explicit AI bridge and returns model metadata")

            let selectedWord = "ready"
            let surroundingSentence = "The project is ready for review."
            let callsBeforeInvalidContext = probe.calls
            for invalidSentence in ["", "A different surrounding sentence.", "ready\0",
                                    "ready " + String(repeating: "x", count: 2_000)] {
                var rejected = false
                do { _ = try await manager.performCommand(for: id, text: selectedWord, sentence: invalidSentence) }
                catch { rejected = true }
                try check(rejected, "Invalid selection context reached the extension command.")
            }
            try check(probe.calls == callsBeforeInvalidContext, "Invalid selection context triggered an AI request.")
            note("invalid, unrelated, or oversized selection context is rejected before AI inference")

            var wordProgress: [String] = []
            var wordFinished = false
            probe.streamNext = true; probe.releaseStream = false
            let contextualWord = Task {
                defer { wordFinished = true }
                return try await manager.performCommand(for: id, text: selectedWord, sentence: surroundingSentence) { update in
                    wordProgress.append(update.text)
                }
            }
            try await eventually("Contextual word translation did not stream through the real JavaScript worker.") {
                probe.streaming && !wordProgress.isEmpty
            }
            try check(!wordFinished && wordProgress == ["AI:"], "Contextual word translation buffered its partial result until completion.")
            let wordPayloadText = probe.latest["text"] as? String ?? ""
            let wordPayload = try JSONSerialization.jsonObject(with: Data(wordPayloadText.utf8)) as? [String: Any]
            try check(wordPayload?["selectedWord"] as? String == selectedWord &&
                      wordPayload?["surroundingSentence"] as? String == surroundingSentence,
                      "The real manager/worker bridge lost the selected word or optional surrounding sentence.")
            try check(probe.latest["action"] as? String == "translate" && probe.latest["targetLanguage"] as? String == "zh-CN",
                      "Word lookup changed the supported AI action or lost the shared target-language setting.")
            let wordPrompt = snapshot.resources["prompts/word-in-context.txt"] ?? ""
            try check(Data((probe.latest["systemPrompt"] as? String ?? "").utf8) == Data(wordPrompt.utf8) &&
                      probe.latest["guidance"] == nil && wordPayload?["targetLanguage"] as? String == "zh-CN" &&
                      (wordPayload?["labels"] as? [String: String])?["sentence"] != nil,
                      "Word translation did not send its dedicated source prompt verbatim with separate language/label data.")
            probe.releaseStream = true
            let contextualWordResult = try await contextualWord.value
            try check(contextualWordResult.text == "AI:" + wordPayloadText && contextualWordResult.model == "fixture-model" &&
                      wordProgress.count == 3 && wordProgress.last == contextualWordResult.text,
                      "Contextual word progress failed to reconcile with the fake AI's final payload answer.")
            note("selected-word context crosses the real manager/worker bridge and streams with the dedicated word prompt")

            var progress: [String] = []
            var streamFinished = false
            probe.streamNext = true; probe.releaseStream = false
            let streamed = Task {
                defer { streamFinished = true }
                return try await manager.performCommand(for: id, text: sample) { update in
                    progress.append(update.text)
                }
            }
            try await eventually("Translation did not forward partial text while AI was still running.") { probe.streaming && !progress.isEmpty }
            try check(!streamFinished && progress == ["AI:"], "Translation buffered progress until completion or reordered its first chunk.")
            probe.releaseStream = true
            let streamedResult = try await streamed.value
            try check(streamedResult.text == "AI:" + samplePayload && progress.count == 3 && progress.last == streamedResult.text &&
                      progress[1].hasPrefix(progress[0]) && progress[2].hasPrefix(progress[1]),
                      "Partial results arrived out of order or failed to reconcile with the final result.")
            note("partial translations arrive before AI completion, in order, and reconcile with the final answer")

            probe.streamNext = true; probe.releaseStream = false; probe.failStreamNext = true
            var failureProgress: [String] = []
            let failedStream = Task { () -> Bool in
                do { _ = try await manager.performCommand(for: id, text: sample) { failureProgress.append($0.text) }; return false }
                catch { return true }
            }
            try await eventually("The streaming failure fixture did not deliver partial text.") { !failureProgress.isEmpty }
            probe.releaseStream = true
            try check(await failedStream.value && failureProgress == ["AI:"], "A failed partial stream was reported as a completed answer.")
            note("an AI failure after partial text remains a failure instead of completing with an incomplete answer")

            probe.streamNext = true; probe.releaseStream = false
            var cancelledProgress: [String] = []
            let streamingPID = try remember(manager.workerPID(for: id))
            let activationBeforeRecovery = manager.activationGeneration(for: id)
            let cancelledStream = Task { () -> Bool in
                do { _ = try await manager.performCommand(for: id, text: sample) { cancelledProgress.append($0.text) }; return false }
                catch { return true }
            }
            try await eventually("The streaming cancellation fixture did not deliver partial text.") { !cancelledProgress.isEmpty }
            let lateProgress = probe.lateProgress
            cancelledStream.cancel()
            try check(await cancelledStream.value, "Cancelling a partially translated message returned a completed answer.")
            try await eventually("Streaming cancellation did not reap its worker.") { !processExists(streamingPID) }
            probe.releaseStream = true
            lateProgress?(["text": "STALE STREAM MUST STAY HIDDEN", "delta": "STALE", "model": "fixture-model"])
            try await Task.sleep(nanoseconds: 80_000_000)
            try check(cancelledProgress == ["AI:"], "Late progress from a cancelled translation reached its display callback.")
            try check(try await manager.performCommand(for: id, text: sample).text == "AI:" + samplePayload,
                      "Translation did not recover after cancelling a partial stream.")
            try check(manager.activationGeneration(for: id) == activationBeforeRecovery,
                      "Recovering a stopped process changed the unchanged source activation and blocked an explicit retry.")
            _ = try remember(manager.workerPID(for: id))
            note("cancelling a partial stream rejects late updates, stops its worker, and permits a fresh translation")

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
            try check(try await manager.performCommand(for: id, text: sample).text == "Edited: AI:" + samplePayload,
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
            try check(Data((probe.latest["systemPrompt"] as? String ?? "").utf8) == Data((prompt + "\n" + markerText + "\n").utf8), "The new source prompt did not reach the AI capability verbatim.")
            note("saving nested prompt resources updates the next AI request")

            probe.streamNext = true; probe.releaseStream = false
            var reloadedStreamProgress: [String] = []
            let streamBeforeReloadPID = try remember(manager.workerPID(for: id))
            let activationBeforeReload = manager.activationGeneration(for: id)
            let countBeforeStreamingReload = try info(manager).reloadCount
            let replacedStream = Task { () -> Bool in
                do { _ = try await manager.performCommand(for: id, text: sample) { reloadedStreamProgress.append($0.text) }; return false }
                catch { return true }
            }
            try await eventually("The reload-during-stream fixture did not deliver partial text.") { !reloadedStreamProgress.isEmpty }
            let oldStreamEmitter = probe.lateProgress
            let runningPrompt = try String(contentsOf: promptURL, encoding: .utf8)
            try (runningPrompt + "\nA resource saved while a translation is streaming.\n").write(to: promptURL, atomically: true, encoding: .utf8)
            try await eventually("Editing a running stream did not replace its source generation.") {
                ((try? info(manager).reloadCount) ?? 0) > countBeforeStreamingReload && manager.workerPID(for: id) != streamBeforeReloadPID
            }
            try check(await replacedStream.value, "A replaced stream incorrectly completed its old command.")
            try check(manager.activationGeneration(for: id) != activationBeforeReload,
                      "A source reload reused the old activation identity and could retain a stale preview.")
            try await eventually("Reloading a running stream did not reap its old worker.") { !processExists(streamBeforeReloadPID) }
            oldStreamEmitter?(["text": "STALE RELOADED STREAM", "delta": "STALE", "model": "fixture-model"])
            probe.releaseStream = true
            try await Task.sleep(nanoseconds: 80_000_000)
            try check(reloadedStreamProgress == ["AI:"], "A replaced source generation delivered stale progress.")
            let promptPIDAfterStreamingReload = try remember(manager.workerPID(for: id))
            try check(try await manager.performCommand(for: id, text: sample).text == "Edited: AI:" + samplePayload,
                      "The new source generation did not work after replacing a streaming operation.")
            note("saving source during a partial stream cancels its old generation and suppresses late progress")

            let countBeforeSyntaxError = try info(manager).reloadCount
            try (editedMain + "\nMacHelper.define({\n").write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("An invalid JavaScript save did not report a reload error.") { (try? info(manager).error) != nil }
            try check(manager.workerPID(for: id) == promptPIDAfterStreamingReload && (try info(manager)).reloadCount == countBeforeSyntaxError,
                      "An invalid edit replaced the last working worker.")
            let promptBeforeInvalidSave = try Data(contentsOf: promptURL)
            var invalidSourcePromptRejected = false
            do {
                try await manager.updatePrompt("translationPrompt", value: "A draft that must stay unsaved.",
                                               expectedValue: manager.promptValue("translationPrompt", for: id), for: id)
            } catch { invalidSourcePromptRejected = true }
            try check(invalidSourcePromptRejected && (try Data(contentsOf: promptURL)) == promptBeforeInvalidSave,
                      "Saving a prompt overwrote source while an invalid JavaScript edit was awaiting repair.")
            try check(try await manager.performCommand(for: id, text: sample).text == "Edited: AI:" + samplePayload,
                      "The last working version stopped serving results after a syntax error.")
            note("syntax errors are visible while the last working generation remains usable")

            let recoveredMain = originalMain.replacingOccurrences(of: outputNeedle, with: "text: \"Recovered: \" + response.text")
            try recoveredMain.write(to: mainURL, atomically: true, encoding: .utf8)
            try await eventually("Fixing invalid source did not recover automatically.") {
                guard let value = try? info(manager) else { return false }
                return value.error == nil && value.reloadCount > countBeforeSyntaxError
            }
            _ = try remember(manager.workerPID(for: id))
            try check(try await manager.performCommand(for: id, text: sample).text == "Recovered: AI:" + samplePayload,
                      "The repaired source did not become active.")
            note("fixing source clears the reload error and activates the repaired version")

            try await manager.updateSetting("targetLanguage", value: "en", for: id)
            samplePayload = "{\"text\":" + quotedSample + ",\"targetLanguage\":\"en\"}"
            _ = try remember(manager.workerPID(for: id))
            _ = try await manager.performCommand(for: id, text: sample)
            try check(probe.latest["targetLanguage"] as? String == "en" && probe.latest["text"] as? String == samplePayload &&
                      probe.latest["guidance"] == nil,
                      "Updated per-extension language settings did not reach JavaScript as separate input data.")
            let settingsFile = state.appendingPathComponent("ExtensionSettings/" + id + "/settings.json")
            let savedSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any]
            try check(savedSettings?["targetLanguage"] as? String == "en" && savedSettings?.count == 1 &&
                      savedSettings?["translationPrompt"] == nil && savedSettings?["wordPrompt"] == nil,
                      "Ordinary language settings were not persisted independently of source prompts.")
            try check(try privatePermissions(settingsFile) == 0o600, "Extension settings must be private on disk.")
            note("extension settings update live, persist independently, and use private file permissions")

            let oldPrompt = try manager.promptValue("translationPrompt", for: id)
            let exactPrompt = "  \r\n\t" + oldPrompt + "\r\n\n"
            let callsBeforePromptSave = probe.calls
            let promptSaveCount = try info(manager).reloadCount
            try await manager.updatePrompt("translationPrompt", value: exactPrompt, expectedValue: oldPrompt, for: id)
            _ = try remember(manager.workerPID(for: id))
            try check((try info(manager)).reloadCount > promptSaveCount && probe.calls == callsBeforePromptSave &&
                      (try Data(contentsOf: promptURL)) == Data(exactPrompt.utf8) &&
                      Data((try manager.promptValue("translationPrompt", for: id)).utf8) == Data(exactPrompt.utf8),
                      "Explicit prompt save changed whitespace, ran AI, or failed to refresh the active generation.")
            _ = try await manager.performCommand(for: id, text: sample)
            try check(Data((probe.latest["systemPrompt"] as? String ?? "").utf8) == Data(exactPrompt.utf8) && probe.latest["guidance"] == nil,
                      "A saved general prompt acquired hidden instructions or changed bytes on the worker bridge.")
            let oldWordPrompt = try manager.promptValue("wordPrompt", for: id)
            let exactWordPrompt = "\n  " + oldWordPrompt + "\r\n\n"
            try await manager.updatePrompt("wordPrompt", value: exactWordPrompt, expectedValue: oldWordPrompt, for: id)
            _ = try remember(manager.workerPID(for: id))
            _ = try await manager.performCommand(for: id, text: selectedWord, sentence: surroundingSentence)
            try check(Data((probe.latest["systemPrompt"] as? String ?? "").utf8) == Data(exactWordPrompt.utf8),
                      "The second prompt field was not independently editable or was rewritten by the host.")
            let promptState = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any]
            try check(promptState?.count == 1 && promptState?["targetLanguage"] as? String == "en" &&
                      promptState?["translationPrompt"] == nil && promptState?["wordPrompt"] == nil,
                      "Prompt source text leaked into ordinary extension settings.")
            note("explicit prompt saves preserve exact source bytes, hot reload both prompt fields, and forward each verbatim without settings copies")

            let validPromptCount = try info(manager).reloadCount
            for invalid in ["", " \n\t", "Invalid\0prompt", String(repeating: "x", count: 12_001)] {
                var rejected = false
                do { try await manager.updatePrompt("translationPrompt", value: invalid, expectedValue: exactPrompt, for: id) }
                catch { rejected = true }
                try check(rejected && (try Data(contentsOf: promptURL)) == Data(exactPrompt.utf8) &&
                          (try info(manager)).reloadCount == validPromptCount,
                          "An invalid prompt replaced the saved source or reloaded its last working generation.")
            }
            let externalPrompt = exactPrompt + "\n"
            try Data(externalPrompt.utf8).write(to: promptURL, options: .atomic)
            var stalePromptRejected = false
            do { try await manager.updatePrompt("translationPrompt", value: "Keep my editor draft", expectedValue: exactPrompt, for: id) }
            catch { stalePromptRejected = true }
            try check(stalePromptRejected && (try Data(contentsOf: promptURL)) == Data(externalPrompt.utf8),
                      "A stale prompt editor overwrote a newer external source edit.")
            try await eventually("Explicit prompt save failed to restore the source watcher.") {
                ((try? info(manager).reloadCount) ?? 0) > validPromptCount
            }
            _ = try remember(manager.workerPID(for: id))
            note("invalid or stale prompt saves preserve source and the last working generation; later external edits still hot reload")

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
            try check(completedFirst.text == "Recovered: AI:" + samplePayload && completedFirst.model == "fixture-model",
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
            try check(try await manager.performCommand(for: id, text: sample).text == "Recovered: AI:" + samplePayload,
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
            try check(restarted.settings(for: id)["targetLanguage"] as? String == "en" && restarted.settings(for: id).count == 1,
                      "Settings were lost when restarting the manager.")
            try check(try await restarted.performCommand(for: id, text: sample).text == "Recovered: AI:" + samplePayload,
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

            // This independently authored tool uses unrelated field names and
            // no AI capability. Its deliberately throwing entry proves that
            // viewing/configuring a disabled tool never evaluates JavaScript.
            let externalID = "com.example.personal-greeting"
            let external = workspace.appendingPathComponent("external-greeting.macsource", isDirectory: true)
            try FileManager.default.createDirectory(at: external.appendingPathComponent("config"), withIntermediateDirectories: true)
            let externalManifest = SourceExtensionManifest(identifier: externalID, displayName: "Personal Greeting", version: "1.0.0",
                summary: "An independently authored settings fixture.", permissions: ["ui.panel"],
                commands: [.init(identifier: "greet", title: "Greet", trigger: "manual"),
                           .init(identifier: "secondary", title: "Secondary", trigger: "manual")], settingsSchema: "config/preferences.json")
            try JSONEncoder().encode(externalManifest).write(to: external.appendingPathComponent("extension.json"), options: .atomic)
            try "throw new Error('Settings must not execute this tool.');".write(to: external.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            var externalFields: [[String: Any]] = [
                ["key": "greeting", "label": "Greeting words", "type": "text", "default": "Hello"],
                ["key": "loud", "label": "Use uppercase", "type": "boolean", "default": false],
                ["key": "punctuation", "label": "Ending", "type": "select", "default": "!",
                 "options": [["value": "!", "label": "Exclamation"], ["value": ".", "label": "Period"]]],
                ["key": "personalPrompt", "label": "Personal instructions", "type": "prompt", "path": "config/instructions.txt"]
            ]
            func externalSchema() throws -> Data {
                try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fields": externalFields], options: [.sortedKeys])
            }
            try externalSchema().write(to: external.appendingPathComponent("config/preferences.json"), options: .atomic)
            try Data("External tool instructions.\n".utf8).write(to: external.appendingPathComponent("config/instructions.txt"))
            let callsBeforeSettings = probe.calls
            try await restarted.importSource(from: external)
            try await restarted.prepareSettings(for: externalID)
            try check(restarted.settingsSchema(for: externalID)?.fields.map(\.key) == ["greeting", "loud", "punctuation", "personalPrompt"] &&
                      restarted.settings(for: externalID)["greeting"] as? String == "Hello" &&
                      restarted.permissions(for: externalID) == ["ui.panel"] && restarted.workerPID(for: externalID) == nil &&
                      restarted.tools.first(where: { $0.id == externalID })?.isEnabled == false && probe.calls == callsBeforeSettings,
                      "An unrelated disabled extension's own schema did not load without executing code or AI.")
            try await restarted.updateSetting("greeting", value: "Welcome", for: externalID)
            try await restarted.updateSetting("loud", value: true, for: externalID)
            try await restarted.updateSetting("punctuation", value: ".", for: externalID)
            guard let externalSource = restarted.sourceURL(for: externalID) else { throw Failure(message: "The external fixture source is missing.") }
            let disabledPrompt = "  Independent prompt.\r\n\tSaved while disabled.\n\n"
            try await restarted.updatePrompt("personalPrompt", value: disabledPrompt,
                                             expectedValue: restarted.promptValue("personalPrompt", for: externalID), for: externalID)
            try check((try Data(contentsOf: externalSource.appendingPathComponent("config/instructions.txt"))) == Data(disabledPrompt.utf8) &&
                      restarted.workerPID(for: externalID) == nil && probe.calls == callsBeforeSettings &&
                      restarted.tools.first(where: { $0.id == externalID })?.isEnabled == false &&
                      restarted.settings(for: externalID)["personalPrompt"] == nil,
                      "Saving an unrelated disabled tool's prompt executed JavaScript/AI, enabled it, or copied prompt text to settings.")
            note("a disabled external tool edits its own prompt resource without evaluating its deliberately throwing JavaScript or enabling AI")
            let externalSchemaURL = externalSource.appendingPathComponent("config/preferences.json")
            externalFields.append(["key": "signature", "label": "Signature", "type": "text", "default": " / local"])
            try externalSchema().write(to: externalSchemaURL, options: .atomic)
            try await restarted.prepareSettings(for: externalID)
            try check(restarted.settingsSchema(for: externalID)?.fields.last?.key == "signature" &&
                      restarted.settings(for: externalID)["signature"] as? String == " / local" &&
                      restarted.settings(for: externalID)["greeting"] as? String == "Welcome",
                      "Selecting a disabled tool did not reread its edited schema while preserving saved values.")
            try await restarted.updateSetting("signature", value: " / custom", for: externalID)
            let externalSettingsFile = state.appendingPathComponent("ExtensionSettings/" + externalID + "/settings.json")
            let externalSaved = try JSONSerialization.jsonObject(with: Data(contentsOf: externalSettingsFile)) as? [String: Any]
            try check(externalSaved?["greeting"] as? String == "Welcome" && externalSaved?["loud"] as? Bool == true &&
                      externalSaved?["signature"] as? String == " / custom" &&
                      restarted.workerPID(for: externalID) == nil && probe.calls == callsBeforeSettings,
                      "Saving disabled-tool settings did not persist independently or unexpectedly started AI/code.")
            note("a second external tool loads its own four field types on selection and saves disabled settings without running code")

            let externalMain = """
            MacHelper.define({commands:{greet(input){
              const s=input.settings;
              const text=(s.prefix||'')+s.greeting+' '+input.text+s.punctuation+s.signature;
              return {text:s.loud?text.toUpperCase():text};
            },secondary(input){return {text:'SECONDARY:'+input.text};}}});
            """
            try externalMain.write(to: externalSource.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            try await restarted.setEnabled(true, for: externalID)
            let externalPID = try remember(restarted.workerPID(for: externalID))
            try check(try await restarted.performCommand(for: externalID, text: "there").text == "WELCOME THERE. / CUSTOM",
                      "The external tool did not receive its independently saved settings.")
            try check(try await restarted.performCommand(for: externalID, text: "there", commandIdentifier: "secondary").text == "SECONDARY:there",
                      "Selecting a specific command silently invoked the first declared command.")
            var unknownCommandRejected = false
            do { _ = try await restarted.performCommand(for: externalID, text: "there", commandIdentifier: "missing") }
            catch { unknownCommandRejected = true }
            try check(unknownCommandRejected, "An unknown action silently fell back to a different command.")
            note("specific manifest command dispatch reaches the selected command and rejects unknown action identifiers")
            let externalReloads = restarted.tools.first(where: { $0.id == externalID })!.reloadCount
            externalFields.append(["key": "prefix", "label": "Prefix", "type": "text", "default": "New "])
            try externalSchema().write(to: externalSchemaURL, options: .atomic)
            try await eventually("A new external schema field did not hot reload.") {
                (restarted.tools.first(where: { $0.id == externalID })?.reloadCount ?? 0) > externalReloads
            }
            _ = try remember(restarted.workerPID(for: externalID))
            let externalReloadedResult = try await restarted.performCommand(for: externalID, text: "there")
            try check(restarted.workerPID(for: externalID) != externalPID &&
                      restarted.settingsSchema(for: externalID)?.fields.last?.key == "prefix" &&
                      externalReloadedResult.text == "NEW WELCOME THERE. / CUSTOM" &&
                      getpid() == hostPID && probe.calls == callsBeforeSettings,
                      "A schema field added outside the host required a rebuild or did not reach the refreshed worker.")
            note("external schema additions hot reload into a new worker and affect behavior without rebuilding the host")
            try await restarted.setEnabled(false, for: externalID)
            let validExternalSchema = try externalSchema()
            try Data("{broken".utf8).write(to: externalSchemaURL, options: .atomic)
            var rejectedInvalidSchema = false
            do { try await restarted.prepareSettings(for: externalID) } catch { rejectedInvalidSchema = true }
            var rejectedInvalidSave = false
            do { try await restarted.updateSetting("greeting", value: "Do not save", for: externalID) } catch { rejectedInvalidSave = true }
            try check(rejectedInvalidSchema && rejectedInvalidSave && restarted.settingsSchema(for: externalID)?.fields.last?.key == "prefix" &&
                      restarted.settings(for: externalID)["greeting"] as? String == "Welcome" && restarted.workerPID(for: externalID) == nil &&
                      restarted.tools.first(where: { $0.id == externalID })?.isEnabled == false,
                      "Invalid disabled source lost the last valid form, accepted stale-schema writes, or enabled code.")
            try validExternalSchema.write(to: externalSchemaURL, options: .atomic)
            try await restarted.prepareSettings(for: externalID)
            try check(restarted.tools.first(where: { $0.id == externalID })?.error == nil && probe.calls == callsBeforeSettings,
                      "Repairing a disabled tool's schema did not clear its configuration error without AI.")
            note("invalid disabled settings retain the last valid form, reject writes, and recover after a source repair")

            // Exercise two independently owned real workers while one streams.
            // The shared UI's reconciliation uses these exact activation tokens;
            // its pure tests separately assert preview/ticket preservation.
            try await restarted.setEnabled(true, for: id)
            try await restarted.setEnabled(true, for: externalID)
            let isolatedOwnerPID = try remember(restarted.workerPID(for: id))
            let isolatedOwnerGeneration = restarted.activationGeneration(for: id)
            let otherGeneration = restarted.activationGeneration(for: externalID)
            let otherPID = try remember(restarted.workerPID(for: externalID))
            let callsBeforeIsolation = probe.calls
            probe.streamNext = true; probe.releaseStream = false
            var isolatedProgress: [String] = []
            let isolatedStream = Task {
                try await restarted.performCommand(for: id, text: sample) { isolatedProgress.append($0.text) }
            }
            try await eventually("The independent-tool fixture did not enter a partial stream.") { !isolatedProgress.isEmpty }
            try await restarted.reload(externalID)
            _ = try remember(restarted.workerPID(for: externalID))
            try check(restarted.workerPID(for: externalID) != otherPID && restarted.activationGeneration(for: externalID) != otherGeneration &&
                      restarted.workerPID(for: id) == isolatedOwnerPID && restarted.activationGeneration(for: id) == isolatedOwnerGeneration &&
                      isolatedProgress == ["AI:"] && probe.streaming && probe.calls == callsBeforeIsolation + 1,
                      "Reloading an unrelated extension interrupted or replaced the active stream's owner.")
            probe.releaseStream = true
            let independentResult = try await isolatedStream.value
            try check(isolatedProgress.count > 1 && isolatedProgress.last.map { independentResult.text.hasSuffix($0) } == true,
                      "An independent owner failed to complete its stream after another tool reloaded.")
            try await restarted.setEnabled(false, for: externalID)
            try check(restarted.activationGeneration(for: id) == isolatedOwnerGeneration && restarted.workerPID(for: id) == isolatedOwnerPID,
                      "Disabling another tool changed the completed result's activation generation.")
            note("unrelated extension reload and disable preserve an active stream and its completed owner's activation generation")
            await restarted.stopAll()

            let market = SourceExtensionManager(workerExecutableURL: worker, helperExecutableURL: helper,
                bundledCatalogURL: catalogURL, stateDirectory: workspace.appendingPathComponent("market-state"),
                sourceDirectory: workspace.appendingPathComponent("market-source"), headless: true,
                testTransform: { payload in try await probe.transform(payload) })
            managers.append(market)
            await market.start()
            let beforeReview = try await requests(requestLogURL).filter { $0.hasPrefix("/Translation/") }
            let installRequest = try MarketplaceInstallRequest(catalogURL: catalogURL, extensionID: id, allowLocalDevelopment: true)
            let preview = try await market.previewMarketplaceInstall(installRequest)
            let afterReview = try await requests(requestLogURL).filter { $0.hasPrefix("/Translation/") }
            try check(afterReview.count == beforeReview.count + 1 && afterReview.last == "/Translation/extension.json" &&
                      market.sourceURL(for: id) == nil && market.workerPID(for: id) == nil,
                      "Marketplace review installed code or fetched more than its hash-verified manifest.")
            note("marketplace review fetches only verified metadata and never installs or executes before approval")
            try check(try await market.installReviewedMarketplaceTool(preview), "An approved marketplace package did not install.")
            _ = try remember(market.workerPID(for: id))
            guard let marketSource = market.sourceURL(for: id) else { throw Failure(message: "The approved marketplace source is missing.") }
            try check(try SourcePackageInspector.snapshot(at: marketSource).fileHashes == expectedHashes,
                      "The approved marketplace install omitted or changed source files.")
            note("approving a marketplace tool installs every verified source file and enables its worker")
            try await market.updateSetting("targetLanguage", value: "ja", for: id)
            let marketMain = marketSource.appendingPathComponent("main.js")
            let customMain = try String(contentsOf: marketMain, encoding: .utf8) + "\n// A user's existing local marketplace customization.\n"
            try customMain.write(to: marketMain, atomically: true, encoding: .utf8)
            try await market.setEnabled(false, for: id)
            try check(!(try await market.installReviewedMarketplaceTool(preview)), "A repeated marketplace click replaced installed source.")
            try check(try String(contentsOf: marketMain, encoding: .utf8) == customMain &&
                      market.workerPID(for: id) == nil && (try info(market)).isEnabled == false,
                      "A repeated marketplace click changed local edits or re-enabled a disabled tool.")
            let marketSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("market-state/ExtensionSettings/" + id + "/settings.json"))) as? [String: Any]
            try check(marketSettings?["targetLanguage"] as? String == "ja", "A repeated marketplace click reset saved settings.")
            note("repeated marketplace installation preserves local edits, preferences, and disabled state")
            await market.stopAll()

            let brokenMarket = SourceExtensionManager(workerExecutableURL: worker, helperExecutableURL: helper,
                bundledCatalogURL: catalogURL, bundledSeedDirectory: source,
                stateDirectory: workspace.appendingPathComponent("broken-market-state"),
                sourceDirectory: workspace.appendingPathComponent("broken-market-source"), headless: true,
                testTransform: { payload in try await probe.transform(payload) })
            managers.append(brokenMarket)
            await brokenMarket.start()
            let brokenRequest = try MarketplaceInstallRequest(catalogURL: catalogURL.deletingLastPathComponent().appendingPathComponent("broken-catalog.json"), extensionID: id, allowLocalDevelopment: true)
            let brokenPreview = try await brokenMarket.previewMarketplaceInstall(brokenRequest)
            var rejectedBrokenPackage = false
            do { _ = try await brokenMarket.installReviewedMarketplaceTool(brokenPreview) }
            catch { rejectedBrokenPackage = true }
            try check(rejectedBrokenPackage && brokenMarket.sourceURL(for: id) == nil && brokenMarket.workerPID(for: id) == nil,
                      "A failed reviewed source download installed partial code or silently substituted the bundled seed.")
            note("a reviewed download hash failure installs nothing and never substitutes the bundled offline seed")
            await brokenMarket.stopAll()
            report["sourceDownloadCount"] = try await requests(requestLogURL).filter { $0.hasPrefix("/Translation/") }.count

            if args.contains("--live") {
                let live = makeManager(live: true)
                await live.start()
                try await live.setEnabled(true, for: id)
                try await live.updateSetting("targetLanguage", value: "zh-CN", for: id)
                _ = try remember(live.workerPID(for: id))
                let liveStarted = ProcessInfo.processInfo.systemUptime
                var firstPartial: TimeInterval?
                var liveProgressCount = 0
                var liveCompleted = false
                var progressBeforeCompletion = false
                let response = try await live.performCommand(for: id, text: "Hello! The project is ready for review. The amount is $125.50. We will review the final design tomorrow and prepare the next development milestone after approval.") { update in
                    if firstPartial == nil { firstPartial = ProcessInfo.processInfo.systemUptime - liveStarted }
                    liveProgressCount += 1
                    if !liveCompleted { progressBeforeCompletion = true }
                }
                liveCompleted = true
                let liveElapsed = ProcessInfo.processInfo.systemUptime - liveStarted
                try check(progressBeforeCompletion && liveProgressCount > 0 && firstPartial != nil,
                          "The local AI returned only a final answer without streaming any partial translation.")
                report["liveProgressCount"] = liveProgressCount
                report["liveFirstPartialSeconds"] = firstPartial
                report["liveCompletionSeconds"] = liveElapsed
                try check(!response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && response.text.contains("125.50"),
                          "The optional local AI smoke test returned no translation or lost the amount.")
                try check(response.text.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }, "The optional live translation did not include Chinese text.")
                report["liveModel"] = response.model ?? ""
                report["liveAI"] = true
                note("real local AI streams a synthetic Chinese translation before the final answer without any Upwork interaction")
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
