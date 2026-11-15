# LocalAIBaseTools

**MacHelper** is one macOS menu-bar app for your AI connection, extensions, and extension settings. **Translation** runs inside MacHelper; it no longer needs a separate app. **MessageHelper — Upwork** remains a Chrome/Edge extension using the same AI connection.

## Structure

```text
LocalAIBaseTools/
├── MacHelper/
│   ├── App/                      Menu-bar app, AI/Extensions/General settings, login startup
│   ├── Runtime/                  AI providers, preferences, framing, extension discovery/lifecycle
│   ├── Host/                     Browser/native-client stdin/stdout executable
│   ├── ExtensionSDK/             Standalone public Objective-C/AppKit extension contract
│   └── Tests/MacHelperTests/
├── Extensions/
│   ├── Translation/              Independently built native extension, bundled in MacHelper
│   └── MessageHelper-Upwork/     Independent Chrome/Edge extension
├── examples/ExternalGreeting/    Example that can be authored and built outside this repository
├── scripts/                      Build/install and integration checks
└── test/                         Browser and installer tests with synthetic fixtures
```

Extensions do not import the helper's AI implementation. Native extensions implement the public SDK and communicate with the AI helper through framed messages. Their settings view controllers are embedded inside MacHelper. Browser tools still need their browser component installed in Chrome or Edge.

## Requirements

- macOS 14 or later; Swift command-line tools and Python 3 to build/install.
- A signed-in Codex/ChatGPT installation with its bundled Codex app-server, Ollama with a model downloaded, or LM Studio with a model loaded and its local server running.
- Chrome/Edge for MessageHelper. Node.js/npm is needed for browser development tests.
- Accessibility approval for **MacHelper** to read selected text in other apps.

ChatGPT processes requests online using the existing sign-in. The helper runs locally; it is not an offline GPT model. Ollama and LM Studio use the service running on this Mac. Remote service addresses and redirects are rejected. There is no automatic fallback between providers.

## Build and install

```sh
python3 scripts/build-apps.py
python3 scripts/install-apps.py
```

This installs only `~/Applications/LocalAIBaseTools/MacHelper.app`. Translation is a native bundle inside its `Contents/PlugIns` directory. The app includes the AI host executable; the installer also registers a copy under `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host` for Chrome/Edge native messaging.

On upgrade, the installer retires our earlier standalone Translation app to Trash without removing its preferences. The hosted extension migrates the previous target-language setting. Quit any running older MacHelper before replacing it, then reopen the installed app.

The build prefers an available Developer ID Application or Apple Development signing identity; otherwise it uses ad-hoc signing. Use `--signing-identity` to choose explicitly. A consistent Apple identity gives macOS a stable app requirement across updates. Public distribution still requires the appropriate signing/notarization release workflow.

## MacHelper settings

- **AI Connection**: provider, current model catalog, local address where relevant, Test Connection, and Save. Models are discovered dynamically; new advertised models can appear without an extension update while the provider protocol remains compatible. Retired selected models produce an error instead of silently choosing another. Ollama/LM Studio require a named model.
- **Extensions**: install, select, enable/disable, and configure native tools. Translation is bundled and enabled initially. New external extensions are discovered without executing their code, and remain disabled until explicitly enabled.
- **General**: launch at login and the system Login Items shortcut. MacHelper registers itself through Apple's ServiceManagement API on its first explicit installed-app launch. It starts in the menu bar when you log in; closing Settings keeps enabled extensions running. A later user disablement is respected.

Shared AI preferences are stored in the MacHelper support folder's `settings.json`; extension enablement in `extensions.json`. Each extension gets a separate preferences directory under `ExtensionSettings`. These files contain configuration, not source text or translations.

### Translation

Open **MacHelper → Extensions → Translation**. Choose the target language, then use **Open Accessibility Settings…** to allow **MacHelper** in Privacy & Security. Permission granted to the old Translation app does not grant it to MacHelper.

Select text in another app. A small icon appears above/below the selection according to the available screen space. Click it for a nearby translation panel with the actual model name, Copy, and Close. Esc, deselecting, clicking elsewhere, and switching apps dismiss/invalidate the result. Changing selections prevents an older answer from replacing the current result.

Protected/password fields, images, and apps that do not expose selected text through Accessibility cannot be read automatically. Copy text yourself and use the explicit **Translate Clipboard…** action for those cases. Translation never simulates Copy or changes the clipboard automatically; the result's Copy button requires a click. **Try Demo…** tests the real AI connection with synthetic text without requiring Accessibility.

### Adding extensions developed elsewhere

Build a `.machextension` bundle implementing the public SDK, then choose **MacHelper → Extensions → Install Extension…**. Its settings appear in the same window after enabling it. Installing a new extension does not require rebuilding MacHelper or installing another Mac application.

