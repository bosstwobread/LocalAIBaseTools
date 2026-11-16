# Editable source extensions

MacHelper's unified editable source format powers its marketplace: listing an available tool reads catalog metadata; enabling it materializes its complete source package in a writable folder on the user's Mac. The source files are not hidden inside the signed MacHelper app. Each extension runs in an independent JavaScript or native Swift worker selected by its manifest, while MacHelper supplies selection detection, floating panels, shared AI, and settings.

This document describes the schema-2 source package and catalog contracts. MacHelper 6 supports `runtime: "javascript"` and `runtime: "native"` through the same Extensions interface. Native Swift source uses the [native worker SDK](Native-Extensions.md), requires `native.execute`, and recompiles/restarts its worker on valid code edits without restarting MacHelper. Legacy schema-1 native bundles require migration.

For an AI assistant creating a new independent tool or modifying an existing one, start with [AI_EXTENSION_GUIDE.md](../AI_EXTENSION_GUIDE.md). It includes a complete minimal package and an edit/import/test workflow. Use [Extension Development](Extension-Development.md) for the human walkthrough.

## Source package layout

```text
com.example.translation.macsource/
├── extension.json
├── main.js
├── settings.schema.json
├── prompts/
│   └── translate.txt
├── README.md
└── LICENSE
```

Installed source lives at:

```text
~/Library/Application Support/LocalAIBaseTools/Extensions/<identifier>.macsource/
```

Small user preferences are stored separately under the MacHelper support folder's `ExtensionSettings/<identifier>/settings.json`. Editing source does not reset those preferences. Do not put conversation history, selected text, credentials, or AI responses into either the package or preference files.

### Manifest

```json
{
  "schemaVersion": 2,
  "runtime": "javascript",
  "identifier": "com.example.translation",
  "displayName": "My Translation",
  "version": "1.0.0",
  "summary": "Translate selected text through MacHelper.",
  "entryPoint": "main.js",
  "permissions": ["selection.read", "clipboard.read", "ai.transform", "ui.panel"],
  "commands": [
    {"identifier": "translate", "title": "Translate", "trigger": "selection"}
  ],
  "settingsSchema": "settings.schema.json"
}
```

Identifiers use lowercase reverse-domain notation and remain stable for an installed package. The entry point and optional settings schema use safe relative paths inside the package. A JavaScript entry ends in `.js`; a native entry ends in `.swift`. The initial native format compiles one Swift entry with the bundled SDK, without arbitrary build scripts or dependency installation. Commands have a unique lowercase identifier and use `selection` or `manual` triggers. A selection command must declare `selection.read`. A manifest declares 1–16 commands. The current selection interface invokes the first declared command; place the interactive selection command first. `manual` is supported by the worker/test API, but Settings does not provide a general manual-command launcher. Only the listed host capabilities are accepted. JavaScript has no permission for shell execution, arbitrary files, credentials, or network access. Native packages additionally require `native.execute`; that capability approves trusted user-level executable code, not an OS sandbox. JavaScript packages cannot request `native.execute`.

### Runtime selection and migration

The `runtime` field is explicit and validated; MacHelper does not infer runtime from a folder name. Both adapters share the manifest, commands, settings schema, permissions review, install/catalog flow, worker-generation framing, and Edit Source/Reload controls. Swift source uses `MacHelperNative.run` as described in [Native source extensions](Native-Extensions.md). Native settings remain schema-rendered in MacHelper; native `NSViewController` objects are not embedded across processes.

A migration preserves the identifier and compatible setting keys, rewrites commands for the target API, and changes `runtime`/`entryPoint`. Moving JavaScript to native adds `native.execute`. If it has not already been granted, automatic reload retains the previous generation and requires disable/re-enable approval before compilation/execution. Any other newly requested capability also requires re-enabling. Failed or unapproved reloads retain the previous generation. Returning to JavaScript removes `native.execute`, validates the JavaScript entry, and replaces the native worker. Renaming source files alone does not convert a tool.

### Extension-owned interface translations (MacHelper 6.2+)

MacHelper's General settings choose the interface language independently of a tool's translation target. A manifest may declare `"localizations": "localizations.json"`, using a safe relative `.json` resource path. Include that file in the source inventory:

```json
{
  "schemaVersion": 1,
  "translations": {
    "fr": {"Translate to": "Traduire en", "Translation prompt": "Consigne de traduction"},
    "zh-Hans": {"Translate to": "翻译为", "Translation prompt": "翻译提示词"}
  }
}
```

