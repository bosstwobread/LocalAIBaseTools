# Developing MacHelper extensions

MacHelper is the installed app and settings host, accessible from the Dock or menu bar. Its unified extension format is an editable source package declaring either a JavaScript or native Swift runtime. An extension can be developed in a separate repository, downloaded or imported into the installed MacHelper, and changed locally without rebuilding the host or installing another app.

The source package uses manifest schema version two. MacHelper chooses a JavaScriptCore worker for `runtime: "javascript"`, or compiles and starts an independent Swift worker for `runtime: "native"`. Both share the same Extensions list, settings, installation, and reload controls. MacHelper owns shared AI settings, selection detection, floating panels, login startup, and extension settings. The independent Translation and Polish-input packages each contain `extension.json`, `main.js`, `settings.schema.json`, editable prompts under `prompts/`, root `discovery.json`, `README.md`, and `LICENSE`. The Marketplace uses `discovery.json` for searchable descriptions. Older installed packages can still run without it.

Translation and Polish-input need no browser extension. Retired browser packages remain separate and can continue using the compatibility [framed MacHelper service](MacHelper-Protocol.md). The old version-one native bundle SDK is a legacy migration source, not the new hot-reload runtime.

## Create or modify a tool with AI

Give your AI assistant the public [AI extension guide](../AI_EXTENSION_GUIDE.md), your requested behavior, and the complete source folder if modifying a tool. It includes a minimal independently importable package, exact prompt transport, capability limits, tests, and catalog distribution guidance. An author can work in a separate repository; MacHelper requires no tool-specific settings code or rebuild.

For a multilingual settings page on MacHelper 6.2+, include an optional manifest-declared `localizations` JSON resource with translations of your tool's original labels and description. The [source contract](Source-Extensions.md#extension-owned-interface-translations-machelper-62) defines its format and limits. UI translations belong in extension source and hot reload with it; changing the interface language must never rewrite prompt files, setting values, or selected text.

Treat text inside your own illustrations, screenshots, and charts as interface copy too. Use text resources or locale-specific image variants in the UI that owns the artwork, and localize captions and accessible labels. Keep those assets with the tool, check long translations and right-to-left text, and include shipped files in its source inventory. This is an authoring requirement, not an additional image-rendering API in the host's settings schema. Foreign source text in a synthetic translation demo may stay foreign; real inputs and AI answers must stay unchanged.

