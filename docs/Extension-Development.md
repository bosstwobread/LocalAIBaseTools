# Developing MacHelper extensions

MacHelper is the installed menu-bar app and settings host. An extension is a native `.machextension` bundle loaded into that app. It does not need its own `.app`, menu-bar item, AI-provider settings, or login item. An extension can be developed in a separate repository and added to an installed MacHelper without rebuilding the host.

Version one supports native Swift and Objective-C extensions for macOS 14 or later. Browser extensions remain separate browser packages; a browser extension can continue using the [framed MacHelper service](MacHelper-Protocol.md).

## Public interface

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

Your principal class derives from `NSObject` and implements `MacHelperExtension`. All host calls occur on the main thread. Keep its factory and `start` quick; perform long-running AI or file operations off the UI thread. `start` receives the host context and begins the extension's active behavior. `stop` must cancel pending work, remove monitors/timers, close panels, and release the context as appropriate. It may later be started again. `makeSettingsViewController` returns a controller that MacHelper embeds under **Extensions**; the extension does not open a separate settings window.

Use `settingsDirectory` for this extension's own small preferences. Do not save selected/source text or AI output as preference history. `openAISettings` opens the shared provider/model settings, and `hideSettings` lets a tool dismiss the host's window before showing a transient interaction. The host's `helperExecutablePath` identifies the already-installed AI service. Send requests through its framed stdin/stdout protocol; never hard-code a developer's file path or require a second AI-provider setup. The first version provides no host capability broker or automatic tool permission prompts.

For Swift, import the public header as a Clang module or bridging header, declare an Objective-C runtime principal name, and implement the imported method names `makeExtension()`, `start(context:)`, `stop()`, and `makeSettingsViewController()`.

## Bundle layout

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

## Installation and lifecycle

Use **MacHelper → Extensions → Install Extension…** to import a bundle, or place it under `~/Library/Application Support/LocalAIBaseTools/Extensions/` and refresh the extension list. The host discovers manifests without loading native code. An external extension is disabled until the user explicitly enables it; its settings become available after enablement. Bundled Translation uses the same interface.

Changing an external bundle's executable, metadata, or manifest invalidates its previous enablement approval. A loaded native bundle cannot be safely unloaded and replaced in the same process, so quit MacHelper before upgrading an extension it has already loaded, then import the replacement, restart, and enable it again.

Native extensions execute inside MacHelper with its process privileges and permissions. This is a trusted-code extension interface, not a sandbox: extensions can do more than the SDK declares. Only enable code you trust. MacHelper does not download or execute third-party bundles automatically. Distribution signing, notarization, and a future sandbox/capability design are separate release work.

## Independent example and test

[`examples/ExternalGreeting`](../examples/ExternalGreeting) contains a minimal Objective-C extension with no AI, network, Accessibility, or other permission dependencies. Its build script accepts only the public SDK header, its own sources, and an output path.

```sh
python3 examples/ExternalGreeting/build.py \
  --sdk-header MacHelper/ExtensionSDK/Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h \
  --output /tmp/ExternalGreeting.machextension

python3 scripts/test-extension-plugin.py \
  --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The test copies the authoring folder and SDK header to a temporary directory outside the repository, compiles it there, and checks native principal loading, factory/start/stop, an offscreen settings controller, a private persisted counter, and a stubbed host callback. With `--host`, it also asks the built MacHelper app's verification mode to discover and explicitly enable the example with isolated extension state. It does not add an extension to your actual account, change permissions, contact an AI service, or rebuild MacHelper.
