import Foundation
import JavaScriptCore
import Darwin

private enum WorkerError: Error { case invalid(String) }

/// This executable owns only a JavaScript VM. Native UI, files, network and AI
/// credentials remain in the host; JS sees a small explicit capability bridge.
@main
private enum ScriptWorkerMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        // A killed host cannot close a VM stuck inside user JavaScript. The
        // independent watchdog exits this worker after it loses its parent.
        let parentPID = getppid()
        let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        parentWatch.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        parentWatch.setEventHandler {
            if getppid() != parentPID || getppid() == 1 { _exit(0) }
        }
        parentWatch.resume()
        defer { parentWatch.cancel() }
        let worker = JavaScriptWorker()
        do {
            while let message = try readFrame() { worker.receive(message) }
        } catch {
            // The parent treats premature EOF as a protocol failure. Never print
            // a request, script, selected text or diagnostics on this channel.
        }
    }

    private static func readExactly(_ count: Int, allowEOF: Bool = false) throws -> Data? {
        var data = Data()
        while data.count < count {
            let next = FileHandle.standardInput.readData(ofLength: count - data.count)
            if next.isEmpty {
                if allowEOF && data.isEmpty { return nil }
                throw WorkerError.invalid("Incomplete frame")
            }
            data.append(next)
        }
        return data
    }

    private static func readFrame() throws -> [String: Any]? {
        guard let header = try readExactly(4, allowEOF: true) else { return nil }
        let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 256 * 1024,
              let data = try readExactly(Int(length)),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkerError.invalid("Invalid frame")
        }
        return object
    }
}

private final class JavaScriptWorker {
    private var context: JSContext?
    private var generation: String?
    private var loaded = false
    private var permissions = Set<String>()
    private var activeIDs = Set<String>()
    private var capabilityIDs = Set<String>()
    private var invocationIDs = Set<String>()
    private var exceptionMessage: String?

    func receive(_ message: [String: Any]) {
        guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let method = message["method"] as? String,
              let requestedGeneration = message["generation"] as? String,
              !requestedGeneration.isEmpty, requestedGeneration.utf8.count <= 128 else { return }
        if method == "load" {
            guard generation == nil else { respond(id, ok: false, error: "A worker process can load only one generation."); return }
            generation = requestedGeneration
            do { try load(message, id: id) }
            catch { respond(id, ok: false, error: "The extension could not be initialized.") }
            return
        }
        guard requestedGeneration == generation else { return }
        guard let context else { respond(id, ok: false, error: "Load the extension before invoking it."); return }
        switch method {
        case "invoke":
            guard loaded, let command = message["command"] as? String,
                  let input = message["input"] as? [String: Any], activeIDs.count < 8,
                  !activeIDs.contains(id), let json = jsonString(input) else {
                respond(id, ok: false, error: "The extension command request is invalid."); return
            }
            activeIDs.insert(id)
            invocationIDs.insert(id)
            exceptionMessage = nil
            context.objectForKeyedSubscript("__mhInvoke")?.call(withArguments: [id, command, json])
            if let error = exceptionMessage { finish(id: id, ok: false, encoded: error) }
        case "capabilityResult":
            guard capabilityIDs.remove(id) != nil, let ok = message["ok"] as? Bool else { return }
            let encoded = ok ? jsonString(message["result"] ?? NSNull()) : jsonString(message["error"] as? String ?? "The capability failed.")
            context.objectForKeyedSubscript("__mhCapabilityResult")?.call(withArguments: [id, ok, encoded ?? "null"])
        case "stop":
            activeIDs.insert(id)
            exceptionMessage = nil
            context.objectForKeyedSubscript("__mhStop")?.call(withArguments: [id])
            if let error = exceptionMessage { finish(id: id, ok: false, encoded: error) }
        default: respond(id, ok: false, error: "Unsupported worker method.")
        }
    }

    private func load(_ message: [String: Any], id: String) throws {
        guard let source = message["entrySource"] as? String, source.utf8.count <= 192 * 1024,
              let resources = message["resources"] as? [String: String], resources.count <= 128,
              let settings = message["settings"] as? [String: Any],
              let declared = message["permissions"] as? [String], declared.count <= 32,
              let context = JSContext(), let resourceJSON = jsonString(resources), let settingsJSON = jsonString(settings) else {
            respond(id, ok: false, error: "The source package load request is invalid.")
            return
        }
        self.context = context
        permissions = Set(declared)
        context.exceptionHandler = { [weak self] _, exception in
            self?.exceptionMessage = String((exception?.toString() ?? "JavaScript error").prefix(2048))
        }
        let finishBlock: @convention(block) (String, Bool, String) -> Void = { [weak self] id, ok, value in
            self?.finish(id: id, ok: ok, encoded: value)
        }
        let capabilityBlock: @convention(block) (String, String) -> Void = { [weak self] id, encoded in
            self?.requestCapability(id: id, encoded: encoded)
        }
        context.setObject(finishBlock, forKeyedSubscript: "__nativeFinish" as NSString)
        context.setObject(capabilityBlock, forKeyedSubscript: "__nativeCapability" as NSString)
        exceptionMessage = nil
        context.evaluateScript(Self.bootstrap(resources: resourceJSON, settings: settingsJSON))
        guard exceptionMessage == nil else { respond(id, ok: false, error: "The script runtime could not initialize."); return }
        context.evaluateScript(source, withSourceURL: URL(string: "machextension://source/main.js"))
        if let error = exceptionMessage { respond(id, ok: false, error: error); return }
        activeIDs.insert(id)
        context.objectForKeyedSubscript("__mhStart")?.call(withArguments: [id])
        if let error = exceptionMessage { finish(id: id, ok: false, encoded: error) }
    }

