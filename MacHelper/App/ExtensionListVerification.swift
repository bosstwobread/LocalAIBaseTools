import AppKit
import Darwin
import Foundation
import MacHelper

/// Exercises the actual offscreen list controls with isolated extension state.
/// It never observes other apps or opens source folders in an external editor.
@MainActor
enum ExtensionListVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() async -> Int32 {
        var manager: SourceExtensionManager?
        var workers: [Int32] = []
        var checks: [String] = []
        let hostPID = getpid()
        do {
            func option(_ key: String) throws -> String {
                guard let index = CommandLine.arguments.firstIndex(of: key),
                      CommandLine.arguments.indices.contains(index + 1) else {
                    throw Failure(message: "Missing list verification argument: " + key)
                }
                return CommandLine.arguments[index + 1]
            }
            let root = URL(fileURLWithPath: try option("--workspace-root"), isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            try check((try? String(contentsOf: root.appendingPathComponent(".mac-helper-list-verification"), encoding: .utf8)) == "isolated-list-workspace\n",
                      "Refusing an unmarked list verification workspace.")
            let state = root.appendingPathComponent("state"), sources = root.appendingPathComponent("extensions")
            try check(!FileManager.default.fileExists(atPath: state.path) && !FileManager.default.fileExists(atPath: sources.path),
                      "List verification state must start empty.")
            let worker = URL(fileURLWithPath: try option("--worker"))
            let helper = URL(fileURLWithPath: try option("--helper"))
            try check(FileManager.default.isExecutableFile(atPath: worker.path) && FileManager.default.isExecutableFile(atPath: helper.path),
                      "List verification executables are missing.")
            let catalogID = "com.example.list-catalog-only"
            let catalog = root.appendingPathComponent("catalog.json")
            let entry = SourceCatalogEntry(identifier: catalogID, displayName: "Z Catalog fixture", version: "1.0.0",
                summary: "Metadata-only test tool", files: [.init(path: "extension.json", url: "never-downloaded.json",
                    sha256: String(repeating: "0", count: 64), size: 0)])
            try JSONEncoder().encode(SourceCatalog(extensions: [entry])).write(to: catalog)
            let current = SourceExtensionManager(workerExecutableURL: worker, helperExecutableURL: helper,
                bundledCatalogURL: catalog, stateDirectory: state, sourceDirectory: sources, headless: false,
                testTransform: { _ in throw Failure(message: "The list verification must never request AI.") })
            manager = current
            await current.start()
            let a = "com.example.list-a", b = "com.example.list-b", c = "com.example.list-c"
            let native = "com.example.list-native"
            for (id, name) in [(a, "A fixture"), (b, "B fixture"), (c, "C fixture")] {
                let author = root.appendingPathComponent("authors/" + id)
                try writePackage(id: id, name: name, native: false, localized: id == b, to: author)
                try await current.importSource(from: author)
            }
            try await current.setEnabled(true, for: a)
            try await current.setEnabled(true, for: c)
            let initialA = try pid(current, a), stableC = try pid(current, c)
            workers += [initialA, stableC]
            var opened: [[URL]] = []
            var reviewedUpdates: [SourceExtensionUpdatePreview] = []
            var approveUpdate = false
            let applications = root.appendingPathComponent("Applications", isDirectory: true)
            let userApplications = root.appendingPathComponent("User/Applications", isDirectory: true)
            let chrome = applications.appendingPathComponent("Google Chrome.app")
            let edge = userApplications.appendingPathComponent("Browsers/Microsoft Edge.app")
            let missingEdge = applications.appendingPathComponent("Old Microsoft Edge.app")
            let foreignBundle = applications.appendingPathComponent("Example.app")
            let updaterCopy = root.appendingPathComponent("User/Library/Application Support/Microsoft/EdgeUpdater/apps/Microsoft Edge.app")
            let stagingCopy = root.appendingPathComponent("Applications Backup/Microsoft Edge.app")
            let nestedCopy = applications.appendingPathComponent("Setup.app/Contents/Resources/Microsoft Edge.app")
            let chromeID = SourceCompanionBrowser.chrome.appBundleIdentifier
            let edgeID = SourceCompanionBrowser.edge.appBundleIdentifier
            try writeBrowser(chrome, identifier: chromeID)
            try writeBrowser(foreignBundle, identifier: "com.example.not-edge")
            for copy in [updaterCopy, stagingCopy, nestedCopy] {
                try writeBrowser(copy, identifier: edgeID)
            }
            var registeredBrowsers = [chromeID: [chrome], edgeID: [updaterCopy, stagingCopy, nestedCopy, missingEdge, foreignBundle]]
            var runningBrowsers: [String: [URL]] = [:]
            let discovered = BrowserCompanionDiscovery(applicationDirectories: [applications, userApplications],
                registeredApplications: { registeredBrowsers[$0] ?? [] }, runningApplications: { runningBrowsers[$0] ?? [] })
            var detectionChanges = 0
            discovered.onChange = { detectionChanges += 1 }
            try check(discovered.applications == [.chrome: chrome], "An updater, staging, missing, or unrelated bundle was detected as installed.")
            discovered.refresh(launched: .edge, at: foreignBundle)
            try check(discovered.applications[.edge] == nil && detectionChanges == 0, "A launch with a mismatched bundle was accepted.")
            try writeBrowser(edge, identifier: edgeID)
            registeredBrowsers[edgeID]?.append(edge)
            discovered.refresh(launched: .edge, at: edge)
            try check(discovered.applications[.edge] == edge && detectionChanges == 1,
                      "A browser installed and launched later did not replace unrelated registrations.")
            discovered.refresh(launched: .edge, at: edge)
            discovered.refresh()
            try check(detectionChanges == 1, "Activating the same browser repeated setup.")
            let movedEdge = root.appendingPathComponent("Microsoft Edge.app")
            try FileManager.default.moveItem(at: edge, to: movedEdge)
            discovered.refresh()
            try check(discovered.applications[.edge] == nil && detectionChanges == 2,
                      "A removed browser remained available while Launch Services still listed it.")
            discovered.refresh(launched: .edge, at: movedEdge)
            try check(discovered.applications[.edge] == movedEdge && detectionChanges == 3,
                      "A valid browser launched outside Applications did not become available.")
            runningBrowsers[edgeID] = [movedEdge]
            discovered.refresh()
            try check(detectionChanges == 3, "Refreshing a browser that stayed running repeated setup.")
            runningBrowsers[edgeID] = nil
            discovered.refresh()
            try check(discovered.applications[.edge] == nil && detectionChanges == 4,
                      "A non-installed browser remained available after it stopped running.")
            checks.append("browser setup rejects updater, staged and stale registrations, detects later installs and running browsers, and avoids duplicate changes")
            let controller = ExtensionsViewController(manager: current, sourceFolderOpener: { urls, completion in
                opened.append(urls)
                completion(nil)
            }, sourceUpdateReviewer: { preview in
                reviewedUpdates.append(preview)
                return approveUpdate
            }, browserDiscovery: discovered)
            controller.loadViewIfNeeded()
            controller.view.frame = NSRect(x: 0, y: 0, width: 820, height: 700)
            controller.view.layoutSubtreeIfNeeded()
            try check(try field("batch-selection-count", in: controller).stringValue == "0 selected", "New tools were selected automatically.")
            try check(current.tools.contains { $0.id == catalogID && $0.sourceURL == nil }, "Missing catalog metadata fixture.")
            try check(find("source-tool-" + catalogID, in: controller.view) == nil &&
                      find("select-extension-" + catalogID, in: controller.view) == nil,
                      "A catalog-only tool appeared in the installed list.")
            checks.append("Extensions shows installed tools and excludes catalog-only entries")
            for id in ["batch-reload", "batch-edit-source", "batch-enable", "batch-disable"] {
                try check(!(try button(id, in: controller)).isEnabled, "A batch action was enabled without a selection.")
            }

            try await select([a, b], manager: current, controller: controller)
            try check(try button("batch-select-all", in: controller).state == .mixed, "Partial selection was not reflected by Select All.")
            try await click("batch-reload", in: controller)
            let reloadedA = try pid(current, a); workers.append(reloadedA)
            try check(reloadedA != initialA && current.workerPID(for: b) == nil && current.workerPID(for: c) == stableC,
                      "Batch reload enabled a disabled tool or touched an unselected worker.")
            try check(!(current.tools.first { $0.id == b }?.isEnabled ?? true), "Disabled reload changed enablement.")
            checks.append("real list selection reloads only enabled selected tools and leaves unselected workers unchanged")

            try await click("batch-enable", in: controller)
            let firstB = try pid(current, b); workers.append(firstB)
            try check(current.workerPID(for: a) == reloadedA && current.workerPID(for: c) == stableC,
                      "Batch enable restarted a tool already enabled.")
            try await click("batch-edit-source", in: controller)
            let expectedPaths = Set([current.sourceURL(for: a), current.sourceURL(for: b)].compactMap { $0?.path })
            try check(opened.count == 1 && Set(opened[0].map(\.path)) == expectedPaths,
                      "Batch Edit Source did not pass exactly the selected installed folders.")
            checks.append("batch enable skips enabled tools and Edit Source opens every selected folder through the shared opener")

            current.onChange?()
            controller.selectTool(a)
            try await drain(controller)
            controller.showOverview()
            try await drain(controller)
            try check(try button("select-extension-" + a, in: controller).state == .on &&
                      button("select-extension-" + b, in: controller).state == .on &&
                      field("batch-selection-count", in: controller).stringValue == "2 selected",
                      "Refresh or detail navigation lost the batch selection.")
            try await click("batch-select-all", in: controller)
            try check(try button("batch-select-all", in: controller).state == .on &&
                      field("batch-selection-count", in: controller).stringValue == "3 selected",
                      "Select All did not select exactly the installed tools.")
            try await click("batch-select-all", in: controller)
            try check(try field("batch-selection-count", in: controller).stringValue == "0 selected",
                      "Select All did not clear the installed selection.")
            try await select([a, b], manager: current, controller: controller)
            checks.append("checkboxes survive status refresh and detail navigation; Select All supports mixed state and excludes catalog tools")

            guard let installedA = current.sourceURL(for: a) else { throw Failure(message: "Fixture A source disappeared.") }
            try Data("Deliberately invalid JavaScript !!!\n".utf8).write(to: installedA.appendingPathComponent("main.js"), options: [.atomic])
            try await eventually("Invalid fixture did not report its watcher reload failure.") {
                current.tools.first { $0.id == a }?.error != nil
            }
            try check(current.workerPID(for: a) == reloadedA, "Watcher failure replaced the working fixture.")
            try await click("batch-reload", in: controller)
            let secondB = try pid(current, b); workers.append(secondB)
            try check(current.workerPID(for: a) == reloadedA && secondB != firstB && current.workerPID(for: c) == stableC,
                      "A failing batch item prevented another reload or touched an unselected worker.")
            let failureSummary = try field("extension-overview-message", in: controller).stringValue
            try check(failureSummary.contains("1 failed") && failureSummary.contains("Reloaded 1"),
                      "Batch summary did not distinguish the failed and successful items.")
            checks.append("one failed reload keeps its working process while later selected tools reload and report individual results")

            try await click("batch-disable", in: controller)
            try check(current.workerPID(for: a) == nil && current.workerPID(for: b) == nil && current.workerPID(for: c) == stableC,
                      "Batch disable touched an unselected tool or left selected workers running.")
            try check(try !button("batch-reload", in: controller).isEnabled && !button("batch-disable", in: controller).isEnabled,
                      "Disabled selections retained reload/disable actions.")
            checks.append("batch disable stops selected workers and updates list action eligibility")

            let nativeAuthor = root.appendingPathComponent("authors/" + native)
            try writePackage(id: native, name: "A Native fixture", native: true, to: nativeAuthor)
            try await current.importSource(from: nativeAuthor)
            controller.refreshDisplay()
            try check(try button("select-extension-" + native, in: controller).state == .off,
                      "A newly installed extension joined the selection automatically.")
            var nativeApprovals = 0
            current.onApproveNativeExecution = { manifest in
                if manifest.identifier == native { nativeApprovals += 1 }
                return false
            }
            try await select([native, b], manager: current, controller: controller)
            try await click("batch-enable", in: controller)
            workers.append(try pid(current, b))
            try check(nativeApprovals == 1 && current.workerPID(for: native) == nil && current.requiresNativeApproval(for: native) &&
                      current.workerPID(for: c) == stableC && current.workerPID(for: a) == nil,
                      "Cancelled native approval was bypassed or affected unrelated tools.")
            try check(!FileManager.default.fileExists(atPath: state.appendingPathComponent("NativeBuildCache").path),
                      "Cancelling native approval compiled code.")
            let cancellationSummary = try field("extension-overview-message", in: controller).stringValue
            try check(cancellationSummary.contains("1 cancelled") && cancellationSummary.contains("Enabled 1"),
                      "Native cancellation prevented the next selected extension from enabling.")
            checks.append("cancelled native approval never builds or runs native code and does not block another selected enable")

            // An external extension owns these labels, including an English
            // override. A resource-only edit must refresh its already-open form
            // from the running generation rather than stale prepared settings.
            try await current.updateSetting("choice", value: "two", for: b)
            let beforeLocalizedReload = try pid(current, b); workers.append(beforeLocalizedReload)
            controller.selectTool(b)
            try await drain(controller)
            guard let installedB = current.sourceURL(for: b) else { throw Failure(message: "Fixture B source disappeared.") }
            let settingsFile = state.appendingPathComponent("ExtensionSettings/" + b + "/settings.json")
            let settingsBytes = try Data(contentsOf: settingsFile)
            let promptFile = installedB.appendingPathComponent("prompts/fixture.txt")
            let promptBytes = try Data(contentsOf: promptFile)
            let sourceBytes = try Data(contentsOf: installedB.appendingPathComponent("main.js"))
            try check(labelValues(in: controller.view).contains("Initial localized setting") &&
                      labelValues(in: controller.view).contains("Initial localized prompt"),
                      "Extension-owned localization did not render schema or prompt labels.")
            guard let initialPopup = popup(label: "Initial localized setting", in: controller.view) else {
                throw Failure(message: "The localized settings control was not accessible by its extension-owned label.")
            }
            try check(initialPopup.itemTitles == ["Initial first option", "Initial second option"] &&
                      initialPopup.selectedItem?.representedObject as? String == "two",
                      "Extension-owned option labels changed the stored option identity.")
            let beforeReloadCount = current.tools.first { $0.id == b }?.reloadCount ?? 0
            try writeLocalizations(to: installedB, updated: true)
            try await eventually("Edited extension labels did not hot reload into the open form.") {
                controller.refreshDisplay()
                return (current.tools.first { $0.id == b }?.reloadCount ?? 0) > beforeReloadCount &&
                    labelValues(in: controller.view).contains("Updated localized setting") &&
                    labelValues(in: controller.view).contains("Updated localized prompt")
            }
            let afterLocalizedReload = try pid(current, b); workers.append(afterLocalizedReload)
            guard let updatedPopup = popup(label: "Updated localized setting", in: controller.view) else {
                throw Failure(message: "The open settings control retained its stale localized label after reload.")
            }
            try check(afterLocalizedReload != beforeLocalizedReload && current.workerPID(for: c) == stableC &&
                      current.workerPID(for: a) == nil && current.workerPID(for: native) == nil,
                      "A localization resource edit failed to replace its own worker or touched another tool.")
            try check(updatedPopup.itemTitles == ["Updated first option", "Updated second option"] &&
                      updatedPopup.selectedItem?.representedObject as? String == "two" &&
                      current.settings(for: b)["choice"] as? String == "two",
                      "Reloaded translated labels reset a stored setting or its selected option identity.")
            try check(try Data(contentsOf: settingsFile) == settingsBytes &&
                      Data(contentsOf: promptFile) == promptBytes &&
                      Data(contentsOf: installedB.appendingPathComponent("main.js")) == sourceBytes,
                      "Localizing interface labels rewrote settings, a source prompt, or command code.")
            let unchangedCommand = try await current.performCommand(for: b, text: "localization fixture input")
            try check(unchangedCommand.text == "localization fixture input" &&
                      (try current.promptValue("sourcePrompt", for: b)) == String(decoding: promptBytes, as: UTF8.self),
                      "Localizing the form changed command execution or the original source prompt.")
            checks.append("extension-owned schema and option labels hot reload in the open form while settings, prompt bytes, command behavior, and other workers remain unchanged")

            let updateCatalog = root.appendingPathComponent("update-catalog.json")
            let originalSource = try SourcePackageInspector.snapshot(at: installedB)
            try writeUpdate(b, version: "1.0.0", root: root, catalog: updateCatalog)
            try await current.addCatalog(from: updateCatalog)
            try check(try button("update-current-extension", in: controller).isHidden, "A matching version offered an update.")
            controller.showOverview()
            try await drain(controller)
            try check(find("update-extension-" + b, in: controller.view) == nil, "A matching version showed an update icon.")
            controller.view.layoutSubtreeIfNeeded()
            let originalCardSize = try button("source-tool-" + b, in: controller).bounds.size

            try writeUpdate(b, version: "2.0.0", root: root, catalog: updateCatalog,
                            script: "MacHelper.define({commands:{greet(input){return {text:'Updated '+input.text};}}});\n")
            try await click("check-for-extension-updates", in: controller)
            controller.view.layoutSubtreeIfNeeded()
            let updateIcon = try button("update-extension-" + b, in: controller)
            let updatedCard = try button("source-tool-" + b, in: controller)
            try check(updateIcon.isEnabled && updateIcon.image != nil && updateIcon.title.isEmpty &&
                      updateIcon.toolTip == "Version 2.0.0 available" &&
                      find("update-extension-" + c, in: controller.view) == nil,
                      "A newer release did not show the matching icon and version tooltip.")
            guard let container = updatedCard.superview, let row = container.superview else {
                throw Failure(message: "The updated card is missing its list row.")
            }
            let iconCenter = updateIcon.convert(NSPoint(x: updateIcon.bounds.midX, y: updateIcon.bounds.midY), to: row)
            let cardCenter = updatedCard.convert(NSPoint(x: updatedCard.bounds.midX, y: updatedCard.bounds.midY), to: row)
            try check(originalCardSize.width > 0 && originalCardSize.height > 0 && updatedCard.bounds.size == originalCardSize &&
                      updateIcon.superview === container && updatedCard.frame.contains(updateIcon.frame) &&
                      updateIcon.frame.midX > updatedCard.frame.midX && updateIcon.frame.midY > updatedCard.frame.midY &&
                      container.hitTest(iconCenter) === updateIcon && container.hitTest(cardCenter) === updatedCard,
                      "The update icon changed the card size or interfered with the card's own action.")
            controller.selectTool(b)
            try await drain(controller)
            let detailUpdate = try button("update-current-extension", in: controller)
            try check(!detailUpdate.isHidden && detailUpdate.isEnabled, "A newer release did not show the detail Update button.")
            try await click("update-current-extension", in: controller)
            try check(reviewedUpdates.count == 1 && reviewedUpdates[0].currentVersion == "1.0.0" &&
                      reviewedUpdates[0].manifest.version == "2.0.0" && reviewedUpdates[0].isLocallyModified &&
                      current.workerPID(for: b) == afterLocalizedReload,
                      "Update review omitted the local edits or versions, or cancellation restarted the worker.")
            try check((try SourcePackageInspector.snapshot(at: installedB)).fingerprint == originalSource.fingerprint,
                      "Cancelling the update changed the installed source.")
            approveUpdate = true
            controller.showOverview()
            try await drain(controller)
            try await click("update-extension-" + b, in: controller)
            let updatedPID = try pid(current, b); workers.append(updatedPID)
            let updatedSource = try SourcePackageInspector.snapshot(at: installedB)
            let backupFolders = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".source-backup-" + b + "-") }
            try check(backupFolders.count == 1, "Updating did not keep exactly one backup for the previous copy.")
            let backedUpSource = try SourcePackageInspector.snapshot(at: backupFolders[0])
            let updatedResult = try await current.performCommand(for: b, text: "fixture input")
            try check(reviewedUpdates.count == 2 && updatedPID != afterLocalizedReload && current.workerPID(for: c) == stableC &&
                      backedUpSource.fingerprint == originalSource.fingerprint &&
                      updatedSource.manifest.version == "2.0.0" &&
                      (try Data(contentsOf: settingsFile)) == settingsBytes && updatedResult.text == "Updated fixture input",
                      "Updating did not preserve the previous source/settings or activate only the intended worker.")
            controller.selectTool(b)
            try await drain(controller)
            try check(try button("update-current-extension", in: controller).isHidden, "The installed release still offered an update.")
            controller.showOverview()
            try await drain(controller)
            try check(find("update-extension-" + b, in: controller.view) == nil, "The list retained Update after installation.")
            checks.append("the installed list and detail show Update only for a newer catalog version, and updating backs up edited source while retaining settings")

