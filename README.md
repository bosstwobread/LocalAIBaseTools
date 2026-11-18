# LocalAIBaseTools

**MacHelper** is one macOS app for your AI connection, extensions, and extension settings. Click its Dock icon to open Settings, or use its menu-bar shortcut. **Translation** and **Polish-input** are editable JavaScript source extensions: select text in a supported Mac app, then choose the Translate or Polish icon in one shared floating toolbar. Polishing streams a preview and changes selected text only after **Apply**. Neither tool needs a browser extension. The **Extension Market** searches public extension descriptions with keywords or MacHelper’s built-in local service for explicit AI matching. Current release: MacHelper **6.6.1** (build **661**), Translation **4.5.2**, Polish-input **1.0.0**. MessageHelper — Upwork is retired from current distribution; its compatibility source and published downloads are preserved.

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
│   └── Polish-input/             Editable cross-app polishing source and prompt
├── legacy/MessageHelper-Upwork/  Retired browser package and safe test fixture
├── catalog/extensions.json       Source catalog metadata and complete SHA-256 file inventory
├── ExtensionMarket-website/      Searchable tool marketplace, source packages, Docker deployment
├── examples/NativeGreeting/      Independent native Swift source-worker example
├── examples/ExternalGreeting/    Legacy in-process SDK migration fixture
├── scripts/                      Build/install and integration checks
└── test/                         Browser and installer tests with synthetic fixtures
```

JavaScript and native Swift source extensions share one Extensions interface. Their manifest runtime chooses execution and reload automatically. Source extensions use MacHelper's capability interface for selected text, nearby panels, shared AI, and schema-based settings. They can be authored outside this repository and installed without rebuilding MacHelper. JavaScript workers do not expose Node.js, shell, arbitrary file, or network APIs. Translation and Polish-input use MacHelper’s shared selection toolbar, without browser installation. Retired browser clients can still use the compatibility AI host. Marketplace search also connects directly to MacHelper without a browser extension.

## Create or customize your own extension

All source tools are editable. Choose a tool under **Extensions → Edit Source** to change its local scripts, prompts, or settings schema; saving reloads an enabled tool without restarting MacHelper. Disabled tools read the changes when enabled. Native Swift code edits compile and replace only its worker; an invalid build keeps the last working version. Translation and Polish-input also offer direct prompt editors in their detail pages. To create a separate tool, build a source folder in your own repository and import it with **Install Source…**. No additional Mac app is needed.

Give your AI coding assistant [AI_EXTENSION_GUIDE.md](AI_EXTENSION_GUIDE.md), the tool source (when modifying one), and the behavior you want. The guide contains a complete independent example, supported APIs, testing, and distribution steps. Use [Extension Development](docs/Extension-Development.md) for the human walkthrough and [Project Design](PROJECT_DESIGN.md) for the architecture. Private deployment notes stay local and are excluded from Git.

## Requirements

- macOS 14 or later. Building MacHelper requires Swift 6 or later command-line tools and Python 3; the prebuilt developer release targets Apple Silicon. Native source extensions also require Apple's Swift command-line tools on the user's Mac, even with a prebuilt MacHelper.
- A signed-in Codex/ChatGPT installation with its bundled Codex app-server, Ollama with a model downloaded, or LM Studio with a model loaded and its local server running.
- A supported Mac app exposing selected text through Accessibility. Browser fields can use Translation and Polish-input without a Chrome/Edge extension. Website AI search needs a running MacHelper 6.5 or later and browser approval for the website’s local connection when requested. Node.js/npm is needed for JavaScript development tests.
- Accessibility approval for **MacHelper** to read selected text in other apps and apply approved replacements in supported editable fields.

ChatGPT processes requests online using the existing sign-in. The helper runs locally; it is not an offline GPT model. Ollama and LM Studio use the service running on this Mac. Remote service addresses and redirects are rejected. There is no automatic fallback between providers.

## Build and install

```sh
python3 scripts/build-apps.py
python3 scripts/install-apps.py
```

The build regenerates the first-party source catalog before bundling so its inventories match the included source seeds. Installation places `MacHelper.app` at `~/Applications/LocalAIBaseTools/`, including its AI host, JavaScript worker executable, and native Swift worker SDK. The installer also registers an AI host copy under `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host` for Chrome/Edge native messaging.

Translation and Polish-input catalog entries are included in the app. First enablement downloads each complete source to `~/Library/Application Support/LocalAIBaseTools/Extensions/<identifier>.macsource/`; the bundled `Contents/Resources/SourceSeeds/<identifier>.macsource/` seeds support offline installation. Their identifiers are `com.localaibasetools.translation` and `com.localaibasetools.polish-input`. Existing local source is preserved on re-enable and upgrades. On upgrade, the installer retires our earlier standalone Translation app to Trash without removing its preferences. Quit an older running MacHelper before replacing it, then reopen the installed app.

The build prefers an available Developer ID Application or Apple Development signing identity; otherwise it uses ad-hoc signing. Use `--signing-identity` to choose explicitly. A consistent Apple identity gives macOS a stable app requirement across updates. Public distribution still requires the appropriate signing/notarization release workflow.

## MacHelper settings

Settings uses a left sidebar for **General**, **AI Connection**, and **Extensions**, with the selected section on the right. Tool search lives on the website. **Extensions** opens the installed-tools list first. Choose a tool to open its detail page, or return to the list to choose another. Catalog tools that have not been installed appear separately.

In the **Installed** list, check individual tools or use **Select All**, then choose **Reload**, **Edit Source**, **Enable**, or **Disable**. Reload applies only to selected enabled tools; disabled tools stay disabled. Edit Source opens every selected source folder in VS Code, or Finder when VS Code is unavailable. Enable/Disable skip tools already in the requested state. Checked tools stay selected across refreshes and detail-page navigation. A failed action or cancelled native approval does not stop the remaining tools; the list reports the result and marks errors on the affected tool.

- **AI Connection**: provider, current model catalog, local address where relevant, Test Connection, and Save. Models are discovered dynamically; new advertised models can appear without an extension update while the provider protocol remains compatible. Retired selected models produce an error instead of silently choosing another. Ollama/LM Studio require a named model. **Website connection** shows the local search service’s status; **Restart Connection** restarts it without changing AI settings. Old website sessions are invalidated; the next **Find with AI** click creates a new connection as needed.
- **Extensions**: **Marketplace…** opens the tool website; source tools can also use **Install Source…**, **Add Catalog…**, **Edit Source**, and **Reload**. A selected tool's fields, labels, choices, and defaults are loaded from the settings schema declared in its own `extension.json`; MacHelper supplies the generic native controls. Installed disabled tools can be configured without starting their worker or enabling them. Marketplace installs show a native permissions review before downloading and enabling a complete source package. Existing local copies retain their edits, preferences, and enabled state. JavaScript and native Swift tools share this list and the same controls; no separate native management page is needed.
- **General**: launch at login and the system Login Items shortcut. MacHelper registers itself through Apple's ServiceManagement API on its first explicit installed-app launch. It starts in the background with a Dock icon and menu-bar shortcut when you log in; closing Settings keeps enabled extensions running. Click the Dock icon to reopen Settings. A later user disablement is respected.

**General → Improve compatibility with Electron apps** is off by default. When enabled, a new text-selection gesture can ask a supporting app to expose full Accessibility information; select text again after changing it. Some apps may change behavior: VS Code can enter Screen Reader Optimized mode, affecting folding and the minimap. Turning it off stops new requests; already affected apps may need a restart to revert. It does not enable VoiceOver or change macOS permissions. Compatibility requests do not guarantee Apply support; insufficient editability evidence still keeps Copy.

Shared AI preferences are stored in the MacHelper support folder's `settings.json`; source-tool enablement, permissions, and catalog addresses are in `source-extensions.json`. Source-tool settings live separately under `ExtensionSettings/<identifier>/settings.json`. Any old native registry file remains legacy data; new native source tools use the shared source-tool state. These files contain configuration, not selected text or translations.

### Interface languages

The marketplace and MacHelper support English, Simplified Chinese, Traditional Chinese, Spanish, French, German, Japanese, Korean, Portuguese, Arabic, Hindi, Russian, and Italian. Choose a language in the website header or **MacHelper → General → Interface language**. The website initially follows browser preferences; MacHelper's **System language** follows macOS. Each remembers its own explicit choice. Arabic uses right-to-left layout. Language changes use bundled translations and make no AI requests.

Website illustrations follow the selected language too: preview labels, buttons, captions, and synthetic translation results change together. A foreign-language source sentence or English polishing example may remain foreign to demonstrate the tool. The website owns this artwork copy in `ExtensionMarket-website/preview-locales.json`; it is separate from MacHelper and extension settings catalogs.

MacHelper updates its interface without restarting workers. Finish unsaved prompt/AI settings edits and pending operations before switching. Interface language is separate from Translation's target language, AI provider, and model. Source prompts, user text, model IDs, and code stay unchanged. The technical AI guide and provider/system diagnostics may remain in their original language.

Extensions own their translated descriptions and settings labels through an optional `localizations` JSON resource in the manifest. Translation 4.5.2 and Polish-input 1.0.0 include all 13 interface languages. Unknown or older tools retain their original labels until their source provides translations; existing editable installations are never overwritten automatically. See the [source contract](docs/Source-Extensions.md) for the format.

### Translation

Open **MacHelper → Extensions → Translation**. Enable it, choose the target language, then use **Accessibility Settings…** to allow **MacHelper** in Privacy & Security. Translation 4.5.2 requires MacHelper 4.5 or later for translation and 6.2 or later for localized interface labels. Its **Translation prompt** and **Word lookup prompt** boxes show the actual source prompt files. Edit a prompt and save it to change the extension's behavior. Saved prompts are sent unchanged as provider instructions; input text, target language, and optional sentence context are separate data. MacHelper adds no translation/style instructions to these explicit-prompt requests. Permission granted to the old Translation app does not grant it to MacHelper.

Select text in another app. A shared toolbar appears above/below the selection according to the available screen space, with icons from enabled selection tools. Choose the **Translate** icon for a nearby translation panel that fills with text as the model responds. Drag its header to move it; streaming and completion keep your chosen position. The panel shows the actual model name; Copy becomes available after the completed answer is validated. Esc, deselecting, clicking elsewhere, and switching apps dismiss/invalidate the result. Changing selections prevents an older answer from replacing the current result.

MacHelper owns one toolbar and one active result panel, so enabled tools do not place separate icons on top of each other. MacHelper 6.6.1 displays separate icon cells in one compact horizontal row, with space between them. Hover for the localized command name; accessibility labels retain the same name. The toolbar stays within the available screen space and shows at most five cells: all actions when there are five or fewer, otherwise four actions plus an ellipsis icon. The ellipsis opens **More…**, a native scrolling menu with the remaining command names, so every enabled selection command stays accessible. Each tool still has its own source, worker, prompts, and settings. Reloading, enabling, or disabling an unrelated tool preserves the current operation/result while its owning extension activation and command stay unchanged; replacing or disabling that activation invalidates the operation. Each validated source/settings activation has its own identity; an internal worker recovery during that activation does not turn an unrelated toolbar update into cancellation.

The toolbar requires a verified nonempty selection range. An ordinary click or a browser's cached selected-text value cannot reopen it after dismissal. Select text again by dragging, double-clicking, Shift-clicking, or using keyboard selection to show it again.

With MacHelper 4.3 and Translation 4.2, selecting one word shows its meaning in the enclosing sentence, followed by that sentence's full translation. The sentence is read only when you click the icon, through bounded Accessibility ranges. If the app cannot supply it, the panel gives a standalone word meaning and notes that sentence context is unavailable. Longer selections keep the normal translation behavior.

MacHelper 4.3.1 also reads sentence context from supported read-only browser text. It orders opaque text-marker endpoints, reads a complete paragraph of at most 2,000 UTF-16 units, and extracts the selected word's sentence locally. This handles backwards selections and inline text split by links or formatting. Unsupported apps or oversized paragraphs keep the context-unavailable fallback.

Protected/password fields, images, and apps that do not expose selected text through Accessibility cannot be read automatically. Translation never simulates Copy or changes the clipboard automatically; the result's Copy button requires a click. The extension settings page contains source editing and reload controls; demo and clipboard input buttons are not offered there.

Use **Edit Source** to open Translation's installed working folder. Change `main.js`, `prompts/translate.txt`, or its settings schema and save. The watcher debounces saves, validates a candidate, and replaces only that extension's worker. Invalid edits show an error while the last working generation remains active. Settings stay separate, and re-enabling does not overwrite local edits. **Reload** performs the same validation on demand.

### Polish-input

Open **MacHelper → Extensions → Polish-input**, enable it, and review its `selection.read`, `selection.replace`, `selection.paste`, `ai.transform`, and `ui.panel` access. MacHelper 6.6 or later is required. Its editable source prompt defines the polishing instructions; MacHelper forwards that prompt unchanged and uses the shared provider/model.

Select a draft in a supported app and choose the **Polish** icon from the shared toolbar. Read the streamed preview, then choose **Apply**. MacHelper rechecks the original app/PID, focused Accessibility element, exact numeric selection range and selected text, and enabled/nonprotected editable state. MacHelper checks whether the selected field belongs to a web editor or a native control. Supported web editors, including those embedded in desktop apps, use approved **Clipboard-assisted Apply** (`selection.paste`) before any write because an advertised writable selection may still ignore a direct edit. Verified native controls prefer direct selected-text replacement and can use approved paste when direct editing is unavailable. If the bounded check cannot determine the editor type, only approved paste is eligible, with the same strict editable-field and selection checks. Fields without that evidence keep Copy. The host puts the completed result on the clipboard and sends only Command-V to the verified source app after another target and clipboard-ownership check. Without paste approval or sufficient editable-field evidence, a web selection keeps Copy. Both partial and full selections can work when the editor exposes the required evidence; there is no select-all requirement.

Clipboard-assisted Apply has a separate permission review explaining that it replaces the clipboard and leaves the result there, like Copy. MacHelper never reads, saves, or restores your previous clipboard. It does not activate another app, force a selection, send Enter, or click Send. If target or clipboard ownership changes, it refuses the paste. A dispatched paste is reported as requested unless the inserted text can be confirmed; check the original app before continuing. There is no automatic retry or rollback. A completed preview remains available through **Copy** for read-only or unsupported fields, and sending remains your action.

After an explicit Apply attempt, the completed preview and Copy remain visible through Accessibility polling changes caused by the write, with Apply disabled. Explicit dismissal or an outside click, a new selection gesture, switching apps, or replacing/disabling the owning activation clears that retained preview.

Replacement depends on the editor’s Accessibility support and, where needed, approved clipboard-assisted Apply. Browser fields can support partial or full selections; unsupported fields keep manual Copy. Replacement is plain text; rich formatting and the editor’s Undo behavior are not guaranteed. Protected fields and text inside images are unsupported. Editing Polish-input’s prompt, script, or settings schema uses the same validated hot-reload workflow as Translation.

### Adding extensions developed elsewhere

Create a source folder containing `extension.json`, its JavaScript or Swift entry, and the editable resources it needs. New tools also provide a root `discovery.json` with a useful description, capabilities, example queries, keywords, limitations, and platforms. Marketplace publication requires that file; older installed tools still run without it. Include it in the complete source inventory. See the [discovery metadata contract](docs/Source-Extensions.md#public-discovery-metadata-machelper-63). Choose **MacHelper → Extensions → Install Source…** to import it, or **Add Catalog…** to list tools from a JSON catalog. Enabling a catalog tool downloads every declared source file with hash/size validation and atomic installation. No additional Mac app is installed.

Browse the [Extension Market](https://local-ai-extension.nelson007.com/) or use **Marketplace…** in MacHelper. The [website project](ExtensionMarket-website/README.md) serves the catalog and complete source packages through a separate Docker container. See [Extension Development](docs/Extension-Development.md) and the detailed [source package/catalog contract](docs/Source-Extensions.md).

Native Swift tools use `runtime: "native"`, a `.swift` entry, and `native.execute` permission. Install Xcode Command Line Tools before enabling or editing native source. MacHelper compiles trusted native code into a separate worker; source changes replace that worker while the app remains open. The same settings schema renders native tool configuration. See [Native source extensions](docs/Native-Extensions.md) for the complete SDK and [Native Greeting](examples/NativeGreeting/README.md) for an independent example.

To migrate the same tool between runtimes, keep its identifier/settings keys, rewrite its command for the target SDK, and update `runtime` plus `entryPoint`. JavaScript-to-native changes need explicit approval for `native.execute` before compilation/execution; native-to-JavaScript changes remove it. Old schema-1 `.machextension` bundles and their in-process settings controllers require migration to this new source interface.

### Finding extensions

Open the [Extension Market](https://local-ai-extension.nelson007.com/). **Keywords** searches names, descriptions, capabilities, example queries, and keywords without AI. For **Describe your need**, keep MacHelper 6.5 or later running, enter a task, and choose **Find with AI**. That one click validates the need, checks/creates the local connection when necessary, and searches using the provider/model saved in MacHelper’s **AI Connection**. Approve the browser’s local connection prompt if it appears. Blank or invalid input makes no local request. There is no separate Connect or Reconnect button.

The website connects directly to MacHelper at `http://127.0.0.1:43827`. Only the official HTTPS marketplace origin is accepted. The service exposes status, session creation, bounded search, and cancellation; it does not expose arbitrary AI prompts, settings, files, or installation. Its session token stays in page memory and expires after 30 minutes. A new page, expired session, or app restart is handled by the next **Find with AI** click. If an old token is rejected with HTTP 401 before inference, the website renews the session and retries that search once; provider failures and other AI errors are not retried automatically. If the connection fails, **Open MacHelper** uses `machelper://open` to launch/focus the app without starting AI, and **Get MacHelper** offers the download. An unreachable service cannot tell the website whether the app is closed or missing, so it offers both actions without assuming the app is uninstalled. Keyword search remains available.