    private func requestCapability(id: String, encoded: String) {
        guard let context, capabilityIDs.count < 8, !capabilityIDs.contains(id),
              let data = encoded.data(using: .utf8), data.count <= 128 * 1024,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard loaded, !invocationIDs.isEmpty, permissions.contains("ai.transform") else {
            let message = loaded ? "This extension has not declared the ai.transform permission." : "AI requests require an explicit command invocation."
            context.objectForKeyedSubscript("__mhCapabilityResult")?.call(withArguments: [id, false, jsonString(message) ?? "null"])
            return
        }
        capabilityIDs.insert(id)
        send(["type": "capability", "id": id, "capability": "ai.transform", "payload": payload,
              "generation": generation ?? ""])
    }

    private func finish(id: String, ok: Bool, encoded: String) {
        guard activeIDs.remove(id) != nil else { return }
        invocationIDs.remove(id)
        if ok {
            guard let data = encoded.data(using: .utf8), data.count <= 192 * 1024,
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                respond(id, ok: false, error: "The extension must return a JSON value."); return
            }
            if let dictionary = value as? [String: Any], dictionary["__loaded"] as? Bool == true {
                loaded = true
            }
            respond(id, ok: true, result: value)
        } else {
            respond(id, ok: false, error: String(encoded.prefix(2048)))
        }
    }

    private func respond(_ id: String, ok: Bool, result: Any? = nil, error: String? = nil) {
        var object: [String: Any] = ["id": id, "ok": ok, "generation": generation ?? ""]
        if let result { object["result"] = result }
        if let error { object["error"] = error }
        send(object)
    }

    private func send(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object), !payload.isEmpty, payload.count <= 256 * 1024 else { return }
        let length = UInt32(payload.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        frame.append(payload)
        try? FileHandle.standardOutput.write(contentsOf: frame)
    }

    private func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func bootstrap(resources: String, settings: String) -> String {
        #"""
        (function (global) {
          "use strict";
          const resources = Object.freeze(\#(resources));
          const initialSettings = Object.freeze(\#(settings));
          const pending = new Map();
          let nextCapability = 0;
          let definition = null;
          const failure = error => String(error && error.message || error || "Extension failed").slice(0, 2048);
          const done = (id, operation) => Promise.resolve().then(operation).then(
            value => __nativeFinish(id, true, JSON.stringify(value === undefined ? {} : value)),
            error => __nativeFinish(id, false, failure(error)));
          const api = Object.freeze({
            define(value) {
              if (definition !== null || !value || typeof value !== "object" || !value.commands || typeof value.commands !== "object")
                throw new Error("Call MacHelper.define once with an object containing commands.");
              const keys = Object.keys(value.commands);
              if (!keys.length || keys.length > 32 || keys.some(key => !/^[a-z][A-Za-z0-9._-]{0,63}$/.test(key) || typeof value.commands[key] !== "function"))
                throw new Error("Extension commands must be named functions.");
              definition = value;
            },
            readText(path) {
              if (typeof path !== "string" || !Object.prototype.hasOwnProperty.call(resources, path))
                throw new Error("The resource is not part of this source package.");
              return resources[path];
            },
            settings: initialSettings,
            ai: Object.freeze({transform(request) {
              return new Promise((resolve, reject) => {
                const id = "cap-" + (++nextCapability);
                pending.set(id, {resolve, reject});
                try { __nativeCapability(id, JSON.stringify(request)); }
                catch (error) { pending.delete(id); reject(error); }
              });
            }})
          });
          Object.defineProperty(global, "MacHelper", {value:api, writable:false, configurable:false});
          global.__mhCapabilityResult = (id, ok, encoded) => {
            const item = pending.get(id); if (!item) return;
            pending.delete(id);
            const value = JSON.parse(encoded);
            ok ? item.resolve(value) : item.reject(new Error(String(value)));
          };
          global.__mhStart = id => done(id, async () => {
            if (!definition) throw new Error("The entry script did not call MacHelper.define.");
            if (definition.start !== undefined && typeof definition.start !== "function") throw new Error("start must be a function.");
            if (definition.stop !== undefined && typeof definition.stop !== "function") throw new Error("stop must be a function.");
            if (definition.start) await definition.start({settings:initialSettings});
            return {__loaded:true, commands:Object.keys(definition.commands)};
          });
          global.__mhInvoke = (id, command, encoded) => done(id, () => {
            if (!definition || typeof definition.commands[command] !== "function") throw new Error("Unknown extension command.");
            return definition.commands[command](JSON.parse(encoded));
          });
          global.__mhStop = id => done(id, async () => {
            if (definition && definition.stop) await definition.stop();
            for (const item of pending.values()) item.reject(new Error("Extension stopped."));
            pending.clear();
            return {stopped:true};
          });
        })(globalThis);
        """#
    }
}