            try writeUpdate(b, version: "3.0.0", root: root, catalog: updateCatalog, script: "Deliberately invalid JavaScript !!!\n")
            try await click("check-for-extension-updates", in: controller)
            try await click("update-extension-" + b, in: controller)
            let sourceAfterFailure = try SourcePackageInspector.snapshot(at: installedB)
            let resultAfterFailure = try await current.performCommand(for: b, text: "fixture input")
            try check(reviewedUpdates.count == 3 && reviewedUpdates[2].manifest.version == "3.0.0" &&
                      (try field("extension-overview-message", in: controller)).stringValue.hasPrefix("Extension error:") &&
                      current.workerPID(for: b) == updatedPID &&
                      sourceAfterFailure.fingerprint == updatedSource.fingerprint &&
                      resultAfterFailure.text == updatedResult.text,
                      "A broken release replaced the last working source or worker.")
            checks.append("a broken newer release leaves the current source and active worker intact")

            try check(getpid() == hostPID, "The host restarted during list actions.")
            await current.stopAll()
            try await eventually("List verification left a worker process running.") { workers.allSatisfy { !processExists($0) } }
            emit(["success": true, "hostPID": Int(hostPID), "workerPIDs": workers.map(Int.init), "checks": checks])
            return 0
        } catch {
            await manager?.stopAll()
            emit(["success": false, "hostPID": Int(hostPID), "workerPIDs": workers.map(Int.init),
                  "checks": checks, "error": error.localizedDescription])
            return 1
        }
    }

    private static func writeBrowser(_ app: URL, identifier: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private static func writePackage(id: String, name: String, native: Bool, localized: Bool = false,
                                     version: String = "1.0.0", script: String? = nil, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = SourceExtensionManifest(runtime: native ? "native" : "javascript", identifier: id,
            displayName: name, version: version, summary: "Synthetic extension-list fixture",
            entryPoint: native ? "Main.swift" : "main.js", permissions: native ? ["native.execute"] : [],
            commands: [.init(identifier: "greet", title: "Greet", trigger: "manual")],
            settingsSchema: localized ? "settings.schema.json" : nil,
            localizations: localized ? "localizations.json" : nil)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("extension.json"))
        let source = native
            ? "@main struct NativeListFixture { static func main() { MacHelperNative.run(commands: [\"greet\": { input in [\"text\": input.text] }]) } }\n"
            : "MacHelper.define({commands:{greet(input){return {text:input.text};}}});\n"
        try Data((script ?? source).utf8).write(to: folder.appendingPathComponent(manifest.entryPoint))
        if localized {
            let schema = """
            {"schemaVersion":1,"fields":[
              {"key":"choice","label":"Fixture setting","type":"select","default":"one","options":[
                {"value":"one","label":"First option"},{"value":"two","label":"Second option"}]},
              {"key":"sourcePrompt","label":"Fixture prompt","type":"prompt","path":"prompts/fixture.txt"}
            ]}
            """
            try Data(schema.utf8).write(to: folder.appendingPathComponent("settings.schema.json"))
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("prompts"), withIntermediateDirectories: true)
            try Data("Keep this exact prompt.\nDo not translate this source file.\n".utf8)
                .write(to: folder.appendingPathComponent("prompts/fixture.txt"))
            try writeLocalizations(to: folder, updated: false)
        }
    }

    private static func writeUpdate(_ identifier: String, version: String, root: URL, catalog: URL,
                                    script: String? = nil) throws {
        let directory = "updates/" + version
        let folder = root.appendingPathComponent(directory)
        try writePackage(id: identifier, name: "B fixture", native: false, localized: true,
                         version: version, script: script, to: folder)
        let package = try SourcePackageInspector.snapshot(at: folder)
        let files = try package.fileHashes.sorted(by: { $0.key < $1.key }).map { path, hash in
            let size = try Data(contentsOf: folder.appendingPathComponent(path)).count
            return SourceCatalogFile(path: path, url: directory + "/" + path, sha256: hash, size: size)
        }
        let manifest = package.manifest
        let entry = SourceCatalogEntry(identifier: identifier, displayName: manifest.displayName,
                                       version: version, summary: manifest.summary, files: files)
        try JSONEncoder().encode(SourceCatalog(extensions: [entry])).write(to: catalog, options: [.atomic])
    }

    private static func writeLocalizations(to folder: URL, updated: Bool) throws {
        let table = SourceTextLocalizations(translations: ["en": [
            "Fixture setting": updated ? "Updated localized setting" : "Initial localized setting",
            "Fixture prompt": updated ? "Updated localized prompt" : "Initial localized prompt",
            "First option": updated ? "Updated first option" : "Initial first option",
            "Second option": updated ? "Updated second option" : "Initial second option"
        ]])
        try JSONEncoder().encode(table).write(to: folder.appendingPathComponent("localizations.json"), options: [.atomic])
    }

    private static func select(_ ids: Set<String>, manager: SourceExtensionManager, controller: ExtensionsViewController) async throws {
        for tool in manager.tools where tool.sourceURL != nil {
            let checkbox = try button("select-extension-" + tool.id, in: controller)
            if (checkbox.state == .on) != ids.contains(tool.id) { try await click("select-extension-" + tool.id, in: controller) }
        }
        try check(try field("batch-selection-count", in: controller).stringValue == "\(ids.count) selected",
                  "The list selection count is incorrect.")
    }

    private static func click(_ id: String, in controller: ExtensionsViewController) async throws {
        let control = try button(id, in: controller)
        try check(control.isEnabled, "The expected list action is disabled: " + id)
        control.performClick(nil)
        try await drain(controller)
    }

    private static func drain(_ controller: ExtensionsViewController) async throws {
        try await eventually("The list operation queue did not finish.") { !controller.hasPendingOperations }
        controller.refreshDisplay()
    }

    private static func button(_ id: String, in controller: ExtensionsViewController) throws -> NSButton {
        guard let value = find(id, in: controller.view) as? NSButton else { throw Failure(message: "Missing list button: " + id) }
        return value
    }

    private static func field(_ id: String, in controller: ExtensionsViewController) throws -> NSTextField {
        guard let value = find(id, in: controller.view) as? NSTextField else { throw Failure(message: "Missing list label: " + id) }
        return value
    }

    private static func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews { if let value = find(id, in: child) { return value } }
        return nil
    }

    private static func popup(label: String, in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.accessibilityLabel() == label { return popup }
        for child in view.subviews { if let value = popup(label: label, in: child) { return value } }
        return nil
    }

    private static func labelValues(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { labelValues(in: $0) }
    }

    private static func pid(_ manager: SourceExtensionManager, _ id: String) throws -> Int32 {
        guard let value = manager.workerPID(for: id), value > 1, value != getpid() else { throw Failure(message: "No independent worker for: " + id) }
        return value
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private static func eventually(_ message: String, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        } while Date() < deadline
        throw Failure(message: message)
    }

    private static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

    private static func emit(_ report: [String: Any]) {
        let bytes = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: bytes, as: UTF8.self))
    }
}
