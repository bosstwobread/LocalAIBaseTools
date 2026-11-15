# LocalAIBaseTools

**MacHelper** is one macOS menu-bar app for your AI connection, extensions, and extension settings. **Translation** is an editable JavaScript source extension: enabling it installs all its source files on your Mac, and saving changes reloads its worker without restarting MacHelper. **MessageHelper — Upwork** remains a Chrome/Edge extension using the same AI connection.

## Structure

```text
LocalAIBaseTools/
├── MacHelper/
│   ├── App/                      Menu-bar app, AI/Extensions/General settings, login startup
│   ├── Assets/                   App icon artwork and native macOS icon resource
│   ├── Runtime/                  AI providers, preferences, framing, source validation/download/watchers
│   ├── Capabilities/             Shared selection detection, floating panels, and AI client
│   ├── ScriptWorker/             Independent JavaScriptCore process for each source generation
│   ├── Host/                     Browser/native-client stdin/stdout executable
│   ├── ExtensionSDK/             Advanced native Objective-C/AppKit compatibility interface
│   └── Tests/                    Runtime, source packages/workers, and native capabilities
├── Extensions/
│   ├── Translation/              Editable JS, manifest, schema, prompts, README, and license
│   └── MessageHelper-Upwork/     Independent Chrome/Edge extension
├── catalog/extensions.json       Source catalog metadata and complete SHA-256 file inventory
├── ExtensionMarket-website/      Searchable tool marketplace, source packages, Docker deployment
├── examples/ExternalGreeting/    Advanced independently built native SDK example
├── scripts/                      Build/install and integration checks
└── test/                         Browser and installer tests with synthetic fixtures
```

Source extensions use MacHelper's capability interface for selected text, nearby panels, shared AI, and schema-based settings. They can be authored outside this repository and installed without rebuilding MacHelper. JavaScript workers do not expose Node.js, shell, arbitrary file, or network APIs. Browser tools still need their browser component installed in Chrome or Edge.

## Requirements

- macOS 14 or later. Building from source requires Swift command-line tools and Python 3; the prebuilt developer release targets Apple Silicon.
- A signed-in Codex/ChatGPT installation with its bundled Codex app-server, Ollama with a model downloaded, or LM Studio with a model loaded and its local server running.
- Chrome/Edge for MessageHelper. Node.js/npm is needed for browser development tests.
- Accessibility approval for **MacHelper** to read selected text in other apps.

ChatGPT processes requests online using the existing sign-in. The helper runs locally; it is not an offline GPT model. Ollama and LM Studio use the service running on this Mac. Remote service addresses and redirects are rejected. There is no automatic fallback between providers.

## Build and install

```sh
python3 scripts/build-apps.py
python3 scripts/install-apps.py
```

This installs `~/Applications/LocalAIBaseTools/MacHelper.app`, including its AI host and JavaScript worker executable. The installer also registers an AI host copy under `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host` for Chrome/Edge native messaging.

Translation's catalog entry is included in the app. First enablement downloads its complete source to `~/Library/Application Support/LocalAIBaseTools/Extensions/com.localaibasetools.translation.macsource/`; the bundled source seed supports offline installation. Existing local source is preserved on re-enable and upgrades. On upgrade, the installer retires our earlier standalone Translation app to Trash without removing its preferences. Quit an older running MacHelper before replacing it, then reopen the installed app.

The build prefers an available Developer ID Application or Apple Development signing identity; otherwise it uses ad-hoc signing. Use `--signing-identity` to choose explicitly. A consistent Apple identity gives macOS a stable app requirement across updates. Public distribution still requires the appropriate signing/notarization release workflow.

## MacHelper settings

- **AI Connection**: provider, current model catalog, local address where relevant, Test Connection, and Save. Models are discovered dynamically; new advertised models can appear without an extension update while the provider protocol remains compatible. Retired selected models produce an error instead of silently choosing another. Ollama/LM Studio require a named model.
- **Extensions**: **Marketplace…** opens the tool website; source tools can also use **Install Source…**, **Add Catalog…**, **Edit Source**, and **Reload**. Marketplace installs show a native permissions review before downloading and enabling a complete source package. Existing local copies retain their edits, preferences, and enabled state. **Native tools…** opens the advanced native SDK interface.
- **General**: launch at login and the system Login Items shortcut. MacHelper registers itself through Apple's ServiceManagement API on its first explicit installed-app launch. It starts in the menu bar when you log in; closing Settings keeps enabled extensions running. A later user disablement is respected.

