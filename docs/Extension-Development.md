# Developing MacHelper extensions

MacHelper is the installed menu-bar app and settings host. Its default extension format is an editable JavaScript source package. An extension can be developed in a separate repository, downloaded or imported into the installed MacHelper, and changed locally without rebuilding the host or installing another app.

The source package uses manifest schema version two and runs in its own `MacHelperScriptWorker` process. MacHelper owns shared AI settings, selection detection, floating panels, login startup, and extension settings. Translation is the first source tool; its six files are `extension.json`, `main.js`, `settings.schema.json`, `prompts/translate.txt`, `README.md`, and `LICENSE`.

Browser extensions remain separate browser packages and can continue using the [framed MacHelper service](MacHelper-Protocol.md). The version-one native Swift/Objective-C SDK is retained as an advanced compatibility interface, documented below.

## Source extension workflow

Create a folder containing the complete editable source, with a manifest like:

```json
{
  "schemaVersion": 2,
  "runtime": "javascript",
  "identifier": "com.example.my-translation",
  "displayName": "My Translation",
  "version": "1.0.0",
  "summary": "Translate selected text through MacHelper.",
  "entryPoint": "main.js",
  "permissions": ["selection.read", "clipboard.read", "ai.transform", "ui.panel"],
  "commands": [{"identifier": "translate", "title": "Translate", "trigger": "selection"}],
  "settingsSchema": "settings.schema.json"
}
```

The entry point defines commands through the host interface:

```js
MacHelper.define({
  commands: {
    async translate(input) {
      const result = await MacHelper.ai.transform({
        action: "translate",
        text: input.text,
        targetLanguage: input.settings.targetLanguage || "zh-CN",
        model: "",
        guidance: MacHelper.readText("prompts/translate.txt")
      });
      return { text: result.text, title: "My Translation" };
    }
  }
});
```

The empty model follows MacHelper's shared AI connection. Settings come from a small JSON schema with `select`, `text`, and `boolean` fields. MacHelper renders those controls under **Extensions**. `MacHelper.readText` reads a frozen resource from that worker's source generation; there is no direct filesystem, network, shell, Node.js, or npm dependency API. AI transformations require an explicit user command; loading a tool or selecting text does not trigger inference.

Use **MacHelper → Extensions → Install Source…** to copy an authoring folder into the user's writable source directory. Imported tools remain disabled until enabled. A `.macsource` suffix is convenient for installed packages; an ordinary authoring folder containing `extension.json` is also accepted. The package is independent of MacHelper's Swift modules and needs no Swift compilation.

Once enabled, use **Edit Source** to open the working folder. Saving scripts, prompts, manifest metadata, or the settings schema triggers a debounced reload. **Reload** requests the same check manually. A candidate must pass package, settings, JavaScript, and declared-command validation before replacing the running worker. Invalid edits retain the last working generation. Other tools and MacHelper stay running, while the changed tool's ordinary JavaScript variables reset. Stopping/replacing a worker cancels its pending operations and discards stale results.

Settings are stored outside the source package at the MacHelper support folder's `ExtensionSettings/<identifier>/settings.json`. Disabling retains settings and source, and stops the worker and watcher. Re-enable preserves user edits rather than downloading over the installed folder. An edit adding capabilities beyond those previously enabled requires disabling and re-enabling to approve that change.

See [Editable source extensions](Source-Extensions.md) for the complete manifest, JavaScript, schema, bounds, path validation, permission, and download contracts.

## Catalogs and complete source download

The future marketplace can serve a JSON catalog over HTTPS. Each entry contains display metadata plus every source file's relative path, download URL, SHA-256, and optional size. List the manifest, scripts, prompts, schema, README, and license; distributing only an executable is not the source format.

**Add Catalog…** reads metadata without downloading or running packages. First enablement downloads the complete declared inventory into a staging directory, validates every file and the manifest identity/version, and atomically installs the source. Failed downloads leave no partial installed tool. Existing local source is always preserved; automatic upstream replacement is not part of enablement.

The first-party catalog is `catalog/extensions.json`. Regenerate it after changing Translation's source:

```sh
python3 scripts/build-source-catalog.py --ref PUBLISHED_GIT_COMMIT
```

For a separate marketplace or CDN, pass `--base-url https://example.com/packages/translation/1.0.0/`. Use immutable source URLs for a published catalog so its hashes continue matching its files. The app bundles a first-party source seed for offline installation; external marketplace entries do not receive that implicit fallback.

## Source verification

```sh
swift test --package-path MacHelper
python3 scripts/test-source-extensions.py
python3 scripts/test-source-extensions.py --live
```

The integration check serves the entire Translation package through a loopback catalog and uses temporary source/preferences directories with real independent JavaScript workers. It checks discovery without download, full source installation on enable, reloads after script/prompt/schema edits, invalid-source recovery, persisted settings and local edits, cancellation, and process cleanup. `--live` additionally transforms one synthetic public sentence through the configured AI service. It does not install a test tool into the user's account or access Upwork, the clipboard, or app permissions.

## Advanced: native SDK compatibility

Native `.machextension` bundles are supported for tools requiring custom Swift/Objective-C and AppKit behavior on macOS 14 or later. They run inside MacHelper's process and use **Extensions → Native tools…**. They are separate from the default JavaScript/source marketplace format and do not support source-worker hot reload.

