# Editable source extensions

MacHelper's JavaScript extension format is designed for a future marketplace: listing an available tool reads catalog metadata; enabling it materializes its complete source package in a writable folder on the user's Mac. The source files are not hidden inside the signed MacHelper app. Each extension runs in its own JavaScript worker, while MacHelper supplies selection detection, floating panels, shared AI, and settings.

This document describes the version-two source package and catalog contracts. Native version-one bundles remain a separate SDK interface; replacing already-loaded native code still requires restarting the app.

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

Identifiers use lowercase reverse-domain notation and remain stable for an installed package. The JavaScript entry point and optional settings schema use safe relative paths inside the package. Commands have a unique lowercase identifier and use `selection` or `manual` triggers. A selection command must declare `selection.read`. Only the listed host capabilities are accepted; there is no script permission for shell execution, arbitrary files, credentials, or network access.

### JavaScript entry point

Call `MacHelper.define` once. Supply named command functions, with optional `start` and `stop` lifecycle functions. Commands may return a Promise. Translation's editable behavior follows this pattern:

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
      return { text: result.text, title: "Translation" };
    }
  }
});
```

`input.text` is the text supplied by the explicit command action. `input.settings` contains that extension's saved preferences plus schema defaults. The empty model uses MacHelper's shared provider/model selection. The AI result includes text and the actual model. The host controls model attribution in its result panel.

`MacHelper.readText(path)` reads a frozen UTF-8 resource from the current source generation. It does not open arbitrary files. Editing a prompt or script creates a new generation; an in-flight old command cannot accidentally read a mixture of old and new files. Source text and guidance are sent through the same answer-only AI helper. Tools remain disabled.

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

The current field types are `select`, `text`, and `boolean`. Keep settings focused on choices users can understand. The shared AI provider and model remain in MacHelper's AI Connection section.

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

Use **Edit Source** to open the installed working folder. Change `main.js` or a resource such as `prompts/translate.txt`, then save normally. The watcher observes nested files, atomic editor replacements, added/removed resources, and changes to the manifest/schema. Closely spaced saves are debounced. It watches only that bounded source folder and does not log file contents.

The host validates a candidate generation before replacing the active worker. A successful reload restarts only that extension; MacHelper, its AI settings, and other extensions stay running. Extension settings persist, while ordinary JavaScript variables belong to the worker generation and reset on reload. Stopping/replacing a generation cancels its pending work so an older AI response cannot overwrite a newer selection or result.

If an edit has invalid JavaScript or package metadata, MacHelper shows a reload error and retains the last working generation. Repairing and saving the source triggers another attempt. Disabling an extension stops its worker and watcher; later source changes must not revive it automatically.

## Limits and development checks

A package can contain at most 128 files, each at most 512 KiB, with at most 4 MiB total downloaded bytes. Frozen runtime scripts/resources sent to the worker are bounded to 96 KiB of UTF-8 text. Documentation and license files are retained on disk; they do not need to cross the worker protocol. Worker protocol framing and execution deadlines impose additional bounds. Keep small tools small and split reusable native capabilities into MacHelper rather than bundling opaque binaries.

The source-package tests exercise metadata-only catalog loading, complete materialization on enable, hash/HTTP/partial-download failures, preservation of user edits, traversal/symlink rejection, settings schema validation, and corrupt-package isolation. Watcher tests cover nested resources, atomic saves, debounce, and stopping pending callbacks:

```sh
swift test --package-path MacHelper --filter 'SourcePackageTests|SourceWatcherTests'
```

Catalog JSON is a download/activation interface for the future marketplace; it is not a marketplace website, account system, or payment implementation.