For an installed tool, **Edit Source** opens its working copy. For a new tool, create a source folder and use **Install Source…**. Import copies the folder, so later edits to the original authoring folder do not affect the installed copy. Save installed source changes for automatic validated reload. A fork intended to coexist with its original needs a different identifier.

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
  "permissions": ["selection.read", "ai.transform", "ui.panel"],
  "commands": [{"identifier": "translate", "title": "Translate", "trigger": "selection"}],
  "settingsSchema": "settings.schema.json"
}
```

The entry point defines commands through the host interface:

```js
MacHelper.define({
  commands: {
    async translate(input) {
      const targetLanguage = input.settings.targetLanguage || "zh-CN";
      const result = await MacHelper.ai.transform({
        action: "translate",
        text: JSON.stringify({text: input.text, targetLanguage}),
        targetLanguage,
        model: "",
        systemPrompt: MacHelper.readText("prompts/translate.txt")
      }, partial => input.reportProgress({ text: partial.text, title: "My Translation" }));
      return { text: result.text, title: "My Translation" };
    }
  }
});
```

The optional AI progress callback receives accumulated text before the final Promise resolves. `input.reportProgress` lets the command show that provisional text immediately, using the same formatting as its final result. MacHelper validates the final answer before enabling Copy. Updates from cancelled/reloaded invocations are ignored. This streaming interface requires MacHelper 4.1 or later.

The empty model follows MacHelper's shared AI connection. Settings come from a small JSON schema with `select`, `text`, `boolean`, and source-backed `prompt` fields. MacHelper renders those controls when the user chooses an installed tool under **Extensions**, including disabled tools without executing them. Change the schema in the tool source to change its form; the host requires no tool-specific settings code. A prompt field declares a `.txt` resource path instead of a default and edits that original source file with Save/Revert. Prompt resources and `systemPrompt` require MacHelper 4.5 or later. `systemPrompt` is forwarded unchanged, while `text` is separate input data; the host adds no task/style instructions to that path. `MacHelper.readText` reads a frozen resource from that worker's source generation; there is no direct filesystem, network, shell, Node.js, or npm dependency API. AI transformations require an explicit user command; loading a tool or selecting text does not trigger inference.

Use **MacHelper → Extensions → Install Source…** to copy an authoring folder into the user's writable source directory. Imported tools remain disabled until enabled. A `.macsource` suffix is convenient for installed packages. An ordinary authoring folder containing `extension.json` is also accepted. JavaScript runs in MacHelper's bundled worker. From MacHelper 6.9.1, a [verified prebuilt native worker](Native-Extensions.md#publish-a-prebuilt-worker) also runs without developer tools. For a source-only native package or an edited Swift entry, install Xcode Command Line Tools. MacHelper supplies its standalone SDK and performs a fixed, bounded build.

Once enabled, use **Edit Source** to open the working folder. Saving scripts, prompts, manifest metadata, or the settings schema triggers a debounced reload. **Reload** requests the same check manually. A candidate must pass package, settings, runtime-specific code/build, and declared-command validation before replacing the running worker. Invalid edits retain the last working generation. Other tools and MacHelper stay running, while the changed tool's worker-local state resets. Stopping/replacing a worker cancels its pending operations and discards stale results.

Settings are stored outside the source package at the MacHelper support folder's `ExtensionSettings/<identifier>/settings.json`. Disabling retains settings and source, and stops the worker and watcher. Re-enable preserves user edits rather than downloading over the installed folder. An edit adding capabilities beyond those previously enabled requires disabling and re-enabling to approve that change.

For several installed tools, use the list checkboxes or **Select All**, then **Reload**, **Edit Source**, **Enable**, or **Disable** (MacHelper 6.1+). The same runtime-specific lifecycle runs for each selected tool; Reload skips disabled tools, and Edit Source opens all selected working folders. One failed operation or cancelled native approval does not abort the other selected tools.

See [Editable source extensions](Source-Extensions.md) for the complete manifest, JavaScript, schema, bounds, path validation, permission, and download contracts.

## Selection actions and polishing

When testing the selection toolbar, make sure **General → Enable MacHelper** is checked. Pausing MacHelper stops selection actions while retaining tool settings and permissions.

MacHelper 6.6+ lists all enabled `selection` commands in one floating toolbar. MacHelper 6.6.1 presents separate icons in a compact horizontal row; command `systemSymbolName` is optional, with capability-based defaults. Give commands clear extension-owned titles and localizations for tooltips, accessibility labels, and the overflow menu. A real selected span shows the toolbar; only choosing its action invokes the worker. There is no separate per-tool overlay and no first-command-only rule. See the [source toolbar contract](Source-Extensions.md#shared-toolbar-and-guarded-replacement-machelper-66). MacHelper 6.7.1 adds bounded hit/focus/window/application selection routes, exact numeric or marker-span reading, and Command-modifier toolbar hiding in that shared host contract. These need no extension-owned UI or relaxed editing checks. MacHelper 6.7 adds a guarded automatic Copy-and-restore fallback after recognized selection gestures when Accessibility cannot read the selection, without a manual switch. It does not run from ordinary clicks or polling, bypass protected/caret/invalid evidence, or grant Apply from clipboard-only text. At tool click, a fresh matching AX read may recover the original numeric range/origin proof while the original context is unchanged; all normal editable-target checks still apply. For a clipboard-captured selection, **Apply** can use the original editor’s standard Paste command when MacHelper can verify the window and its editing commands. Keep the text selected while reviewing the preview. This method leaves the result on the clipboard. **Copy** remains available. Unreadable or oversized snapshots and stale contexts skip capture; later clipboard changes prevent overwriting new content. No macOS Services, OCR, or screen-reading permission is added, and universal coverage or preservation is not guaranteed. See the shared source contract for exact capture and restoration limits.

MacHelper handles Electron compatibility for installations with an opt-in saved in an earlier version. For an unreadable selection, the host can request full Accessibility for the focused editor window. Users may need to select again in a newly opened VS Code window. Extension authors use the ordinary selection API. Apply still requires a verified target. See the [host compatibility contract](Source-Extensions.md#shared-toolbar-and-guarded-replacement-machelper-66).

For a tool such as Polish-input, add `selection.replace` alongside `selection.read`, `ai.transform`, and `ui.panel`. Request `selection.paste` for clipboard-assisted Apply on an exact range or menu-based paste into the current selection in the original window. Both require read/replace access and separate approval. Keep polishing instructions in a source prompt and return the ordinary `{text, title}` result. MacHelper handles the Apply button and chooses a supported editing method for that result. It offers editing only for a completed preview and only after another explicit user click.

For an exact-range edit, Apply rechecks the source app and PID, focused AX element identity, selected text, range, and enabled, nonprotected editable state. A bounded Accessibility parent-chain check identifies web editors, including supported editors embedded in desktop apps, which select approved paste before any write even if a selected-text setter is advertised writable. Verified native controls prefer `AXSelectedText`. A depth/deadline-limited unknown classification permits only approved paste with strict positive editability and all original focus/range/text/permission checks; it never permits a direct setter. Missing/cyclic/protected ancestry stays blocked with Copy. No browser/app allowlist chooses the route. Every exact-range Apply paste requires approval and strict editable-field evidence. For approved `selection.paste`, the host may write only the completed result and its ownership stamp to the clipboard, revalidate target and own clipboard change count/stamp, then send fixed Command-V down/up to that original PID. This Apply transaction never reads/saves/restores previous clipboard contents; the result remains there. Automatic selection capture is a separate guarded host operation. There is no whole-field value write/reconstruction, app activation, focus/range forcing, arbitrary keyboard SDK, Enter/Send, or automatic retry after a direct write. Both supported partial and full selections are eligible. Unsupported/read-only/protected fields keep manual Copy. The host reports a paste as requested unless insertion is confirmed; check the original app. Formatting and Undo vary. Test only disposable fields with sending disabled. See the [exact capability contract](Source-Extensions.md#shared-toolbar-and-guarded-replacement-machelper-66).

## Describe a tool so people can find it

Add root `discovery.json` with schema version 1, an accurate description, capabilities, example task queries, keywords, limitations, and platforms. Optional installation steps and exact-source translation maps provide public display text. Keep metadata in the extension's source folder, including for tools in separate repositories; do not hard-code tool descriptions in MacHelper. Use all 13 supported language maps for a fully localized listing. See the [complete metadata schema and bounds](Source-Extensions.md#public-discovery-metadata-machelper-63).

The website publisher generates an independent public index and revision/hash manifest. MacHelper’s local AI service refreshes metadata, not every tool's source; a verified local cache or release seed supports stale/offline results. The website has keyword search plus **Describe your need → Find with AI**. That one click validates the need, establishes or renews a local session when needed, and searches using shared AI settings; no separate connection button is needed. Invalid input never contacts the local service. MacHelper 6.5 or later runs the narrow loopback service, so no browser search extension is needed. The connection handshake may ask for browser local-access approval and creates a short-lived in-memory session without inference. An HTTP 401 rejection before inference can renew the session and retry the search once; other AI/provider errors do not trigger automatic retries. Larger catalogs use AI query expansion, a local shortlist, and bounded ranking; up to five known tools are suggested with reasons and fit labels. Search cannot install or run code, and it is not guaranteed exhaustive semantic search. Website keyword search and setup links remain available without the local connection. See the [website discovery protocol](MacHelper-Protocol.md#website-local-discovery-machelper-65).

## Catalogs and complete source download

The marketplace serves a JSON catalog over HTTPS. Each entry contains display metadata plus every source file's relative path, download URL, SHA-256, and optional size. List the manifest, scripts, prompts, schema, `discovery.json`, README, and license; distributing only an executable is not the source format.

**Add Catalog…** registers extension update metadata without downloading or running packages. To install a published extension, open it in **Marketplace…** and use **Install & Enable** in MacHelper’s review. MacHelper stages the complete declared inventory, validates every file and the manifest identity and version, then installs the complete source folder in one operation. Failed downloads leave no partial installed tool. Re-enabling uses the installed source. Once an update source offers a newer version, the card’s update icon and the detail page’s **Update…** button both open the update review. MacHelper retains the previous source as a backup. [Update behavior](Source-Extensions.md#updating-an-installed-extension)

The Marketplace publishes `catalog.json` from approved GitHub commits. Each author owns the package, tests, and version in their extension repository. See the standalone build instructions for [Translation](https://github.com/bosstwobread/Translation-MacHelper) and [Polish-input](https://github.com/bosstwobread/Polish-input-MacHelper). A separate catalog or CDN can use the same complete inventory contract and immutable source URLs. For offline installation, use **Install Source…** with a previously downloaded package or its extracted archive.

## Source verification

```sh
node --test test/translation-source.test.cjs test/polish-input-source.test.cjs
swift test --package-path MacHelper
python3 scripts/test-source-extensions.py
python3 scripts/test-native-extensions.py
python3 scripts/test-source-extensions.py --live
```

The lifecycle check serves a historical fixture through a loopback catalog and uses temporary source and settings directories with the real JavaScript worker. It checks full source installation, reloads, invalid-source recovery, persisted settings and local edits, cancellation, and process cleanup. `--live` additionally transforms one synthetic public sentence through the configured AI service. The check uses an isolated profile and synthetic data.

## Native Swift source workers

MacHelper 6 adds `runtime: "native"` to the same schema-2 source format. Native packages have one `.swift` entry and require `native.execute` approval. They use **Install Source**, **Edit Source**, the same schema-generated settings, and **Reload**; there is no separate native management screen. Valid native source edits compile and replace only the extension worker, while build/startup failures retain the prior working generation.

See [Native source extensions](Native-Extensions.md) for a complete package, exact Swift API, compiler/cache behavior, and migration instructions. The [standalone native SDK](https://local-ai-extension.nelson007.com/NativeExtensionSDK/MacHelperNativeSDK.swift) is supplied by the app during compilation. JavaScript and native workers share the AI broker, generation/cancellation rules, prompt ownership, settings schema, and capability interface. Native Swift remains trusted executable code with the user's OS access rather than a restricted JavaScript environment.

## Runtime migration

Preserve the extension's identifier and compatible settings keys when migrating the same tool. Rewrite commands for the new API and update `runtime` plus `entryPoint`; MacHelper then chooses the corresponding execution/reload adapter. If `native.execute` has not already been granted, adding it to a running JavaScript tool requires approval through disable/re-enable before native compilation/execution; other newly requested capabilities also require re-enabling. Until approval or when a new build fails, the old generation remains active. Returning to JavaScript removes `native.execute` and starts a JavaScript worker after validation. Public distribution still requires a new version and freshly computed file inventory.

## Legacy native bundle migration

Schema-1 `.machextension` bundles and the old Objective-C header remain for isolated CLI verification and migration reference; the normal app does not automatically load them. Their in-process `NSViewController` settings interface is not accepted as a remote settings view by the new worker SDK. Move reusable logic into a schema-2 native Swift source package and declare settings in `settings.schema.json`. The separate **Native Plug-ins** interface has been removed. Existing legacy code must migrate; renaming a bundle or setting a runtime flag alone cannot make it hot reload.
