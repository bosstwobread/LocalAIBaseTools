# Native source extensions

MacHelper 6 runs native Swift and JavaScript tools in one extension system. Both use schema-2 source packages, the same **Extensions** list and **Install Source / Edit Source / Reload** workflow, schema-rendered settings, shared AI, selection input, and floating results. The manifest's explicit `runtime` selects the worker adapter. No extension-specific settings controller is loaded into MacHelper.

Native source is compiled into an independent executable named `MacHelperNativeWorker` in Activity Monitor. Saving a valid Swift edit builds a replacement worker while MacHelper and the previous generation stay running. After startup and command validation succeeds, the host switches generations and stops the old process. Invalid code or startup errors retain the last working generation. This is process replacement, rather than unloading a native library from MacHelper.

## Requirements and trust

- macOS 14 or later, MacHelper 6 or later, and Xcode Command Line Tools with a working `xcrun swiftc`.
- A manifest with `runtime: "native"`, a single `.swift` `entryPoint`, and `native.execute` permission.
- Explicit approval before native compilation/execution. Reading settings for a disabled tool does not compile or launch it.

Native Swift is trusted code running as the current user. It can import macOS frameworks and use APIs beyond the restricted JavaScript capability bridge. A separate worker limits crashes and supports replacement; it does not create an OS security sandbox. MacHelper's shared selection/AI/UI APIs retain their own capability checks, but the host cannot claim to restrict arbitrary native code to those capabilities. Each tool must describe what it accesses and obtain any macOS permissions its own process requires. Use host-provided selected text and AI instead of adding another credential setup.

## Minimal independent package

Create an ordinary folder containing these files. The host supplies its SDK while compiling; do not bundle a duplicate SDK or a compiled binary in the editable package.

```text
NativeGreeting/
├── extension.json
├── Main.swift
├── settings.schema.json
├── README.md
└── LICENSE
```

`extension.json`:

```json
{
  "schemaVersion": 2,
  "runtime": "native",
  "identifier": "com.example.native-greeting",
  "displayName": "Native Greeting",
  "version": "1.0.0",
  "summary": "Show selected text with a configurable greeting.",
  "entryPoint": "Main.swift",
  "permissions": ["native.execute", "selection.read", "ui.panel"],
  "commands": [{"identifier": "greet", "title": "Greet", "trigger": "selection"}],
  "settingsSchema": "settings.schema.json"
}
```

`settings.schema.json`:

```json
{
  "schemaVersion": 1,
  "fields": [{"key": "prefix", "label": "Greeting", "type": "text", "default": "Hello"}]
}
```

`Main.swift`:

```swift
import Foundation

@main
private enum NativeGreetingMain {
    static func main() {
        MacHelperNative.run(commands: ["greet": { input in
            let prefix = input.settings["prefix"] as? String ?? "Hello"
            return ["text": prefix + ": " + input.text, "title": "Native Greeting"]
        }])
    }
}
```