MacHelper starts the local service when the app starts, including background login startup. Closing Settings keeps it available. Chrome or Edge can be installed before or after MacHelper; no browser-profile files or extension installation are needed for website search. A new profile or browser reinstall may require local-access approval and a new connection session, while the MacHelper installation and shared AI settings remain usable. If local access was denied, allow it in that browser’s site settings and choose **Find with AI** again. The former MacHelper Connector is retired from current listings; existing published downloads remain available for compatibility.

For website AI requests, MacHelper downloads a small revision manifest and a separate, verified public description index, caching it with a bundled seed for unavailable networks. Source code is downloaded only when installing a chosen tool. New or changed descriptions can be published without shipping a new MacHelper. With more than 40 indexed tools, AI expands the query into keywords, local retrieval selects up to 40 candidates, then AI ranks a bounded subset. This is useful discovery rather than guaranteed exhaustive semantic search of every tool. The service response retains the model and whether cached metadata is stale; these details are not shown in the search form. Search returns up to five suggested tools with a reason and a good/partial fit; it never installs or executes extension code. Review details and permissions before separately choosing installation.

### Retired MessageHelper — Upwork

Translation and Polish-input replace the main translation and polishing workflows through text selection in supported Mac apps, including browser fields. MessageHelper — Upwork is no longer a current marketplace tool. Its source is retained under `legacy/MessageHelper-Upwork/`, and immutable published downloads remain available for compatibility. The old inline per-message controls are specific to that retired browser package; the current tools use the floating selection toolbar.

The framed host remains compatible with existing browser and standalone clients. Its canonical name is `com.localaibasetools.mac_helper`; `com.messagehelper.gpt` is a compatibility alias. Existing browser registrations are preserved. Additional legacy browser clients still require explicit IDs, with no wildcard origins:

```sh
python3 scripts/install-helper.py --extension-id ADDITIONAL_32_CHARACTER_EXTENSION_ID
```

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

The optional live AI-host check (`scripts/test-native.py --live`) also uses synthetic text only. Add `--model MODEL_ID_FROM_CATALOG` to test an explicit model. Browser tests use synthetic messages/feedback and zero-send/zero-submit sentinels. Swift tests cover the providers, framing, source validation/downloads/watchers, JavaScript and native source workers/settings, shared-toolbar routing, selected-text replacement validation, selection lifecycle/geometry, preferences, and startup decisions. Native worker integration checks build outside the editable package, exercise invalid-build recovery and runtime migration, and use isolated extension state. Legacy SDK checks remain separate development fixtures.

See [MacHelper Protocol](docs/MacHelper-Protocol.md) for browser and native AI requests.

## License

MIT. See [LICENSE](LICENSE).
