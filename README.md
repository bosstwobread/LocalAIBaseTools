# LocalAIBaseTools

**MacHelper** is one macOS app for your AI connection, extensions, and extension settings. Click its Dock icon to open Settings, or use its menu-bar shortcut. **Translation** is an editable JavaScript source extension: enabling it installs all its source files on your Mac, and saving changes while enabled reloads its worker without restarting MacHelper. **MessageHelper — Upwork** remains a Chrome/Edge extension using the same AI connection. The **Extension Market** searches public extension descriptions with keywords or uses MacHelper’s built-in local service for explicit AI matching. Website search needs no browser extension. Current release: MacHelper **6.5.0** (build **650**), Translation **4.5.2**, MessageHelper — Upwork **1.4.0**.

Before making changes, read the short [development checklist](DEVELOPMENT.md). Check it again before finishing so related functionality, documentation, and website content stay consistent.

## Structure

```text
LocalAIBaseTools/
├── MacHelper/
│   ├── App/                      Dock/menu-bar app, AI/Extensions/General settings, login startup
│   ├── Assets/                   App icon artwork and native macOS icon resource
│   ├── Runtime/                  AI providers, local website service, public discovery index/search, source validation/download/watchers
│   ├── Capabilities/             Shared selection detection, floating panels, and AI client
│   ├── ScriptWorker/             Independent JavaScriptCore process for each source generation
│   ├── Host/                     Browser/native-client stdin/stdout executable
│   ├── NativeExtensionSDK/       Standalone Swift source-worker SDK
│   ├── ExtensionSDK/             Legacy Objective-C/AppKit migration fixture
│   └── Tests/                    Runtime, source packages/workers, and native capabilities
├── Extensions/
│   ├── Translation/              Editable JS, manifest, schema, prompts, README, and license
│   └── MessageHelper-Upwork/     Independent Chrome/Edge extension
├── catalog/extensions.json       Source catalog metadata and complete SHA-256 file inventory
├── ExtensionMarket-website/      Searchable tool marketplace, source packages, Docker deployment
├── examples/NativeGreeting/      Independent native Swift source-worker example
├── examples/ExternalGreeting/    Legacy in-process SDK migration fixture
├── scripts/                      Build/install and integration checks
└── test/                         Browser and installer tests with synthetic fixtures
```

JavaScript and native Swift source extensions share one Extensions interface. Their manifest runtime chooses execution and reload automatically. Source extensions use MacHelper's capability interface for selected text, nearby panels, shared AI, and schema-based settings. They can be authored outside this repository and installed without rebuilding MacHelper. JavaScript workers do not expose Node.js, shell, arbitrary file, or network APIs. Browser tools such as MessageHelper-Upwork still need their browser component installed in Chrome or Edge. Marketplace search connects directly to MacHelper without a browser extension.

## Create or customize your own extension

All source tools are editable. Choose a tool under **Extensions → Edit Source** to change its local scripts, prompts, or settings schema; saving reloads an enabled tool without restarting MacHelper. Disabled tools read the changes when enabled. Native Swift code edits compile and replace only its worker; an invalid build keeps the last working version. Translation also offers direct prompt editors in its detail page. To create a separate tool, build a source folder in your own repository and import it with **Install Source…**. No additional Mac app is needed.

Give your AI coding assistant [AI_EXTENSION_GUIDE.md](AI_EXTENSION_GUIDE.md), the tool source (when modifying one), and the behavior you want. The guide contains a complete independent example, supported APIs, testing, and distribution steps. Use [Extension Development](docs/Extension-Development.md) for the human walkthrough and [Project Design](PROJECT_DESIGN.md) for the architecture. Private deployment notes stay local and are excluded from Git.

## Requirements

- macOS 14 or later. Building MacHelper requires Swift 6 or later command-line tools and Python 3; the prebuilt developer release targets Apple Silicon. Native source extensions also require Apple's Swift command-line tools on the user's Mac, even with a prebuilt MacHelper.
- A signed-in Codex/ChatGPT installation with its bundled Codex app-server, Ollama with a model downloaded, or LM Studio with a model loaded and its local server running.
- Chrome/Edge for MessageHelper. Website AI search needs a running MacHelper 6.5 or later and browser approval for the website’s local connection when requested; no search extension is needed. Node.js/npm is needed for browser development tests.
- Accessibility approval for **MacHelper** to read selected text in other apps.

ChatGPT processes requests online using the existing sign-in. The helper runs locally; it is not an offline GPT model. Ollama and LM Studio use the service running on this Mac. Remote service addresses and redirects are rejected. There is no automatic fallback between providers.

## Build and install

```sh
python3 scripts/build-apps.py
python3 scripts/install-apps.py
```