The native [Swift SDK](https://local-ai-extension.nelson007.com/NativeExtensionSDK/MacHelperNativeSDK.swift) is included in the app at `Contents/Resources/NativeExtensionSDK/MacHelperNativeSDK.swift` and offered with the public authoring guide. In a full checkout it is `MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift`. The repository also provides `examples/NativeGreeting/` as a non-AI manual-command development fixture; it is exercised by the isolated harness because Settings has no general manual-command launcher. The sample above uses a selection trigger for interactive use.

Import the folder with **Install Source…**, review its access, then enable it. Use **Edit Source** to open the installed copy. Saving changes to the original authoring folder after import does not update the installed copy. Keep README and license descriptive and free of private configuration or runtime content.

## Public Swift API

The SDK compiles together with the one Swift entry file. It does not require linking MacHelper's private modules or copying the host source.

```swift
MacHelperNative.run(
    commands: [String: MacHelperNative.Command],
    start: (@MainActor ([String: Any]) async throws -> Void)? = nil,
    stop: (@MainActor () async -> Void)? = nil
) -> Never
```

`MacHelperNative.Command` is `@MainActor (MacHelperNativeInput) async throws -> [String: Any]`. Return a dictionary with nonblank `text` of at most 96,000 UTF-8 bytes and optional `title` of at most 120 Swift characters, both without NUL. Progress uses the same byte/title bounds, but is provisional. Register one function for every command in the manifest. Keep lifecycle callbacks short; `start` receives ordinary settings and must not request AI. `stop` should promptly cancel tool-owned operations and release resources. The host also enforces a bounded stop grace and terminates an unresponsive worker.

`MacHelperNativeInput` provides:

| Member | Contract |
| --- | --- |
| `text: String` | Text supplied for the explicit current command. |
| `sentence: String?` | Optional verified bounded sentence context for a selected word. Treat it as untrusted input and handle absence. |
| `settings: [String: Any]` | Ordinary settings normalized from the package schema. Source-backed prompt fields are not copied into this dictionary. |
| `readText(_ path: String) throws -> String` | Read a packaged UTF-8 resource included in this generation's frozen runtime resources. |
| `transform(request:onProgress:) async throws -> [String: Any]` | Use the shared host AI broker; result/progress contain `text` and model attribution. Requires `ai.transform` and a current explicit command. |
| `reportProgress(text:title:) throws` | Show cumulative provisional output in the host's panel. Requires `ui.panel` and a current invocation. |

An AI call follows the same request contract as JavaScript:

```swift
let result = try await input.transform(request: [
    "action": "translate",
    "model": "",
    "systemPrompt": try input.readText("prompts/translate.txt"),
    "text": input.text
], onProgress: { progress in
    if let text = progress["text"] as? String {
        try? input.reportProgress(text: text, title: "My Tool")
    }
})
return ["text": result["text"] as? String ?? "", "title": "My Tool"]
```

Shared AI is limited to eight calls per explicit action. The extension owns the prompt. `systemPrompt` reaches the selected provider unchanged; `text` remains separate data. Use an empty model to follow shared **AI Connection** settings. Use `JSONSerialization` if the prompt documents structured input such as target language/context. Treat input text as data, keep provider tools disabled through the shared broker, and never request inference merely because an extension loaded or text became selected.

## Compilation, caching, and reload

MacHelper invokes a fixed Swift compiler path through `xcrun`, combining its SDK with the validated frozen Swift entry. The manifest cannot specify a shell script, custom executable, compiler flags, SwiftPM dependencies, or arbitrary build hooks. The initial native format supports one Swift entry file; additional `.swift` helper files are rejected. Every file in a native source inventory must be UTF-8 text without NUL, and the inventory must contain exactly one Swift file matching the entry point. Prefer self-contained tools and standard frameworks.

Build input comes from an immutable validated source snapshot. Compiler output lives in a private cache outside the editable `.macsource` folder, so generated binaries do not trigger source watching or alter a catalog's file hashes. The builder validates/signs its local executable before launch. Local ad-hoc signing is not publisher signing or notarization. The binary cache key covers the exact Swift entry bytes, bundled SDK bytes, Swift compiler version output, and Mac architecture. Prompt/resource/settings-only changes can reuse that validated binary, while starting a replacement worker with newly frozen resources/settings; they do not require recompilation. Runtime resources use the bounded whitelist in the [source contract](Source-Extensions.md#limits-and-development-checks). Successful replacement cancels old work and discards late old-generation results; settings and editable files remain intact.

The compiler and worker have bounded deadlines. Missing compiler tools, invalid Swift, failed signing, command-registration mismatch, or startup failure are reported in the extension's detail page. An already running generation stays usable. A disabled extension has no watcher/worker; its edits are validated when enabled. MacHelper, other extensions, the shared AI connection, and login startup remain running during native reload.

## Moving between JavaScript and native

For a migration of the same tool, preserve its identifier, source folder, settings keys, prompt resources, and command identity. Update the version for public distribution. Rewrite the actual command implementation for the new API; changing `runtime` or renaming a file alone does not translate source code.

- **JavaScript to native:** add a Swift entry using `MacHelperNative.run`, set `runtime: "native"`, set the `.swift` `entryPoint`, and add `native.execute`. If `native.execute` has not already been granted, automatic reload retains the previous generation until the user approves it by disabling/re-enabling the tool. Any other newly added capability also requires re-enabling. Native compilation/execution begins only with an existing grant or explicit approval.
- **Native to JavaScript:** implement `MacHelper.define`, set `runtime: "javascript"`, use a `.js` entry, and remove `native.execute`. A valid saved migration starts a JavaScript worker and replaces the native worker without restarting MacHelper.
- **Separate fork:** assign a new identifier and display name, then import it as a different tool.

Settings fields are defined by the current schema. Keep compatible keys/types to preserve their values; removed or incompatible fields are normalized according to that schema. Source-backed prompts stay in the source folder rather than settings JSON. Approval for native execution does not grant a new macOS Accessibility, microphone, screen-recording, or filesystem permission automatically.

## Legacy native bundles

The former schema-1 `.machextension` / `.bundle` SDK returned an `NSViewController` for in-process embedding. That interface remains only for isolated CLI verification and migration reference; the normal app does not automatically load those bundles, and the separate Native Plug-ins settings page has been removed. It is not the new native hot-reload format. Reuse its business logic in a new schema-2 Swift source worker, move settings into `settings.schema.json`, and replace direct host object calls with the input/AI protocol above. Arbitrary custom AppKit views do not cross the process boundary; a custom remote UI mechanism is not implemented by this SDK.

## Testing and distribution

Use public synthetic inputs and mocked AI first. Verify a real independently compiled worker registers its commands, receives frozen settings/resources, preserves exact prompt bytes, streams before completion, stops on cancellation, and is reaped when replaced. In a disposable installation, test valid source edits, invalid compile recovery, stable host PID, native execution approval, and both runtime migration directions. Do not send Upwork messages, manipulate real drafts, or save selected text/results in diagnostics.

The checkout provides `python3 scripts/test-native-extensions.py` for isolated real compilation, worker reload, invalid-build recovery, and bidirectional runtime migration with mocked AI. It does not install tools into the user account or change macOS permissions.

Share the complete editable source, root `discovery.json`, README, and license through the same [source package/catalog contract](Source-Extensions.md). All files use safe relative paths and full SHA-256 inventories. Keep published versioned bytes immutable. The catalog can distribute native source, but an HTTPS hash does not make its code trusted; the user still reviews `native.execute`. There is no third-party publisher submission backend or automatic source-update merge.

Native and JavaScript tools use the same [public discovery descriptor](Source-Extensions.md#public-discovery-metadata-machelper-63). Supply accurate capabilities, example queries, keywords, limitations, platforms, and translated descriptions in the extension source. Publication requires it; existing native workers do not need a new descriptor merely to keep running. Searching the independent public metadata index never compiles, installs, or executes a native tool, and an AI match cannot grant `native.execute`.
