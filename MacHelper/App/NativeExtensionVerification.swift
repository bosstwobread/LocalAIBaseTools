import Darwin
import Foundation
import MacHelper
import Network

/// Real compiler/worker checks with synthetic inputs and isolated preferences.
/// This path never starts Accessibility monitors or opens a native window.
@MainActor
enum NativeExtensionVerification {
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
        var cancellations = 0

        func transform(_ payload: [String: Any], progress: @MainActor ([String: Any]) -> Void) async throws -> [String: Any] {
            calls += 1; latest = payload
            guard let text = payload["text"] as? String else { throw Failure(message: "Missing fixture AI input.") }
            progress(["text": "AI:", "delta": "AI:", "model": "fixture-native-model"])
            if blockNext {
                blockNext = false; blocked = true
                defer { blocked = false }
                do { while true { try await Task.sleep(nanoseconds: 20_000_000) } }
                catch { cancellations += 1; throw error }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            progress(["text": "AI:" + text, "delta": text, "model": "fixture-native-model"])
            return ["text": "AI:" + text, "model": "fixture-native-model"]
        }
    }

    static func run() async -> Int32 {
        let hostPID = getpid()
        var managers: [SourceExtensionManager] = []
        var workers: [Int32] = []
        var checks: [String] = []
        func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
        func remember(_ manager: SourceExtensionManager, _ id: String) throws -> Int32 {
            guard let pid = manager.workerPID(for: id), pid > 1, pid != hostPID else { throw Failure(message: "The extension did not start an independent worker.") }
            if !workers.contains(pid) { workers.append(pid) }
            return pid
        }
        do {
            func option(_ key: String) throws -> String {
                guard let index = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.indices.contains(index + 1) else {
                    throw Failure(message: "Missing native verification argument: " + key)
                }
                return CommandLine.arguments[index + 1]
            }
            let root = URL(fileURLWithPath: try option("--workspace-root"), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let marker = root.appendingPathComponent(".mac-helper-native-verification")
            try check((try? String(contentsOf: marker, encoding: .utf8)) == "isolated-native-workspace\n", "Refusing an unmarked native verification workspace.")
            let state = root.appendingPathComponent("state"), sources = root.appendingPathComponent("extensions")
            try check(!FileManager.default.fileExists(atPath: state.path) && !FileManager.default.fileExists(atPath: sources.path), "Native verification state must start empty.")
            let workerURL = URL(fileURLWithPath: try option("--worker")), helperURL = URL(fileURLWithPath: try option("--helper"))
            let sdkURL = URL(fileURLWithPath: try option("--native-sdk"))
            try check(FileManager.default.isExecutableFile(atPath: workerURL.path) && FileManager.default.isExecutableFile(atPath: helperURL.path), "Verification host executables are missing.")
            let catalog = root.appendingPathComponent("catalog.json")
            try JSONEncoder().encode(SourceCatalog(extensions: [])).write(to: catalog)
            let author = root.appendingPathComponent("author")
            try FileManager.default.createDirectory(at: author.appendingPathComponent("prompts"), withIntermediateDirectories: true)
            let id = "com.example.native-verification"
            let prompt = "  Preserve the user's complete instructions. Cafe\u{0301}.\n\n"
            try writeManifest(id: id, runtime: "native", to: author)
            try Data(nativeSource(tag: "one").utf8).write(to: author.appendingPathComponent("Main.swift"))
            try Data(prompt.utf8).write(to: author.appendingPathComponent("prompts/reply.txt"))
            try Data(#"{"schemaVersion":1,"fields":[{"key":"prefix","label":"Prefix","type":"text","default":"default"},{"key":"replyPrompt","label":"Prompt","type":"prompt","path":"prompts/reply.txt"}]}"#.utf8).write(to: author.appendingPathComponent("settings.schema.json"))
            let approvalState = root.appendingPathComponent("approval-state")
            let approvalManager = SourceExtensionManager(workerExecutableURL: workerURL, helperExecutableURL: helperURL,
                bundledCatalogURL: catalog, stateDirectory: approvalState, nativeSDKURL: sdkURL,
                sourceDirectory: root.appendingPathComponent("approval-sources"), headless: false)
            managers.append(approvalManager)
            await approvalManager.start()
            try await approvalManager.importSource(from: author)
            do { try await approvalManager.setEnabled(true, for: id); throw Failure(message: "Native code ran without an approval handler.") }
            catch is CancellationError { }
            var approvals = 0
            approvalManager.onApproveNativeExecution = { manifest in
                if manifest.identifier == id && manifest.permissions.contains("native.execute") { approvals += 1 }
                return false
            }
            do { try await approvalManager.setEnabled(true, for: id); throw Failure(message: "Native code ran after approval was denied.") }
            catch is CancellationError { }
            try check(approvals == 1 && approvalManager.workerPID(for: id) == nil &&
                      !FileManager.default.fileExists(atPath: approvalState.appendingPathComponent("NativeBuildCache").path),
                      "Denied native execution still built code or recorded approval.")
            try check(approvalManager.requiresNativeApproval(for: id), "Denied native execution was persisted as approved.")
            await approvalManager.stopAll()
            checks.append("native execution defaults to denied and a rejected approval never builds or launches code")
            let probe = AIProbe()
            func makeManager() -> SourceExtensionManager {
                let manager = SourceExtensionManager(workerExecutableURL: workerURL, helperExecutableURL: helperURL, bundledCatalogURL: catalog,
                    stateDirectory: state, nativeSDKURL: sdkURL, sourceDirectory: sources, headless: true,
                    testTransform: { payload in try await probe.transform(payload, progress: { _ in }) },
                    testStreamingTransform: { payload, progress in try await probe.transform(payload, progress: progress) })
                managers.append(manager)
                return manager
            }
            let manager = makeManager()
            await manager.start()
            try await manager.importSource(from: author)
            try await manager.prepareSettings(for: id)
            try await manager.updateSetting("prefix", value: "user", for: id)
            let editedPrompt = prompt + "Saved before enable.\n"
            try await manager.updatePrompt("replyPrompt", value: editedPrompt, expectedValue: prompt, for: id)
            try check(manager.workerPID(for: id) == nil && probe.calls == 0 && manager.requiresNativeApproval(for: id), "Disabled settings spawned native code or silently approved execution.")
            try check(!FileManager.default.fileExists(atPath: state.appendingPathComponent("NativeBuildCache").path), "Reading disabled native settings compiled code.")
            checks.append("disabled native settings and prompt editing never compile, execute, or request AI")

            try await manager.setEnabled(true, for: id)
            let first = try remember(manager, id)
            try check(!manager.requiresNativeApproval(for: id), "Explicit enable did not record native execution approval.")
            var progress: [String] = []
            let initial = try await manager.performCommand(for: id, text: "A public synthetic sentence.") { progress.append($0.text) }
            try check(initial.text == "user|one|AI:A public synthetic sentence." && initial.model == "fixture-native-model", "Native command or shared AI attribution is incorrect.")
            try check(progress.count >= 2 && probe.latest["systemPrompt"] as? String == editedPrompt && probe.latest["text"] as? String == "A public synthetic sentence.", "Native prompt/data or streaming changed in transit.")
            checks.append("approved native source compiles and runs in a separate worker with exact prompts and streamed shared AI")
            guard let installed = manager.sourceURL(for: id) else { throw Failure(message: "Imported native source is missing.") }

            try Data(nativeSource(tag: "two").utf8).write(to: installed.appendingPathComponent("Main.swift"), options: [.atomic])
            try await eventually("Native source save did not hot reload.") { manager.workerPID(for: id) != nil && manager.workerPID(for: id) != first && manager.tools.first(where: { $0.id == id })?.error == nil }
            let second = try remember(manager, id)
            let reloaded = try await manager.performCommand(for: id, text: "Native reload.")
            try check(reloaded.text == "user|two|AI:Native reload." && getpid() == hostPID, "Native reload did not replace only its worker.")
            try await eventually("Old native worker remained alive.") { !processExists(first) }
            checks.append("saving native Swift rebuilds and replaces only that worker while the MacHelper PID stays unchanged")

            try Data("This is deliberately invalid Swift.\n".utf8).write(to: installed.appendingPathComponent("Main.swift"), options: [.atomic])
            try await eventually("Invalid Swift did not report a reload error.") { manager.tools.first(where: { $0.id == id })?.error != nil }
            try check(manager.workerPID(for: id) == second, "A failed native build replaced the working worker.")
            let retained = try await manager.performCommand(for: id, text: "Still works.")
            try check(retained.text == "user|two|AI:Still works.", "The last good native command stopped after a failed build.")
            checks.append("failed native compilation preserves the last working process and command behavior")

            await manager.stopAll()
            let recovered = makeManager()
            await recovered.start()
            let recoveredPID = try remember(recovered, id)
            let recoveredResult = try await recovered.performCommand(for: id, text: "Recovery.")
            try check(recoveredResult.text == "user|two|AI:Recovery.", "Restart did not recover a last-good native source generation.")
            checks.append("restart recovers the approved last-good native generation without rewriting invalid user edits")
            try Data(nativeSource(tag: "three").utf8).write(to: installed.appendingPathComponent("Main.swift"), options: [.atomic])
            try await eventually("Repaired native source did not recover automatically.") { recovered.workerPID(for: id) != nil && recovered.workerPID(for: id) != recoveredPID && recovered.tools.first(where: { $0.id == id })?.error == nil }
            _ = try remember(recovered, id)
            let resourcePrompt = "  Resource update only.\n"
            let beforeResource = recovered.workerPID(for: id)
            try Data(resourcePrompt.utf8).write(to: installed.appendingPathComponent("prompts/reply.txt"), options: [.atomic])
            try await eventually("Native resource save did not reload.") { recovered.workerPID(for: id) != nil && recovered.workerPID(for: id) != beforeResource && recovered.tools.first(where: { $0.id == id })?.error == nil }
            _ = try remember(recovered, id)
            _ = try await recovered.performCommand(for: id, text: "Resource check.")
            try check(probe.latest["systemPrompt"] as? String == resourcePrompt, "Native generation did not read its new resource.")
            checks.append("repaired native code and editable prompt resources reload without resetting settings")

            let beforeScript = recovered.workerPID(for: id)
            try Data(scriptSource.utf8).write(to: installed.appendingPathComponent("main.js"), options: [.atomic])
            try writeManifest(id: id, runtime: "javascript", to: installed)
            try await eventually("Native to JavaScript runtime migration did not reload.") { recovered.workerPID(for: id) != nil && recovered.workerPID(for: id) != beforeScript && recovered.tools.first(where: { $0.id == id })?.runtime == "javascript" && recovered.tools.first(where: { $0.id == id })?.error == nil }
            _ = try remember(recovered, id)
            let scriptResult = try await recovered.performCommand(for: id, text: "Script migration.")
            try check(scriptResult.text == "user|script|AI:Script migration." && recovered.settings(for: id)["prefix"] as? String == "user", "Runtime migration lost the extension identity, setting or behavior.")
            // An explicit JavaScript enable records only the JavaScript grants.
            try await recovered.setEnabled(false, for: id)
            try await recovered.setEnabled(true, for: id)
            let scriptPID = try remember(recovered, id)
            try Data(nativeSource(tag: "four").utf8).write(to: installed.appendingPathComponent("Main.swift"), options: [.atomic])
            try writeManifest(id: id, runtime: "native", to: installed)
            try await eventually("JavaScript to native migration did not request renewed approval.") { recovered.tools.first(where: { $0.id == id })?.error?.contains("new permissions") == true }
            try check(recovered.workerPID(for: id) == scriptPID && recovered.requiresNativeApproval(for: id), "A runtime change silently ran unapproved native code.")
            let stillScript = try await recovered.performCommand(for: id, text: "Approval pending.")
            try check(stillScript.text == "user|script|AI:Approval pending.", "Pending native approval did not retain the working script.")
            try await recovered.setEnabled(false, for: id)
            try await recovered.setEnabled(true, for: id)
            _ = try remember(recovered, id)
            let nativeAgain = try await recovered.performCommand(for: id, text: "Approved migration.")
            try check(nativeAgain.text == "user|four|AI:Approved migration." && getpid() == hostPID, "Approved migration did not choose the native runtime automatically.")
            checks.append("one extension identity migrates native to script and back; new native execution requires approval and retains settings")

            probe.blockNext = true
            let beforeCancel = recovered.workerPID(for: id)
            let stale = Task { try await recovered.performCommand(for: id, text: "Cancelled synthetic input.") }
            try await eventually("Native fixture did not begin the cancellable AI action.") { probe.blocked }
            try Data(nativeSource(tag: "five").utf8).write(to: installed.appendingPathComponent("Main.swift"), options: [.atomic])
            try await eventually("Reload did not replace the busy native worker.") { recovered.workerPID(for: id) != nil && recovered.workerPID(for: id) != beforeCancel && recovered.tools.first(where: { $0.id == id })?.error == nil }
            _ = try remember(recovered, id)
            do { _ = try await stale.value; throw Failure(message: "A replaced native worker returned stale output.") }
            catch is Failure { throw Failure(message: "A replaced native worker returned stale output.") }
            catch { }
            try await eventually("Native reload left the old AI capability alive.") { !probe.blocked && probe.cancellations > 0 }
            checks.append("native reload cancels in-flight AI, rejects stale output, and reaps the old worker")

            try await recovered.setEnabled(false, for: id)
            let calls = probe.calls
            try await recovered.prepareSettings(for: id)
            try check(recovered.workerPID(for: id) == nil && probe.calls == calls, "Disabled native settings restarted execution.")
            let companionDirectory = root.appendingPathComponent("companion", isDirectory: true)
            let companionProbe = AIProbe()
            let companionManager = SourceExtensionManager(
                workerExecutableURL: workerURL, helperExecutableURL: helperURL, bundledCatalogURL: catalog,
                stateDirectory: root.appendingPathComponent("companion-state"), nativeSDKURL: sdkURL,
                sourceDirectory: root.appendingPathComponent("companion-sources"), headless: false,
                testTransform: { try await companionProbe.transform($0, progress: { _ in }) },
                companionSocketDirectory: companionDirectory
            )
            managers.append(companionManager)
            workers.append(contentsOf: try await verifyCompanions(
                authorDirectory: root, socketDirectory: companionDirectory, manager: companionManager, probe: companionProbe
            ))
            checks.append("approved native and JavaScript companion commands use exact routes, bounded AI, and live status and cancellation")
            for current in managers { await current.stopAll() }
            try await eventually("Native verification left a worker process running.") { workers.allSatisfy { !processExists($0) } }
            emit(["success": true, "hostPID": Int(hostPID), "workerPIDs": workers.map(Int.init), "checks": checks])
            return 0
        } catch {
            for manager in managers { await manager.stopAll() }
            emit(["success": false, "hostPID": Int(hostPID), "workerPIDs": workers.map(Int.init), "checks": checks, "error": error.localizedDescription])
            return 1
        }
    }

    private struct CompanionRequest: Encodable {
        let type: String
        let extensionID: String
        let companion: String
        var command: String? = nil
        var payload: String? = nil

        enum CodingKeys: String, CodingKey {
            case type, companion, command, payload
            case extensionID = "extension"
        }
    }

    private struct CompanionReply: Decodable {
        let ok: Bool?
        let payload: String?
        let error: String?
        let type: String?
        let enabled: Bool?
    }

    private static func verifyCompanions(authorDirectory: URL, socketDirectory: URL,
                                         manager: SourceExtensionManager, probe: AIProbe) async throws -> [Int32] {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw Failure(message: message) }
        }

        let nativeID = "com.example.native-companion"
        let scriptID = "com.example.script-companion"
        let nativeBrowser = String(repeating: "a", count: 32)
        let scriptBrowser = String(repeating: "b", count: 32)
        let endpoint = socketDirectory.appendingPathComponent("endpoint")
        let nativeSource = try makeCompanionFixture(in: authorDirectory, id: nativeID, browser: nativeBrowser, native: true)
        let scriptSource = try makeCompanionFixture(in: authorDirectory, id: scriptID, browser: scriptBrowser, native: false)
        let nativeWatch = CompanionRequest(type: "watchStatus", extensionID: nativeID, companion: nativeBrowser)
        let scriptWatch = CompanionRequest(type: "watchStatus", extensionID: scriptID, companion: scriptBrowser)
        let opaque = " Synthetic input with quotes: \"text\".\n"

        func invoke(_ id: String, _ browser: String, _ command: String, _ payload: String) async throws -> CompanionReply? {
            let message = CompanionRequest(type: "invoke", extensionID: id, companion: browser, command: command, payload: payload)
            let connection = try await openCompanionSocket(in: socketDirectory, request: message)
            defer { connection.cancel() }
            return try await readCompanionFrame(from: connection)
        }

        await manager.start()
        try await manager.importSource(from: nativeSource)
        try await manager.importSource(from: scriptSource)
        manager.onApproveNativeExecution = { $0.identifier == nativeID }
        manager.onApproveCompanion = { _, _ in false }
        do {
            try await manager.setEnabled(true, for: nativeID)
            throw Failure(message: "A denied companion grant started a worker.")
        } catch is CancellationError { }
        try check(manager.workerPID(for: nativeID) == nil && !FileManager.default.fileExists(atPath: endpoint.path),
                  "A denied companion grant exposed a worker or endpoint.")

        manager.onApproveCompanion = { manifest, grant in
            switch manifest.identifier {
            case nativeID: return grant.chromeExtensionID == nativeBrowser && grant.commands == ["ai", "echo"] && grant.allowsAI
            case scriptID: return grant.chromeExtensionID == scriptBrowser && grant.commands == ["echo", "no-ai"] && !grant.allowsAI
            default: return false
            }
        }
        try await manager.setEnabled(true, for: nativeID)
        try await manager.setEnabled(true, for: scriptID)
        guard let nativePID = manager.workerPID(for: nativeID), let scriptPID = manager.workerPID(for: scriptID),
              nativePID != scriptPID, nativePID != getpid(), scriptPID != getpid() else {
            throw Failure(message: "The companion fixtures did not run in independent workers.")
        }
        try await eventually("No approved companion endpoint was published.", timeout: 5) {
            FileManager.default.fileExists(atPath: endpoint.path)
        }

        let nativeWatcher = try await openCompanionSocket(in: socketDirectory, request: nativeWatch)
        let scriptWatcher = try await openCompanionSocket(in: socketDirectory, request: scriptWatch)
        defer { nativeWatcher.cancel(); scriptWatcher.cancel() }
        try await expectCompanionStatus(true, from: nativeWatcher)
        try await expectCompanionStatus(true, from: scriptWatcher)
        let wrongBrowser = try await invoke(nativeID, scriptBrowser, "echo", opaque)
        let wrongCommand = try await invoke(scriptID, scriptBrowser, "ai", opaque)
        try check(wrongBrowser?.error == "unavailable" && wrongCommand?.error == "unavailable",
                  "An unapproved companion identity or command reached a worker.")
        let nativeEcho = try await invoke(nativeID, nativeBrowser, "echo", opaque)
        let scriptEcho = try await invoke(scriptID, scriptBrowser, "echo", opaque)
        try check(nativeEcho?.ok == true && nativeEcho?.payload == opaque && scriptEcho?.ok == true && scriptEcho?.payload == opaque,
                  "A companion payload changed while crossing the worker boundary.")

        let deniedAI = try await invoke(scriptID, scriptBrowser, "no-ai", opaque)
        try check(deniedAI?.payload == "denied" && probe.calls == 0, "An ungranted companion invoked shared AI.")
        let translated = try await invoke(nativeID, nativeBrowser, "ai", opaque)
        try check(translated?.payload == "AI:" + opaque && probe.calls == 1 && probe.latest["model"] == nil &&
                  probe.latest["systemPrompt"] as? String == "Fixture instructions.\n",
                  "Companion AI ignored its one-call budget, used a model override, or changed the packaged prompt.")

        probe.blockNext = true
        let inFlight = Task { try await invoke(nativeID, nativeBrowser, "ai", opaque) }
        defer { inFlight.cancel() }
        try await eventually("The companion invocation did not reach the synthetic provider.", timeout: 5) { probe.blocked }
        manager.setSelectionActionsEnabled(false)
        try await expectCompanionStatus(false, from: nativeWatcher)
        try await expectCompanionStatus(false, from: scriptWatcher)
        try await eventually("Pausing MacHelper did not cancel in-flight companion AI.", timeout: 5) { probe.cancellations == 1 }
        let cancelled = try await inFlight.value
        try check(cancelled == nil, "A paused companion published a stale result.")
        let paused = try await invoke(scriptID, scriptBrowser, "echo", opaque)
        try check(paused?.error == "unavailable", "Paused MacHelper accepted a companion command.")
        manager.setSelectionActionsEnabled(true)
        try await expectCompanionStatus(true, from: nativeWatcher)
        try await expectCompanionStatus(true, from: scriptWatcher)

        try await manager.setEnabled(false, for: nativeID)
        try await expectCompanionStatus(false, from: nativeWatcher)
        guard let installed = manager.sourceURL(for: nativeID) else {
            throw Failure(message: "The disabled companion fixture was unexpectedly removed.")
        }
        try FileManager.default.removeItem(at: installed)
        let removed = try await readCompanionFrame(from: nativeWatcher)
        try check(removed == nil, "Removing one companion left its watcher open.")
        let retained = try await invoke(scriptID, scriptBrowser, "echo", opaque)
        try check(retained?.payload == opaque && probe.calls == 2, "Removing one companion disturbed the remaining route.")
        return [nativePID, scriptPID]
    }