This installs `~/Applications/LocalAIBaseTools/MacHelper.app`, including its AI host, JavaScript worker executable, and native Swift worker SDK. The installer also registers an AI host copy under `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host` for Chrome/Edge native messaging.

Translation's catalog entry is included in the app. First enablement downloads its complete source to `~/Library/Application Support/LocalAIBaseTools/Extensions/com.localaibasetools.translation.macsource/`; the bundled source seed supports offline installation. Existing local source is preserved on re-enable and upgrades. On upgrade, the installer retires our earlier standalone Translation app to Trash without removing its preferences. Quit an older running MacHelper before replacing it, then reopen the installed app.

The build prefers an available Developer ID Application or Apple Development signing identity; otherwise it uses ad-hoc signing. Use `--signing-identity` to choose explicitly. A consistent Apple identity gives macOS a stable app requirement across updates. Public distribution still requires the appropriate signing/notarization release workflow.

## MacHelper settings

Settings uses a left sidebar for **General**, **AI Connection**, and **Extensions**, with the selected section on the right. Tool search lives on the website. **Extensions** opens the installed-tools list first. Choose a tool to open its detail page, or return to the list to choose another. Catalog tools that have not been installed appear separately.

In the **Installed** list, check individual tools or use **Select All**, then choose **Reload**, **Edit Source**, **Enable**, or **Disable**. Reload applies only to selected enabled tools; disabled tools stay disabled. Edit Source opens every selected source folder in VS Code, or Finder when VS Code is unavailable. Enable/Disable skip tools already in the requested state. Checked tools stay selected across refreshes and detail-page navigation. A failed action or cancelled native approval does not stop the remaining tools; the list reports the result and marks errors on the affected tool.

- **AI Connection**: provider, current model catalog, local address where relevant, Test Connection, and Save. Models are discovered dynamically; new advertised models can appear without an extension update while the provider protocol remains compatible. Retired selected models produce an error instead of silently choosing another. Ollama/LM Studio require a named model. **Website connection** shows the local search service’s status; **Restart Connection** restarts it without changing AI settings. Reconnect on the website afterward because old sessions are invalidated.
- **Extensions**: **Marketplace…** opens the tool website; source tools can also use **Install Source…**, **Add Catalog…**, **Edit Source**, and **Reload**. A selected tool's fields, labels, choices, and defaults are loaded from the settings schema declared in its own `extension.json`; MacHelper supplies the generic native controls. Installed disabled tools can be configured without starting their worker or enabling them. Marketplace installs show a native permissions review before downloading and enabling a complete source package. Existing local copies retain their edits, preferences, and enabled state. JavaScript and native Swift tools share this list and the same controls; no separate native management page is needed.
- **General**: launch at login and the system Login Items shortcut. MacHelper registers itself through Apple's ServiceManagement API on its first explicit installed-app launch. It starts in the background with a Dock icon and menu-bar shortcut when you log in; closing Settings keeps enabled extensions running. Click the Dock icon to reopen Settings. A later user disablement is respected.

Shared AI preferences are stored in the MacHelper support folder's `settings.json`; source-tool enablement, permissions, and catalog addresses are in `source-extensions.json`. Source-tool settings live separately under `ExtensionSettings/<identifier>/settings.json`. Any old native registry file remains legacy data; new native source tools use the shared source-tool state. These files contain configuration, not selected text or translations.

### Interface languages

The marketplace and MacHelper support English, Simplified Chinese, Traditional Chinese, Spanish, French, German, Japanese, Korean, Portuguese, Arabic, Hindi, Russian, and Italian. Choose a language in the website header or **MacHelper → General → Interface language**. The website initially follows browser preferences; MacHelper's **System language** follows macOS. Each remembers its own explicit choice. Arabic uses right-to-left layout. Language changes use bundled translations and make no AI requests.

Website illustrations follow the selected language too: preview labels, buttons, captions, and synthetic translation results change together. A foreign-language source sentence or English polishing example may remain foreign to demonstrate the tool. The website owns this artwork copy in `ExtensionMarket-website/preview-locales.json`; it is separate from MacHelper and extension settings catalogs.

MacHelper updates its interface without restarting workers. Finish unsaved prompt/AI settings edits and pending operations before switching. Interface language is separate from Translation's target language, AI provider, and model. Source prompts, user text, model IDs, and code stay unchanged. The technical AI guide and provider/system diagnostics may remain in their original language.

Extensions own their translated descriptions and settings labels through an optional `localizations` JSON resource in the manifest. Translation 4.5.2 includes all 13 interface languages. Unknown or older tools retain their original labels until their source provides translations; existing editable installations are never overwritten automatically. See the [source contract](docs/Source-Extensions.md) for the format.

### Translation