External bundles live under `~/Library/Application Support/LocalAIBaseTools/Extensions/`. A changed external executable requires re-enabling, and replacing already-loaded native code requires restarting MacHelper. Native extensions are trusted code inside MacHelper and share its access; this first interface does not sandbox arbitrary third-party code or automatically install downloads.

See [Extension Development](docs/Extension-Development.md), the [standalone SDK](MacHelper/ExtensionSDK/README.md), and [External Greeting](examples/ExternalGreeting/README.md). The example can be copied to another folder and built using only the public SDK header; it does not depend on this repository's private Swift modules.

### MessageHelper — Upwork

In Edge, use `edge://extensions`; in Chrome, use `chrome://extensions`. Enable Developer mode, choose Load unpacked, and select `Extensions/MessageHelper-Upwork`. Reload an existing installation after source changes, and refresh affected tabs after preserving unsaved drafts.

Supported routes include Upwork messages, proposal conversations, and contract Leave feedback forms. Message Translate shows output below the original. Polish previews English before Apply; Cancel preserves the draft, and Undo restores it while unchanged. Feedback Translate draft is read-only. Ratings and submission controls are untouched. Only the user may send messages or submit feedback.

The popup's AI model list uses the currently selected MacHelper provider. MacHelper default follows shared preferences; a named choice overrides the shared model only for this browser extension. If a provider change makes that override unavailable, select an available model or MacHelper default. Use its safe test page for synthetic Apply/Undo checks.

Native host: `com.localaibasetools.mac_helper`; compatibility alias: `com.messagehelper.gpt`. Both launch the same new host. The stable Upwork extension ID is `fmhfobfddchbeibojepeocgfemkpcklo`. Additional browser clients need explicit registration:

```sh
python3 scripts/install-helper.py --extension-id ADDITIONAL_32_CHARACTER_EXTENSION_ID
```

Repeated flags add multiple IDs; existing registrations are preserved, with no wildcard origins.

## Data

Selection alone does not send text for inference. AI requests happen after a translation/polishing action. Source text is treated as data. The ChatGPT client uses isolated answer-only requests with tools disabled; local HTTP providers receive no tool definitions. These tools never send Upwork messages automatically.

The helper does not save source text or results in settings or project logs. AI providers may retain their own diagnostic or service records; an ephemeral ChatGPT thread is not a guarantee that no records exist anywhere. Native extensions must follow the same data-handling rules.

## Verification

```sh
npm ci --ignore-scripts
npm test
swift test --package-path MacHelper
swift test --package-path Extensions/Translation
python3 -m unittest discover -s test -p '*_test.py'
python3 scripts/build-apps.py
python3 scripts/test-native.py
python3 scripts/test-native.py --catalog
python3 scripts/test-native.py --live
python3 scripts/test-extension-plugin.py --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The optional live native check uses synthetic text only and consumes the configured provider's usage. Add `--model MODEL_ID_FROM_CATALOG` to test an explicit model. Browser tests use synthetic messages/feedback and zero-send/zero-submit sentinels. Swift tests cover the providers, framing, selection lifecycle/geometry, preferences, startup decisions, plugin validation, and real independently compiled native bundles. The external integration check builds outside the repository and runs against isolated extension state; it does not install a test tool into the user's account.

See [MacHelper Protocol](docs/MacHelper-Protocol.md) for browser and native AI requests.

### Verified on this Mac — November 15, 2026

- 83 MacHelper Swift tests, 28 Translation Swift tests, 37 browser tests, and 12 installer tests pass (160 total).
- The signed MacHelper 3.0.0 app is installed with Translation 2.1.0 inside it. The standalone Translation app was stopped and moved recoverably to Trash; its language preference was migrated.
- The Extensions, AI Connection, and General settings render correctly. Closing the settings window keeps MacHelper running, and reopening returns to the central settings interface.
- The system reports launch at login enabled. Startup-policy checks pass; the Mac was not rebooted during testing.
- MacHelper's Accessibility access is enabled. The user manually confirmed floating selection translation and Esc dismissal in Edge through the unified app.
- The browser companion reconnects to helper 3.0.0 and dynamically discovers eight ChatGPT models. Shared preferences remain ChatGPT with Automatic model selection.
- Live synthetic translation and polishing pass with an explicit model, preserving the fixture's name, date, amount, and URL. No Upwork messages or feedback were sent.
- An external example was copied and built outside the repository using only the public SDK header. The real MacHelper registry discovered it, started it, and loaded its settings with isolated test preferences, without rebuilding MacHelper or installing another app.

## License

MIT. See [LICENSE](LICENSE).
