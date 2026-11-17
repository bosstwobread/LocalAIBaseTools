# Developing MacHelper extensions

MacHelper is the installed app and settings host, accessible from the Dock or menu bar. Its unified extension format is an editable source package declaring either a JavaScript or native Swift runtime. An extension can be developed in a separate repository, downloaded or imported into the installed MacHelper, and changed locally without rebuilding the host or installing another app.

The source package uses manifest schema version two. MacHelper chooses a JavaScriptCore worker for `runtime: "javascript"`, or compiles and starts an independent Swift worker for `runtime: "native"`. Both share the same Extensions list, settings, installation, and reload controls. MacHelper owns shared AI settings, selection detection, floating panels, login startup, and extension settings. Translation is the first source tool; its files include `extension.json`, `main.js`, `settings.schema.json`, editable prompts under `prompts/`, root `discovery.json`, `README.md`, and `LICENSE`. New tools keep searchable descriptions in their own `discovery.json`; publishing requires it, while older installed packages remain runnable without it.

Browser extensions remain separate browser packages and can continue using the [framed MacHelper service](MacHelper-Protocol.md). The old version-one native bundle SDK is a legacy migration source, not the new hot-reload runtime.

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

Use **MacHelper → Extensions → Install Source…** to copy an authoring folder into the user's writable source directory. Imported tools remain disabled until enabled. A `.macsource` suffix is convenient for installed packages; an ordinary authoring folder containing `extension.json` is also accepted. A JavaScript package is independent of MacHelper's Swift modules and needs no Swift compilation. A native source package requires Xcode Command Line Tools; the host supplies its standalone SDK and performs a fixed bounded build.

Once enabled, use **Edit Source** to open the working folder. Saving scripts, prompts, manifest metadata, or the settings schema triggers a debounced reload. **Reload** requests the same check manually. A candidate must pass package, settings, runtime-specific code/build, and declared-command validation before replacing the running worker. Invalid edits retain the last working generation. Other tools and MacHelper stay running, while the changed tool's worker-local state resets. Stopping/replacing a worker cancels its pending operations and discards stale results.

Settings are stored outside the source package at the MacHelper support folder's `ExtensionSettings/<identifier>/settings.json`. Disabling retains settings and source, and stops the worker and watcher. Re-enable preserves user edits rather than downloading over the installed folder. An edit adding capabilities beyond those previously enabled requires disabling and re-enabling to approve that change.

For several installed tools, use the list checkboxes or **Select All**, then **Reload**, **Edit Source**, **Enable**, or **Disable** (MacHelper 6.1+). The same runtime-specific lifecycle runs for each selected tool; Reload skips disabled tools, and Edit Source opens all selected working folders. One failed operation or cancelled native approval does not abort the other selected tools.

See [Editable source extensions](Source-Extensions.md) for the complete manifest, JavaScript, schema, bounds, path validation, permission, and download contracts.

## Describe a tool so people can find it

Add root `discovery.json` with schema version 1, an accurate description, capabilities, example task queries, keywords, limitations, and platforms. Optional installation steps and exact-source translation maps provide public display text. Keep metadata in the extension's source folder, including for tools in separate repositories; do not hard-code tool descriptions in MacHelper. Use all 13 supported language maps for a fully localized listing. See the [complete metadata schema and bounds](Source-Extensions.md#public-discovery-metadata-machelper-63).

The website publisher generates an independent public index and revision/hash manifest. MacHelper’s local AI service refreshes metadata, not every tool's source; a verified local cache or release seed supports stale/offline results. The website has keyword search plus **Describe your need → Connect MacHelper → Find with AI**, using shared AI settings only after an explicit AI search. MacHelper 6.5 or later runs the narrow loopback service, so no browser search extension is needed. Connecting may ask for browser local-access approval and creates a short-lived in-memory session without calling AI. Larger catalogs use AI query expansion, a local shortlist, and bounded ranking; up to five known tools are suggested with reasons and fit labels. Search cannot install or run code, and it is not guaranteed exhaustive semantic search. Website keyword search and setup links remain available without the local connection. See the [website discovery protocol](MacHelper-Protocol.md#website-local-discovery-machelper-65).

## Catalogs and complete source download

The marketplace serves a JSON catalog over HTTPS. Each entry contains display metadata plus every source file's relative path, download URL, SHA-256, and optional size. List the manifest, scripts, prompts, schema, `discovery.json`, README, and license; distributing only an executable is not the source format.

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
python3 scripts/test-native-extensions.py
python3 scripts/test-source-extensions.py --live
```

The integration check serves the entire Translation package through a loopback catalog and uses temporary source/preferences directories with real independent JavaScript workers. It checks discovery without download, full source installation on enable, reloads after script/prompt/schema edits, invalid-source recovery, persisted settings and local edits, cancellation, and process cleanup. `--live` additionally transforms one synthetic public sentence through the configured AI service. It does not install a test tool into the user's account or access Upwork, the clipboard, or app permissions.

## Native Swift source workers

MacHelper 6 adds `runtime: "native"` to the same schema-2 source format. Native packages have one `.swift` entry and require `native.execute` approval. They use **Install Source**, **Edit Source**, the same schema-generated settings, and **Reload**; there is no separate native management screen. Valid native source edits compile and replace only the extension worker, while build/startup failures retain the prior working generation.

See [Native source extensions](Native-Extensions.md) for a complete package, exact Swift API, compiler/cache behavior, and migration instructions. The [standalone native SDK](https://local-ai-extension.nelson007.com/NativeExtensionSDK/MacHelperNativeSDK.swift) is supplied by the app during compilation. JavaScript and native workers share the AI broker, generation/cancellation rules, prompt ownership, settings schema, and capability interface. Native Swift remains trusted executable code with the user's OS access rather than a restricted JavaScript environment.

## Runtime migration

Preserve the extension's identifier and compatible settings keys when migrating the same tool. Rewrite commands for the new API and update `runtime` plus `entryPoint`; MacHelper then chooses the corresponding execution/reload adapter. If `native.execute` has not already been granted, adding it to a running JavaScript tool requires approval through disable/re-enable before native compilation/execution; other newly requested capabilities also require re-enabling. Until approval or when a new build fails, the old generation remains active. Returning to JavaScript removes `native.execute` and starts a JavaScript worker after validation. Public distribution still requires a new version and freshly computed file inventory.

## Legacy native bundle migration

Schema-1 `.machextension` bundles and the old Objective-C header remain for isolated CLI verification and migration reference; the normal app does not automatically load them. Their in-process `NSViewController` settings interface is not accepted as a remote settings view by the new worker SDK. Move reusable logic into a schema-2 native Swift source package and declare settings in `settings.schema.json`. The separate **Native Plug-ins** interface has been removed. Existing legacy code must migrate; renaming a bundle or setting a runtime flag alone cannot make it hot reload.