Open **MacHelper → Extensions → Translation**. Enable it, choose the target language, then use **Accessibility Settings…** to allow **MacHelper** in Privacy & Security. Translation 4.5.2 requires MacHelper 4.5 or later for translation and 6.2 or later for localized interface labels. Its **Translation prompt** and **Word lookup prompt** boxes show the actual source prompt files. Edit a prompt and save it to change the extension's behavior. Saved prompts are sent unchanged as provider instructions; input text, target language, and optional sentence context are separate data. MacHelper adds no translation/style instructions to these explicit-prompt requests. Permission granted to the old Translation app does not grant it to MacHelper.

Select text in another app. A small icon appears above/below the selection according to the available screen space. Click it for a nearby translation panel that fills with text as the model responds. Drag its header to move it; streaming and completion keep your chosen position. The panel shows the actual model name; Copy becomes available after the completed answer is validated. Esc, deselecting, clicking elsewhere, and switching apps dismiss/invalidate the result. Changing selections prevents an older answer from replacing the current result.

The icon requires a verified nonempty selection range. An ordinary click or a browser's cached selected-text value cannot reopen it after dismissal. Select text again by dragging, double-clicking, Shift-clicking, or using keyboard selection to show it again.

With MacHelper 4.3 and Translation 4.2, selecting one word shows its meaning in the enclosing sentence, followed by that sentence's full translation. The sentence is read only when you click the icon, through bounded Accessibility ranges. If the app cannot supply it, the panel gives a standalone word meaning and notes that sentence context is unavailable. Longer selections keep the normal translation behavior.

MacHelper 4.3.1 also reads sentence context from supported read-only browser text. It orders opaque text-marker endpoints, reads a complete paragraph of at most 2,000 UTF-16 units, and extracts the selected word's sentence locally. This handles backwards selections and inline text split by links or formatting. Unsupported apps or oversized paragraphs keep the context-unavailable fallback.

Protected/password fields, images, and apps that do not expose selected text through Accessibility cannot be read automatically. Translation never simulates Copy or changes the clipboard automatically; the result's Copy button requires a click. The extension settings page contains source editing and reload controls; demo and clipboard input buttons are not offered there.

Use **Edit Source** to open Translation's installed working folder. Change `main.js`, `prompts/translate.txt`, or its settings schema and save. The watcher debounces saves, validates a candidate, and replaces only that extension's worker. Invalid edits show an error while the last working generation remains active. Settings stay separate, and re-enabling does not overwrite local edits. **Reload** performs the same validation on demand.

### Adding extensions developed elsewhere