    private static func makeCompanionFixture(in directory: URL, id: String, browser: String, native: Bool) throws -> URL {
        let source = directory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let entry = native ? "Main.swift" : "main.js"
        let permissions = [SourceCompanionGrant.permission] + (native ? ["native.execute", "ai.transform"] : [])
        let commands = ["echo", native ? "ai" : "no-ai"].map {
            SourceExtensionCommand(identifier: $0, title: $0, trigger: "companion")
        }
        let manifest = SourceExtensionManifest(runtime: native ? "native" : "javascript", identifier: id,
            displayName: "Companion fixture", version: "1.0.0", summary: "Isolated companion verification",
            entryPoint: entry, permissions: permissions, commands: commands,
            companion: SourceCompanion(chromeExtensionID: browser))
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("extension.json"))
        if native {
            let script = """
            import Foundation
            @main struct NativeCompanionFixture {
                static func main() {
                    MacHelperNative.run(commands: [
                        "echo": { ["text": $0.text] },
                        "ai": { input in
                            let request: [String: Any] = ["action": "translate", "text": input.text,
                                "model": "fixture-override", "systemPrompt": try input.readText("reply.txt")]
                            let answer = try await input.transform(request: request)
                            do {
                                _ = try await input.transform(request: request)
                                return ["text": "Exceeded the approved budget."]
                            } catch { return ["text": answer["text"] as? String ?? ""] }
                        }
                    ])
                }
            }
            """
            try Data(script.utf8).write(to: source.appendingPathComponent(entry))
            try Data("Fixture instructions.\n".utf8).write(to: source.appendingPathComponent("reply.txt"))
        } else {
            let script = """
            MacHelper.define({commands:{
                echo(input) { return {text:input.text}; },
                async "no-ai"(input) {
                    try {
                        await MacHelper.ai.transform({action:"translate",text:input.text});
                        return {text:"Denied capability executed."};
                    } catch { return {text:"denied"}; }
                }
            }});
            """
            try Data(script.utf8).write(to: source.appendingPathComponent(entry))
        }
        return source
    }

    private static func openCompanionSocket(in directory: URL, request: CompanionRequest) async throws -> NWConnection {
        let socket = try String(contentsOf: directory.appendingPathComponent("endpoint"), encoding: .utf8)
        let connection = NWConnection(to: .unix(path: directory.appendingPathComponent(socket).path), using: .tcp)
        let frame = try NativeFrameEncoder.encode(request)
        connection.start(queue: .global())
        do {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { result.resume(throwing: error) }
                    else { result.resume() }
                })
            }
        } catch {
            connection.cancel()
            throw error
        }
        return connection
    }

    private static func readCompanionFrame(from connection: NWConnection) async throws -> CompanionReply? {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(4)); connection.cancel() }
            catch { }
        }
        defer { deadline.cancel() }
        func read(_ count: Int) async throws -> Data? {
            try await withCheckedThrowingContinuation { result in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { result.resume(throwing: error) }
                    else { result.resume(returning: data) }
                }
            }
        }
        guard let header = try await read(4) else { return nil }
        guard header.count == 4 else { throw Failure(message: "An incomplete companion frame arrived.") }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard (1...CompanionService.maximumFrameBytes).contains(length), let body = try await read(length), body.count == length else {
            throw Failure(message: "A companion frame was invalid or unbounded.")
        }
        return try JSONDecoder().decode(CompanionReply.self, from: body)
    }

    private static func expectCompanionStatus(_ enabled: Bool, from connection: NWConnection) async throws {
        let update = try await readCompanionFrame(from: connection)
        guard update?.type == "status", update?.enabled == enabled else {
            throw Failure(message: "The companion watcher did not receive the expected effective status.")
        }
    }

    private static func writeManifest(id: String, runtime: String, to folder: URL) throws {
        let permissions = ["ai.transform", "ui.panel"] + (runtime == "native" ? ["native.execute"] : [])
        let manifest = SourceExtensionManifest(runtime: runtime, identifier: id, displayName: "Native verification",
            version: "1.0.0", summary: "Synthetic independent native fixture", entryPoint: runtime == "native" ? "Main.swift" : "main.js",
            permissions: permissions, commands: [.init(identifier: "greet", title: "Greet", trigger: "manual")], settingsSchema: "settings.schema.json")
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("extension.json"), options: [.atomic])
    }

    private static func nativeSource(tag: String) -> String {
        """
        import Foundation
        @main struct NativeVerificationMain {
            static func main() {
                MacHelperNative.run(commands: ["greet": { input in
                    let result = try await input.transform(request: ["action": "translate", "text": input.text,
                        "systemPrompt": try input.readText("prompts/reply.txt"), "model": ""], onProgress: { update in
                            try? input.reportProgress(text: "native-\(tag):" + (update["text"] as? String ?? ""), title: "Native fixture")
                        })
                    return ["text": (input.settings["prefix"] as? String ?? "missing") + "|\(tag)|" + (result["text"] as? String ?? "")]
                }])
            }
        }
        """
    }

    private static let scriptSource = """
    MacHelper.define({commands:{async greet(input){
        const result=await MacHelper.ai.transform({action:"translate",text:input.text,model:"",systemPrompt:MacHelper.readText("prompts/reply.txt")},
            update=>input.reportProgress({text:update.text,title:"Script fixture"}));
        return {text:input.settings.prefix+"|script|"+result.text};
    }}});
    """

    private static func eventually(_ message: String, timeout: TimeInterval = 45, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        throw Failure(message: message)
    }
    private static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }
    private static func emit(_ report: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }
}