Shared AI preferences are stored in the MacHelper support folder's `settings.json`; source-tool enablement, permissions, and catalog addresses are in `source-extensions.json`. Source-tool settings live separately under `ExtensionSettings/<identifier>/settings.json`. The advanced native registry retains its own `extensions.json`. These files contain configuration, not selected text or translations.

### Translation

Open **MacHelper → Extensions → Translation**. Enable it, choose the target language and writing style, then use **Accessibility Settings…** to allow **MacHelper** in Privacy & Security. Permission granted to the old Translation app does not grant it to MacHelper.

Select text in another app. A small icon appears above/below the selection according to the available screen space. Click it for a nearby translation panel that fills with text as the model responds. The panel shows the actual model name; Copy becomes available after the completed answer is validated. Esc, deselecting, clicking elsewhere, and switching apps dismiss/invalidate the result. Changing selections prevents an older answer from replacing the current result.

With MacHelper 4.3 and Translation 4.2, selecting one word shows its meaning in the enclosing sentence, followed by that sentence's full translation. The sentence is read only when you click the icon, through bounded Accessibility ranges. If the app cannot supply it, the panel gives a standalone word meaning and notes that sentence context is unavailable. Longer selections keep the normal translation behavior.

Protected/password fields, images, and apps that do not expose selected text through Accessibility cannot be read automatically. Copy text yourself and use the explicit **Translate Clipboard…** action for those cases. Translation never simulates Copy or changes the clipboard automatically; the result's Copy button requires a click. **Try Demo…** tests the real AI connection with synthetic text without requiring Accessibility.

Use **Edit Source** to open Translation's installed working folder. Change `main.js`, `prompts/translate.txt`, or its settings schema and save. The watcher debounces saves, validates a candidate, and replaces only that extension's worker. Invalid edits show an error while the last working generation remains active. Settings stay separate, and re-enabling does not overwrite local edits. **Reload** performs the same validation on demand.

### Adding extensions developed elsewhere

Create a source folder containing `extension.json`, JavaScript, and the editable resources it needs. Choose **MacHelper → Extensions → Install Source…** to import it, or **Add Catalog…** to list tools from a JSON catalog. Enabling a catalog tool downloads every declared source file with hash/size validation and atomic installation. No additional Mac app is installed.

Browse the [Extension Market](https://local-ai-extension.nelson007.com/) or use **Marketplace…** in MacHelper. The [website project](ExtensionMarket-website/README.md) serves the catalog and complete source packages through a separate Docker container. See [Extension Development](docs/Extension-Development.md) and the detailed [source package/catalog contract](docs/Source-Extensions.md).

Advanced native `.machextension` bundles remain compatible through **Extensions → Native tools… → Install Extension…** and the [standalone SDK](MacHelper/ExtensionSDK/README.md). They run trusted native code inside MacHelper; replacing loaded native code requires restarting the app. [External Greeting](examples/ExternalGreeting/README.md) demonstrates building outside this repository using only the public SDK header. Native bundles do not support the JavaScript hot-reload workflow.

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

The helper does not save selected text or results in settings or project logs. Downloaded extension code and a last-working source cache contain tool files, not conversation history. AI providers may retain their own diagnostic or service records; an ephemeral ChatGPT thread is not a guarantee that no records exist anywhere. Extensions must follow the same data-handling rules.

## Verification

```sh
npm ci --ignore-scripts
npm test
swift test --package-path MacHelper
python3 -m unittest discover -s test -p '*_test.py'
python3 scripts/build-apps.py
python3 scripts/test-source-extensions.py
python3 scripts/test-source-extensions.py --live
python3 scripts/test-native.py
python3 scripts/test-native.py --catalog
python3 scripts/test-native.py --live
python3 scripts/test-extension-plugin.py --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The source-extension integration check uses temporary preferences/source folders, a loopback catalog, and real worker processes. It verifies metadata-only discovery, complete source download on enable, script/prompt/schema reload, invalid-edit recovery, persisted settings/local edits, cancellation, ordered partial streaming before completion, and worker cleanup. `--live` additionally sends one synthetic public sentence through the real configured AI provider and consumes its usage. It does not access Upwork, clipboard contents, user extension folders, or permissions.

The optional live native check also uses synthetic text only. Add `--model MODEL_ID_FROM_CATALOG` to test an explicit model. Browser tests use synthetic messages/feedback and zero-send/zero-submit sentinels. Swift tests cover the providers, framing, source validation/downloads/watchers, JavaScript workers/settings, selection lifecycle/geometry, preferences, startup decisions, and advanced native SDK compatibility. The native integration check builds outside the repository and runs against isolated extension state.

See [MacHelper Protocol](docs/MacHelper-Protocol.md) for browser and native AI requests.

## License

MIT. See [LICENSE](LICENSE).