Create a source folder containing `extension.json`, its JavaScript or Swift entry, and the editable resources it needs. New tools also provide a root `discovery.json` with a useful description, capabilities, example queries, keywords, limitations, and platforms. Marketplace publication requires that file; older installed tools still run without it. Include it in the complete source inventory. See the [discovery metadata contract](docs/Source-Extensions.md#public-discovery-metadata-machelper-63). Choose **MacHelper → Extensions → Install Source…** to import it, or **Add Catalog…** to list tools from a JSON catalog. Enabling a catalog tool downloads every declared source file with hash/size validation and atomic installation. No additional Mac app is installed.

Browse the [Extension Market](https://local-ai-extension.nelson007.com/) or use **Marketplace…** in MacHelper. The [website project](ExtensionMarket-website/README.md) serves the catalog and complete source packages through a separate Docker container. See [Extension Development](docs/Extension-Development.md) and the detailed [source package/catalog contract](docs/Source-Extensions.md).

Native Swift tools use `runtime: "native"`, a `.swift` entry, and `native.execute` permission. Install Xcode Command Line Tools before enabling or editing native source. MacHelper compiles trusted native code into a separate worker; source changes replace that worker while the app remains open. The same settings schema renders native tool configuration. See [Native source extensions](docs/Native-Extensions.md) for the complete SDK and [Native Greeting](examples/NativeGreeting/README.md) for an independent example.

To migrate the same tool between runtimes, keep its identifier/settings keys, rewrite its command for the target SDK, and update `runtime` plus `entryPoint`. JavaScript-to-native changes need explicit approval for `native.execute` before compilation/execution; native-to-JavaScript changes remove it. Old schema-1 `.machextension` bundles and their in-process settings controllers require migration to this new source interface.

### Finding extensions

Open the [Extension Market](https://local-ai-extension.nelson007.com/). **Keywords** searches names, descriptions, capabilities, example queries, and keywords without AI. For **Describe your need**, keep MacHelper 6.5 or later running and choose **Connect MacHelper**. Approve the browser’s local connection prompt if it appears. Connecting checks the local service and creates a short-lived session; it does not call AI. Enter a task and choose **Find with AI** to use the provider/model saved in MacHelper’s **AI Connection**.

The website connects directly to MacHelper at `http://127.0.0.1:43827`. Only the official HTTPS marketplace origin is accepted. The service exposes status, session creation, bounded search, and cancellation; it does not expose arbitrary AI prompts, settings, files, or installation. Its session token stays in page memory and expires after 30 minutes. Reconnect after a session expires or MacHelper restarts. **Open MacHelper** uses `machelper://open` to launch/focus the app without starting AI. Keyword search remains available while MacHelper is unavailable.

MacHelper starts the local service when the app starts, including background login startup. Closing Settings keeps it available. Chrome or Edge can be installed before or after MacHelper; no browser-profile files or extension installation are needed for website search. A new profile or browser reinstall may require local-access approval and a new connection session, while the MacHelper installation and shared AI settings remain usable. If local access was denied, allow it in that browser’s site settings and connect again. The former MacHelper Connector is retired from current listings; existing published downloads remain available for compatibility.

For website AI requests, MacHelper downloads a small revision manifest and a separate, verified public description index, caching it with a bundled seed for unavailable networks. Source code is downloaded only when installing a chosen tool. New or changed descriptions can be published without shipping a new MacHelper. With more than 40 indexed tools, AI expands the query into keywords, local retrieval selects up to 40 candidates, then AI ranks a bounded subset. This is useful discovery rather than guaranteed exhaustive semantic search of every tool. Results identify the model and whether cached metadata is stale. Search returns up to five suggested tools with a reason and a good/partial fit; it never installs or executes extension code. Review details and permissions before separately choosing installation.

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

Selection alone does not send text for inference. AI requests happen after a translation/polishing action or an explicit discovery search. Discovery sends the entered task and public metadata to the configured provider; queries and extension descriptions are untrusted data, and discovery remains answer-only with tools disabled. Source text is treated as data. The ChatGPT client uses isolated answer-only requests with tools disabled; local HTTP providers receive no tool definitions. These tools never send Upwork messages automatically.

The helper does not save selected text or results in settings or project logs. Downloaded extension code and a last-working source cache contain tool files, not conversation history. AI providers may retain their own diagnostic or service records; an ephemeral ChatGPT thread is not a guarantee that no records exist anywhere. Extensions must follow the same data-handling rules.

## Verification

```sh
npm ci --ignore-scripts
npm test
swift test --package-path MacHelper
python3 -m unittest discover -s test -p '*_test.py'
python3 scripts/build-apps.py
python3 scripts/test-source-extensions.py
python3 scripts/test-native-extensions.py
python3 scripts/test-extension-list.py
python3 scripts/test-discovery.py
python3 scripts/test-marketplace-service.py
python3 scripts/test-source-extensions.py --live
python3 scripts/test-native.py
python3 scripts/test-native.py --catalog
python3 scripts/test-native.py --live
python3 scripts/test-extension-plugin.py --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The source-extension integration check uses temporary preferences/source folders, a loopback catalog, and real worker processes. It verifies metadata-only discovery, complete source download on enable, script/prompt/schema reload, invalid-edit recovery, persisted settings/local edits, cancellation, ordered partial streaming before completion, and worker cleanup. `--live` additionally sends one synthetic public sentence through the real configured AI provider and consumes its usage. It does not access Upwork, clipboard contents, user extension folders, or permissions.

The extension-list check drives the actual offscreen list controls with temporary tools. It verifies multi-selection, batch actions, selection persistence, partial failures, and cancelled native approval without opening a source editor or calling AI.

The discovery script checks the compatibility framed-host discovery contract with synthetic input; its optional live mode uses the saved provider and consumes usage. With MacHelper running, `python3 scripts/test-marketplace-service.py` checks the extension-free HTTP connection and rejects invalid/unauthorized requests without calling AI. Add `--live` to rank one synthetic public need through the saved provider; this consumes usage. Local-service tests use bounded HTTP/socket fixtures and mocked inference to check origin/host validation, session ownership, cancellation, and rejection of unrelated operations. Website tests mock the local HTTP API and verify that opening a page, changing language, and playing demonstrations make no connection or AI request.

The optional live AI-host check (`scripts/test-native.py --live`) also uses synthetic text only. Add `--model MODEL_ID_FROM_CATALOG` to test an explicit model. Browser tests use synthetic messages/feedback and zero-send/zero-submit sentinels. Swift tests cover the providers, framing, source validation/downloads/watchers, JavaScript and native source workers/settings, selection lifecycle/geometry, preferences, and startup decisions. Native worker integration checks build outside the editable package, exercise invalid-build recovery and runtime migration, and use isolated extension state. Legacy SDK checks remain separate development fixtures.

See [MacHelper Protocol](docs/MacHelper-Protocol.md) for browser and native AI requests.

## License

MIT. See [LICENSE](LICENSE).
