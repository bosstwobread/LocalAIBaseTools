# Translation

A native extension hosted inside the **MacHelper** menu bar app. Translation stays in its own Swift package and uses the public extension SDK plus framed helper messages; it does not import MacHelper’s AI implementation. There is no separate Translation application or menu bar icon.

## Use

1. Open `~/Applications/LocalAIBaseTools/MacHelper.app` and enable Translation in its extensions settings.
2. Open Translation’s settings panel. Allow **MacHelper** in **System Settings → Privacy & Security → Accessibility**. You grant permission yourself.
3. Select text in another app. Click the floating translation icon above or below the selection.
4. Read the nearby result. **Copy** copies only when clicked. Escape, clicking elsewhere, deselecting text, or switching apps dismisses it.

The target language defaults to Simplified Chinese. Choose another language in Translation’s settings panel. **AI Settings…** opens the shared MacHelper provider/model settings. **Try Demo…** shows a synthetic selection without needing Accessibility permission. **Translate Clipboard…** translates only text you have already copied yourself.

The extension reads the focused app’s selected text and selection bounds using macOS Accessibility. Protected fields, images, and apps that do not expose text selection cannot be read this way. When selection bounds are unavailable, the icon uses the last mouse selection position. For unsupported apps, use the explicit clipboard action. Translation never presses Copy for you.

Some Chromium/Electron apps expose web content only after their accessibility support is enabled. Translation makes a read-only application role query, which [Chromium uses to activate native accessibility](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm). This cannot guarantee all apps expose selected web text. Translation does not set the `AXManualAccessibility` attribute described in [Electron’s accessibility documentation](https://www.electronjs.org/docs/latest/tutorial/accessibility) or change another app’s accessibility configuration. Use the app’s own accessibility settings or the explicit clipboard fallback if needed.

No AI call occurs on selection alone. Translation never pastes, sends messages, changes another app’s text, or saves selected text or translation history. The selected AI provider may have its own data retention behavior. Accessibility permission is required for automatic detection and system-wide Escape monitoring; **Try Demo…** works without granting it.

## Build and test independently

Requires macOS 14 or newer and a Swift 6 toolchain. Run from the repository root:

```sh
swift build --package-path Extensions/Translation --configuration release
swift test --package-path Extensions/Translation
```

This builds `libTranslation.dylib`. The repository’s build script packages it as a `.machextension` bundle containing its manifest and `NSPrincipalClass = TranslationExtension`. MacHelper loads it through the standalone SDK in `MacHelper/ExtensionSDK`. App/window/menu ownership stays with MacHelper.

## Files

- `TranslationExtension.swift`: public SDK principal and host context wiring.
- `TranslationController.swift`: reusable start/stop controller, settings view, explicit translation actions, and result lifecycle.
- `TranslationPreferences.swift`: target-language JSON settings and migration from the earlier standalone app.
- `SelectionMonitor.swift`: read-only Accessibility selection queries and debounced event monitoring. No keyboard text is collected.
- `FloatingPanels.swift`: nonactivating icon and result panels.
- `SelectionState.swift`: stale-result protection and multi-display panel placement.
- `HelperClient.swift`: independent native messaging client and translation payload validation.
- `extension.json`: source manifest copied into the packaged extension.
- `Tests/TranslationTests`: geometry, lifecycle, preferences migration, framed subprocess round trips, malformed replies, timeout, and cancellation checks.

## Host contract

The Objective-C principal implements `MacHelperExtension` from the public `MacHelperExtensionSDK` module:

```swift
static func makeExtension() -> any MacHelperExtension
func start(context: any MacHelperExtensionContext)
func stop()
func makeSettingsViewController() -> NSViewController
```

MacHelper invokes the extension on the main thread. The context supplies the native helper executable path, an extension-specific settings directory, host version, and callbacks to open AI settings or hide the host settings window. Translation writes only `schemaVersion` and `targetLanguage` to `settings.json` in that directory. On the first hosted launch, it migrates a valid language preference from the earlier standalone Translation app.

The reusable `TranslationController` also exposes `configure(helperExecutableURL:settingsDirectory:)`, `start()`, `stop()`, `makeSettingsViewController()`, `showDemo()`, and `translateClipboard()`. Its callbacks let a host manage shared settings and windows.

## MacHelper protocol

Translation starts the helper executable supplied by MacHelper on demand. Each request is four bytes of little-endian payload length followed by UTF-8 JSON:

```json
{"id":"unique-request-id","action":"translate","text":"Hello","targetLanguage":"zh-CN","model":""}
```

The empty `model` uses MacHelper’s shared default. Replies use the same framing and must match the request ID. The client bounds frame sizes, applies a 180-second deadline, and cancels its host process when the selection changes or the result is dismissed. It closes stdin first so the host can stop its AI subprocess before bounded termination cleanup. Selected text travels through stdin, never command-line arguments or logs.