### Public interface

The SDK is the declaration-only header at `MacHelper/ExtensionSDK/Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h`. External authors can copy this header alone. No private MacHelper implementation or Swift module is required. The boundary uses Objective-C runtime protocols and Foundation/AppKit types so separately built extensions do not depend on MacHelper's internal Swift ABI.

```objc
@protocol MacHelperExtensionContext <NSObject>
@property(nonatomic, readonly, copy) NSString *helperExecutablePath;
@property(nonatomic, readonly, copy) NSString *settingsDirectory;
@property(nonatomic, readonly, copy) NSString *hostVersion;
- (void)openAISettings;
- (void)hideSettings;
@end

@protocol MacHelperExtension <NSObject>
+ (id<MacHelperExtension>)makeExtension;
- (void)startWithContext:(id<MacHelperExtensionContext>)context;
- (void)stop;
- (NSViewController *)makeSettingsViewController;
@end
```

Your principal class derives from `NSObject` and implements `MacHelperExtension`. All host calls occur on the main thread. Keep its factory and `start` quick; perform long-running AI or file operations off the UI thread. `start` receives the host context and begins the extension's active behavior. `stop` must cancel pending work, remove monitors/timers, close panels, and release the context as appropriate. It may later be started again. `makeSettingsViewController` returns a controller that MacHelper embeds under **Extensions → Native tools…**; the extension does not open a separate settings window.

Use `settingsDirectory` for this extension's own small preferences. Do not save selected/source text or AI output as preference history. `openAISettings` opens the shared provider/model settings, and `hideSettings` lets a tool dismiss the host's window before showing a transient interaction. The host's `helperExecutablePath` identifies the already-installed AI service. Send requests through its framed stdin/stdout protocol; never hard-code a developer's file path or require a second AI-provider setup. This legacy native interface does not use the source worker's capability broker or permission declarations.

For Swift, import the public header as a Clang module or bridging header, declare an Objective-C runtime principal name, and implement the imported method names `makeExtension()`, `start(context:)`, `stop()`, and `makeSettingsViewController()`.

### Bundle layout

```text
ExternalGreeting.machextension/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── ExternalGreetingExtension
    └── Resources/
        └── extension.json
```

The executable is a native loadable Mach-O bundle, built with `clang -bundle` or the equivalent Swift linker bundle output. `Info.plist` contains:

- `CFBundleIdentifier`: the same reverse-domain identifier as the manifest.
- `CFBundleExecutable`: the executable filename under `Contents/MacOS`.
- `NSPrincipalClass`: the Objective-C runtime class implementing the SDK protocol.
- `CFBundlePackageType`: `BNDL`.

The manifest at `Contents/Resources/extension.json` uses API version one:

```json
{
  "schemaVersion": 1,
  "identifier": "com.localaibasetools.example.external-greeting",
  "displayName": "External Greeting",
  "version": "1.0.0",
  "summary": "A small independently built extension with settings inside MacHelper.",
  "entryPoint": "Contents/MacOS/ExternalGreetingExtension"
}
```

Use a unique lowercase reverse-domain identifier. `version` uses `major.minor.patch` with an optional prerelease suffix. The entry point must be a regular file directly inside `Contents/MacOS`; it cannot be an absolute path, a traversal, or a symlink escaping the bundle. Keep the bundle identifier, manifest, executable filename, and principal class consistent.

### Installation and lifecycle

Use **MacHelper → Extensions → Native tools… → Install Extension…** to import a bundle, or place it under `~/Library/Application Support/LocalAIBaseTools/Extensions/` and refresh the native list. The host discovers manifests without loading native code. An external native extension is disabled until the user explicitly enables it; its settings become available after enablement. Translation now uses the independent JavaScript/source interface.

Changing an external bundle's executable, metadata, or manifest invalidates its previous enablement approval. A loaded native bundle cannot be safely unloaded and replaced in the same process, so quit MacHelper before upgrading an extension it has already loaded, then import the replacement, restart, and enable it again.

Native extensions execute inside MacHelper with its process privileges and permissions. This is a trusted-code extension interface, not a sandbox: extensions can do more than the SDK declares. Only enable native code you trust. The source catalog downloader does not install native bundles. Native distribution signing and notarization remain separate release work.

### Independent native example and test

[`examples/ExternalGreeting`](../examples/ExternalGreeting) contains a minimal Objective-C extension with no AI, network, Accessibility, or other permission dependencies. Its build script accepts only the public SDK header, its own sources, and an output path.

```sh
python3 examples/ExternalGreeting/build.py \
  --sdk-header MacHelper/ExtensionSDK/Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h \
  --output /tmp/ExternalGreeting.machextension

python3 scripts/test-extension-plugin.py \
  --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The test copies the authoring folder and SDK header to a temporary directory outside the repository, compiles it there, and checks native principal loading, factory/start/stop, an offscreen settings controller, a private persisted counter, and a stubbed host callback. With `--host`, it also asks the built MacHelper app's verification mode to discover and explicitly enable the example with isolated extension state. It does not add an extension to your actual account, change permissions, contact an AI service, or rebuild MacHelper.