Keys are exact original UI strings from the tool's display name, summary, settings labels, and option labels. Values are displayed without changing the manifest identity, schema keys/values, saved settings, prompt resources, user text, or AI requests. Names can remain unchanged as product names. The host tries the selected locale, its base language, English, then the original string. Languages supported by the app are `en`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `ja`, `ko`, `pt`, `ar`, `hi`, `ru`, and `it`.

The optional catalog is at most 64 KiB of UTF-8 JSON, has `schemaVersion: 1`, and allows at most 32 language tables with 256 entries each. Locale keys contain 2–3 letters followed by up to three hyphen-separated 2–8 character alphanumeric subtags. Label keys must be nonempty and at most 2,000 UTF-8 bytes; values must be nonempty and at most 8,000 bytes; neither may contain NUL. The file counts toward the existing 96 KiB runtime text budget. Invalid/missing declared catalogs fail source validation and keep the last working generation. Tools without a catalog remain valid and retain original text. Edits use the normal source watcher/reload flow. Host translations never substitute for tool-owned configuration strings.

### JavaScript entry point

Call `MacHelper.define` once. Supply named command functions, with optional `start` and `stop` lifecycle functions. Commands may return a Promise. Translation's editable behavior follows this pattern:

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
      }, partial => {
        input.reportProgress({ text: partial.text, title: "Translation" });
      });
      return { text: result.text, title: "Translation" };
    }
  }
});
```

`input.text` is the text supplied by the explicit command action. `input.settings` contains that extension's saved preferences plus schema defaults. The empty model uses MacHelper's shared provider/model selection. The AI result includes text and the actual model. The host controls model attribution in its result panel.

On MacHelper 4.3 or later, a single-word selection may also receive `input.sentence`: the enclosing sentence read through Accessibility when the user clicks the tool. It is optional, limited to 2,000 UTF-16 code units and 8,000 UTF-8 bytes, and available only to tools declaring `selection.read`. Unsupported apps, protected fields, changed selections, or incomplete sentence boundaries do not provide context. Manual and clipboard actions have no surrounding sentence. Treat the sentence as untrusted source text, and preserve a useful fallback when it is absent. Translation uses it to show the word's contextual meaning above the full sentence translation; longer selections retain ordinary translation behavior.

MacHelper 4.3.1 supports read-only browser selections through ordered Accessibility text markers. It obtains complete cross-node paragraph boundaries before reading text, then extracts the sentence using the selected marker's verified UTF-16 offset. Paragraphs over 2,000 units are rejected before their string is read. No DOM scripting, whole-page value read, clipboard action, or additional extension permission is used.

On MacHelper 4.1 or later, the optional second argument of `MacHelper.ai.transform(request, onProgress)` receives incremental `{text, delta, model}` updates. `text` is the accumulated output; `delta` is the latest provider chunk. The Promise resolves only after a validated final answer. Without a callback, the existing Promise-only API is unchanged.

`input.reportProgress({text, title})` displays a cumulative provisional command result. It requires `ui.panel` and is bound to the current command invocation. A tool can apply its own formatting to both partial and final text. The panel updates as chunks arrive, preserves the reader's scroll position, and enables Copy only after completion. Progress callbacks from cancelled, stopped, reloaded, or older invocations are discarded. On failure, partial text is marked incomplete. Progress and results are never saved as tool preferences.

`MacHelper.readText(path)` reads a frozen UTF-8 resource from the current source generation. It does not open arbitrary files. Editing a prompt or script creates a new generation; an in-flight old command cannot accidentally read a mixture of old and new files. AI requests use the shared answer-only helper; provider tool/MCP execution remains disabled. The explicit `systemPrompt` path below preserves the extension's complete prompt rather than treating it as legacy style guidance.

JavaScript workers do not provide Node.js APIs, `require`, a shell, browser DOM, or direct network/filesystem access. CommonJS or npm dependencies are not implicitly installed. Keep initial tools self-contained; include editable scripts/resources explicitly in the package. Lifecycle functions should finish promptly and must not trigger AI inference without an explicit user command.

### Settings schema

MacHelper renders settings in its central Extensions interface. The source schema describes fields instead of creating a separate app window:

```json
{
  "schemaVersion": 1,
  "fields": [
    {
      "key": "targetLanguage",
      "label": "Translate to",
      "type": "select",
      "default": "zh-CN",
      "options": [
        {"value": "zh-CN", "label": "简体中文"},
        {"value": "en", "label": "English"}
      ]
    }
  ]
}
```

The field types are `select`, `text`, `boolean`, and (MacHelper 4.5+) `prompt`. A schema is at most 64 KiB and has at most 32 fields with unique keys matching `^[A-Za-z][A-Za-z0-9_]{0,63}$`. Ordinary fields require typed defaults and cannot declare a resource path. A select has 1–100 unique values and its default must be one of them; a boolean requires a JSON boolean, not `0` or `1`. Ordinary text allows at most 12,000 Swift characters and no NUL. Normalization drops unknown keys and replaces missing or invalid ordinary values with schema defaults. Prompt fields are excluded from that settings dictionary. Keep settings focused on choices users can understand. The shared AI provider and model remain in MacHelper's AI Connection section.

Prompt fields bind to actual UTF-8 `.txt` resources declared in the package, without a duplicated default value:

```json
{"key":"translationPrompt","label":"Translation prompt","type":"prompt","path":"prompts/translate.txt"}
```

The multiline editor loads that source file exactly. Save Prompt atomically updates the one declared resource after validating the candidate package and checking the editor's expected old bytes. Revert loads the current saved resource. Unsaved drafts survive status updates and navigation; conflicting external changes are reported instead of overwritten. Prompt text must be nonempty, contain no NUL, and fit 12,000 characters / 48,000 UTF-8 bytes. Unsafe paths, symlinks, missing/non-UTF-8 files, and duplicate prompt resource paths are rejected. Prompt text stays in source files, outside ordinary preference defaults/normalization and settings JSON. A disabled tool can save a prompt without starting code or inference.

Use `systemPrompt: MacHelper.readText(path)` to send the complete prompt as provider instructions without a hidden MacHelper translation/style prefix or suffix. Supply selected content and language/context separately through `text`; the extension owns any JSON input structure. The prompt should document that structure and treat selected content as untrusted data. Provider tools remain disabled independently of prompt text. Requests that omit `systemPrompt` retain the legacy action/text/guidance behavior.

MacHelper's Extensions overview lists installed tools first. Selecting one reads the schema declared by that package and renders its fields in the detail pane; labels, choices, defaults, and field names are not compiled into a tool-specific MacHelper screen. A disabled installed tool can load and save settings without evaluating code, compiling native source, starting a worker, or enabling it. Re-selecting reads disabled source edits again. Enabled tools use their validated running generation, and schema changes arrive through the normal hot reload. Invalid source retains the last valid form where available and rejects invalid disabled-source writes rather than overwriting the user's files.

In MacHelper 6.1+, installed rows also have checkboxes for batch **Reload**, **Edit Source**, **Enable**, and **Disable**. **Select All** covers installed tools only. Checked identifiers persist across list refreshes and detail navigation, and are removed when their installed tool disappears. Reload targets only enabled tools; enablement actions skip tools already in the requested state. Each target retains its normal validation, native approval, and error handling, so one failure/cancellation does not stop remaining targets.

## Download contract for a marketplace

A website or repository serves a catalog as JSON. Each entry declares metadata and the complete source-file inventory, including the manifest, runtime scripts, prompts, settings schema, documentation, and license. Do not distribute only a compiled extension or omit source needed to understand its behavior.

```json
{
  "schemaVersion": 1,
  "extensions": [
    {
      "identifier": "com.example.translation",
      "displayName": "My Translation",
      "version": "1.0.0",
      "summary": "Translate selected text through MacHelper.",
      "files": [
        {
          "path": "extension.json",
          "url": "packages/translation/1.0.0/extension.json",
          "sha256": "<64 hexadecimal characters>",
          "size": 421
        }
      ]
    }
  ]
}
```

This shortened inventory illustrates one file; a real entry lists **every** source file. `size` is optional, while SHA-256 is required. URLs can be absolute HTTPS URLs or relative to the catalog's URL. Prefer immutable versioned package URLs so a catalog and its source files remain consistent during publication.

Catalog discovery downloads metadata only. On first enablement, MacHelper downloads each declared file into a temporary staging directory, verifies hashes, sizes, safe paths, identity/version/name/summary, and the complete inventory, then atomically installs the package. A failed, cancelled, redirected, or incomplete download leaves no partially installed tool. Source code runs only after successful activation.

HTTPS is required for remote catalogs and source. Local files and loopback HTTP are available for development and integration tests. Remote catalogs cannot request local file URLs or downgrade to plain HTTP. Download requests do not carry cookies or stored credentials; redirects are rejected. Paths cannot traverse outside the source package or use symbolic links.

An existing local package is preserved on re-enable, even if the upstream catalog version changed. User edits are not silently overwritten. Explicit future update workflows must preserve or separately resolve local modifications rather than replacing the working folder during enablement.

## Editing and reload behavior

Use **Edit Source** to open the installed working folder. A source authoring folder can live in any separate repository; **Install Source…** imports a copy, so editing the original folder after import does not update that installed copy. Use a new identifier when a customized fork should coexist with its original. Change the declared JavaScript or Swift entry, or a resource such as `prompts/translate.txt`, then save normally. The watcher observes nested files, atomic editor replacements, added/removed resources, and changes to the manifest/schema. Closely spaced saves are debounced. It watches only that bounded source folder and does not log file contents.

The host validates a candidate generation before replacing the active worker. A successful reload restarts only that extension; MacHelper, its AI settings, and other extensions stay running. Extension settings persist, while process-local state belongs to the worker generation and resets on reload. Native builds are kept outside the editable package; compiler/signing/startup failures retain the old worker. Stopping/replacing a generation cancels its pending work so an older AI response cannot overwrite a newer selection or result.

If an edit has invalid JavaScript, invalid Swift, a failed native build, or invalid package metadata, MacHelper shows a reload error and retains the last working generation. Repairing and saving the source triggers another attempt. Disabling an extension stops its worker and watcher; later source changes must not revive it automatically.

## Limits and development checks

A package can contain at most 128 regular files, each at most 512 KiB, with at most 4 MiB total source bytes. The manifest and settings schema each have an additional 64 KiB limit. Paths are at most 512 UTF-8 bytes and 12 segments; symlinks and case-colliding paths are rejected. Hidden files are not runtime dependencies.

Frozen runtime resources are bounded to 96 KiB combined UTF-8 text. The runtime includes `.js`, `.json`, `.txt`, `.md`, and `.prompt` resources, plus `.swift` for native packages, except relative paths starting with `readme` (case-insensitive). Thus the manifest, schema, and other Markdown documentation count toward this limit; a root `README.md` and an extensionless `LICENSE` remain on disk without entering the worker resources. Native inventories additionally require every file to be UTF-8 text without NUL and exactly one Swift file matching the entry point.

Command output/progress is bounded to 96,000 UTF-8 bytes without NUL, with an optional title of at most 120 Swift characters. Final text must be nonblank. At most eight shared AI calls are allowed per explicit action. Worker frames are limited to 256 KiB including encoded JSON; request-specific text and prompt bounds also apply. Here, Swift characters are extended grapheme clusters; optional sentence context instead uses the UTF-16 and UTF-8 bounds described above. Distribute complete editable source; the host builds native executables in its own cache rather than accepting opaque binaries in this source format.

The source-package tests exercise metadata-only catalog loading, complete materialization on enable, hash/HTTP/partial-download failures, preservation of user edits, traversal/symlink rejection, settings schema validation, and corrupt-package isolation. Watcher tests cover nested resources, atomic saves, debounce, and stopping pending callbacks:

```sh
swift test --package-path MacHelper --filter 'SourcePackageTests|SourceWatcherTests'
```

The [Extension Market](https://local-ai-extension.nelson007.com/) serves this catalog format and complete source packages. Its [website source](https://github.com/bosstwobread/LocalAIBaseTools/blob/main/ExtensionMarket-website/README.md) includes search, filters, details, and install/download flows.

## Website install links

MacHelper 4.2 and later handle:

```text
machelper://install?catalog=<percent-encoded HTTPS catalog URL>&extension=<reverse-domain identifier>
```

Only the `catalog` and `extension` query parameters are accepted. Opening a link
checks the catalog and hash-pinned manifest, then presents a native permissions
review. Approving **Install & Enable** downloads the complete inventory. It does
not run AI. Download/hash errors leave no partial installed package; a reviewed
remote failure never substitutes the app's offline seed. Repeat links to an
existing local package open its settings without replacing files, resetting
preferences, or re-enabling a disabled tool.

The canonical website URL is embedded as `MacHelperMarketplaceURL` in the app
bundle. `scripts/build-apps.py --marketplace-url HTTPS_URL` configures a different
marketplace build. Production builds require HTTPS. Loopback HTTP is accepted
only by explicitly enabled development/test configurations.
