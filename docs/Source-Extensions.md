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
  "permissions": ["selection.read", "ai.transform", "ui.panel"],
  "commands": [
    {"identifier": "translate", "title": "Translate", "trigger": "selection", "systemSymbolName": "character.bubble"}
  ],
  "settingsSchema": "settings.schema.json"
}
```

Identifiers use lowercase reverse-domain notation and remain stable for an installed package. The entry point and optional settings schema use safe relative paths inside the package. A JavaScript entry ends in `.js`; a native entry ends in `.swift`. The initial native format compiles one Swift entry with the bundled SDK, without arbitrary build scripts or dependency installation. Commands have a unique lowercase identifier and use `selection` or `manual` triggers. A selection command must declare `selection.read`. A manifest declares 1–16 commands. On MacHelper 6.6+, one shared toolbar lists all enabled source commands whose trigger is `selection`, using the command titles; the chosen action invokes that exact command in its owning worker. `manual` is supported by the worker/test API, but Settings does not provide a general manual-command launcher. Only the listed host capabilities are accepted. JavaScript has no permission for shell execution, arbitrary files, credentials, or network access. Native packages additionally require `native.execute`; that capability approves trusted user-level executable code, not an OS sandbox. JavaScript packages cannot request `native.execute`.

### Shared toolbar and guarded replacement (MacHelper 6.6+)

The shared toolbar uses every enabled tool’s `selection` command, rather than separate overlapping icons. Selection must be verified and nonempty. Displaying the toolbar does not invoke code or AI. Each selected command uses the current validated extension activation and normal cancellation/stale-result checks.

One host coordinator owns the toolbar and active result panel. Placement stays within screen bounds. MacHelper shows separate icon cells in one horizontal row, with gaps that keep their click areas from overlapping. All actions appear when there are five or fewer; with more than five, four action icons and an ellipsis lead to **More…**, a native scrolling menu containing the remaining command names. There is no five-extension installation limit. Each extension keeps independent source, worker, settings, and prompt resources.

MacHelper uses fixed Accessibility routes: an app-scoped mouse hit, application focus, system focus whose anchor belongs to the original application PID, then focused/main window and application selection providers. Captured intermediate focus nodes may be queried even when a provider does not link them back through `AXParent`; arbitrary descendants are never crawled. Each candidate checks at most eight parent-chain nodes, including its anchor. An evaluated blocked focus proof stops later, broader fallbacks; an independently verified earlier route can return before unused roots are queried. Separate hit/focus time slices share an approximately 2.4-second capture budget.

Numeric ranges belong to their exposing control. Missing/empty `AXSelectedText` may use `AXStringForRange` for that control's own verified positive selected span only. If the plain range representation is unsupported/absent, `AXAttributedStringForRange` may supply plain text for the identical range; malformed data cannot trigger that fallback. Exactly one valid plural range may be used if the singular attribute is unavailable. With no numeric range, a same-element selected-marker range can provide read-only text even without `AXSelectedText`, after ordered positive-length and repeated exact text/range/protection/context checks. An explicit caret or invalid numeric range never falls back to markers. The host revalidates source process/launch, source element, ancestry and exact hit/focus/window/application origin. No full-document/value capture, macOS Services, OCR, or screen-reading permission is added. MacHelper 6.7 also supports the guarded automatic Copy fallback below. Reading never authorizes editing: Apply still independently requires the exact original focused editable target and numeric range.

MacHelper 6.7 may make one fixed Copy attempt only after a recognized selection gesture when Accessibility cannot read that selection. It automatically snapshots every readable clipboard item/type in memory under size and stability limits, copies, accepts only newly copied nonempty text, and conditionally restores the snapshot while the clipboard state still belongs to that attempt. The host prefers the original process’s enabled Copy menu item, found through a bounded menu-only lookup; otherwise it may use a fixed, host-tagged Command-C pair.

Before any Copy attempt, the host can retry preparation at most three times within the unchanged gesture context, allowing a briefly unavailable menu or clipboard to settle. It waits for 60 milliseconds of clipboard quiet before snapshotting and uses a 0.5-second snapshot budget. These are preparation retries only: once Copy has been attempted, there is no second Copy for that gesture. A changed context or user clipboard intent cancels preparation. There is no manual enable switch and no Copy from ordinary clicks, app activation, or polling. Protected fields, explicit carets, invalid evidence, stale contexts, and unreadable/oversized snapshots block the attempt. A later clipboard change or user Copy intent prevents restoration over that new content. No arbitrary keyboard or clipboard API is exposed to extensions.

Capture-only text supplies no numeric editing proof or sentence context: tools may preview and offer result Copy. Clipboard text alone never grants editing access. At an explicit tool click, MacHelper may independently reread Accessibility and recover editing eligibility only from matching text, the source control’s own positive numeric range and origin, and an unchanged original gesture/process/focus/window context. The normal editable-target and Apply checks still run. If MacHelper cannot verify either an exact edit target or an eligible Paste menu target, Apply stays disabled. The completed preview offers Copy and explains why. Translation remains read-only. Coverage and preservation are best effort; unavailable/lazy formats and clipboard-history observers prevent a universal no-impact guarantee. Extensions must not implement their own Copy capture, whole-document read, or per-app bypass.

Pressing Command hides only the idle toolbar and suppresses selection publication while held. Releasing Command alone does not reopen it. A recognized keyboard selection such as Command-A is latched on key-down and published after both its key and Command are released when still current, whichever is released first. The modifier alone does not dismiss a working or completed result panel. Existing outside-click, new-selection, app-switch, owner-activation and language invalidation rules remain in effect.

Mouse selection intent is latched at mouse-down for double/triple-click and Shift-click, and a selection indication from either edge is retained. Gesture completion commits a fresh read context, invalidating an older pending read before it can consume the new Copy preparation. Double-click, triple-click and Shift-click schedule their first Accessibility read 0.12 seconds after release. Copy becomes eligible 0.35 seconds after release. A double-click also waits until the system double-click interval has elapsed from the second mouse-down so a third click can supersede it. Each completed gesture supersedes older reads. Drag and keyboard reads keep their 0.14-second delay. The same deadlines apply to scheduled reads and polling. A new mouse gesture reads its own Command flag so a missed modifier transition from an earlier gesture cannot leave the toolbar suppressed. After Copy, a timed-out Accessibility source check permits bounded revalidation of that same gesture and source. MacHelper issues no additional Copy, and a confirmed source change discards the capture.

Commands may provide an optional `systemSymbolName` containing an SF Symbols name, such as `character.bubble` or `pencil.and.outline` (MacHelper 6.6.1+). It controls presentation only and grants no capability. When omitted, the host uses a pencil for a tool with `selection.replace`, or a character bubble for a read-only tool. An unavailable symbol falls back to a generic extension icon. Existing source packages need no edit or new version to use the default icons. Keep `title` and its source translations: the host uses them for tooltips, accessibility labels, and overflow menu items.

The current operation/result is associated with the owning extension’s immutable activation UUID (validated source/settings generation) and command identity. Successful activation/reload/re-enable assigns a new UUID. An internal worker recovery can retain that activation; worker IPC generations remain separately strict. Reconciling unrelated tool reloads, enablement, or disablement preserves that operation/result if its owner remains unchanged. Replacing/stopping that activation or removing its command invalidates it; stale output cannot cross generations. Selection changes and existing interface-language invalidation continue to dismiss the active work.

`selection.replace` is an optional manifest permission and requires `selection.read`. It approves host-managed plain-text replacement, not a new JavaScript or Swift SDK editing method. Return `{text, title}` and report progress normally. A valid completed result can enable **Apply** for either an exact edit target or the menu-based paste path described below. Partial/error output cannot be applied. Read-only tools such as Translation remain read-only without that permission. Optional `selection.paste` requires both `selection.read` and `selection.replace` and adds the two host-owned clipboard paths described below; it requires a separate permission review.

In editors such as VS Code, a read-only element can mirror the focused control’s selection using different local offsets. MacHelper requires matching selection markers at both ends and verifies that both endpoints belong to the focused editable control before using its own positive range and exact selected text.

For an exact-range edit, Apply revalidates the source PID/app, original focused AX element identity, exact selected text and numeric range, and enabled/nonprotected editable state. The host classifies the exact selected control through a read-only Accessibility parent chain bounded to 16 nodes and about 0.8 seconds. An `AXWebArea` ancestor identifies a web editor, including supported embedded Electron/WebKit editors, and selects approved paste before any write even when `AXSelectedText` is advertised writable. Reaching an `AXWindow` or `AXApplication` without a web ancestor identifies a native control, which prefers direct selected-text editing. Missing roles/parents, cycles, or protection block editing and retain Copy. Reaching the depth/deadline limit leaves classification unknown; only approved paste is then eligible, with strict positive editable-field evidence and every original focus/range/text/permission check. Unknown classification never permits a direct setter. Routing uses no browser/app allowlist. There is no whole-field `AXValue` write or reconstruction of unselected text. Both partial and full numeric selections may be eligible; unsupported/read-only/protected fields retain manual **Copy**.

For a web editor, an eligible depth/deadline-limited unknown control, or a verified native control where direct writing is unavailable, approved `selection.paste` lets MacHelper write the completed result plus a private ownership stamp to the clipboard. This Apply transaction never reads, snapshots, or restores previous clipboard contents, and the result intentionally stays there; automatic selection capture is a separate host operation. It revalidates the original target and its own pasteboard change count/stamp immediately before posting fixed Command-V key-down/up to the original PID. Target or clipboard ownership changes abort dispatch. The Apply path does not activate the app, force focus/ranges, synthesize Copy/Enter/Send, reconstruct field values, or expose arbitrary keyboard/clipboard methods to extension code. A failed direct write never starts an automatic paste retry.

The permission review covers both clipboard methods behind **Apply**: the paste shortcut for an exact range and the original editor’s Paste menu command for its current selection. Both leave the result on the clipboard. Neither edit reads or restores the previous clipboard contents. Adding `selection.paste` to an enabled tool requires renewed approval. Each edit requires a completed preview and a click on Apply.

The shared **General → Improve compatibility with Electron apps** preference is off by default. With it enabled, the host tries a bounded Accessibility read after a recognized selection gesture. If the selection is still unreadable, the host may set the application's advertised, settable `AXManualAccessibility` attribute to `true`. It requires a verified focused AX window and tracks its identity with the process launch. MacHelper skips the request when the window cannot be identified. A distinct window in the same process can recover within the per-process and host limits. A handshake permits one initial request and at most one refresh after 2.2 seconds. The refresh checks the same process and window, the current selection context, Accessibility trust, settable support, and opt-in. After an interruption, another deliberate selection in the same window may resume its outstanding refresh at the original deadline. Polling alone cannot start or resume the handshake.

VS Code may enter Screen Reader Optimized mode, affecting folding and the minimap. Users may need to reselect the text if their first gesture occurred before the editor exposed it. Disabling compatibility stops future requests. Affected apps may need restarting. MacHelper leaves VS Code settings files, VoiceOver and macOS permissions alone. Extension code receives the ordinary selection capability. Editing still requires a verified target.

A direct setter/paste dispatch is not insertion proof. The host reports “Selected text replaced.” only for exact bounded read-back where available. Otherwise it reports a requested paste/edit or asks the user to check the original app; editor-altered text is not confirmed as exact. Apply is disabled after the attempt, Copy remains available, and there is no automatic retry/rollback. Plain-text formatting, Undo, and verification depend on the editor.

**Apply** can use the original editor’s Paste menu command for a clipboard-captured selection without an exact Accessibility range. This path requires the tool’s approved `selection.paste`, a completed result, the original selection gesture, process, window and available focus anchors, and a standard enabled Cut command. After the click, MacHelper stages the result with the original boundary whitespace, checks the window, edit commands and its clipboard ownership again, and requests the app’s standard Paste menu action once. Cut is never invoked. This targets the current selection in the original window. The host cannot distinguish two identical text spans by document offset in this mode. A changed target or missing permission leaves Copy available. The result stays on the clipboard.

After an Apply attempt, the button keeps its label and becomes disabled. The status reports the outcome, and the completed preview remains available to copy. Explicit dismissal or an outside click, a new selection gesture, switching apps, or replacing/disabling the owning activation clears that retained preview. This is an exception for edit/paste-caused polling updates, not permission to retain stale work after a new user selection; interface-language invalidation is unchanged.

Newly adding this permission requires the normal disable/re-enable approval; existing read access does not imply write access. Polish-input uses this permission while keeping its complete prompt, settings, and polishing logic in its own source folder. The host capability is independent of extension identifiers and does not hard-code polishing instructions.

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

Keys are exact original UI strings from the tool's display name, summary, command titles, settings labels, and option labels. Values are displayed without changing the manifest identity, schema keys/values, saved settings, prompt resources, user text, or AI requests. Names can remain unchanged as product names. The host tries the selected locale, its base language, English, then the original string. Languages supported by the app are `en`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `ja`, `ko`, `pt`, `ar`, `hi`, `ru`, and `it`.

The optional catalog is at most 64 KiB of UTF-8 JSON, has `schemaVersion: 1`, and allows at most 32 language tables with 256 entries each. Locale keys contain 2–3 letters followed by up to three hyphen-separated 2–8 character alphanumeric subtags. Label keys must be nonempty and at most 2,000 UTF-8 bytes; values must be nonempty and at most 8,000 bytes; neither may contain NUL. The file counts toward the existing 96 KiB runtime text budget. Invalid/missing declared catalogs fail source validation and keep the last working generation. Tools without a catalog remain valid and retain original text. Edits use the normal source watcher/reload flow. Host translations never substitute for tool-owned configuration strings.

The catalog translates host-rendered labels. Keep app artwork localized in the tool’s runtime resources when it contains visible text. Keep website-only preview copy and assets in `marketplace/`; these stay outside the MacHelper install inventory. Provide localized captions and accessible descriptions, and check that long and right-to-left strings fit. Language switches update presentation without changing user content or contacting AI.

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

On MacHelper 4.3 or later, a single-word selection may also receive `input.sentence`: the enclosing sentence read through Accessibility when the user clicks the tool. It is optional, limited to 2,000 UTF-16 code units and 8,000 UTF-8 bytes, and available only to tools declaring `selection.read`. Unsupported apps, protected fields, changed selections, or incomplete sentence boundaries do not provide context. Manual command inputs have no surrounding sentence. Treat the sentence as untrusted source text, and preserve a useful fallback when it is absent. Translation uses it to show the word's contextual meaning above the full sentence translation; longer selections retain ordinary translation behavior.

The old `clipboard.read` permission name remains accepted so previously published source packages still load. The current source host provides no clipboard-input action or JavaScript clipboard reader; new tools should omit this declaration. Automatic fallback capture is a guarded host implementation of selection reading, not a clipboard capability granted to workers. The floating result's explicit Copy button writes a completed answer and remains supported.

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

## Public discovery metadata (MacHelper 6.3)

New tools provide a root `discovery.json` beside `extension.json` or a browser `manifest.json`. Marketplace publication requires it. It describes the tool for people, keyword filtering, and AI matching; it is separate from executable commands, settings schema, and the installation catalog. Older installed source packages still load without this publication metadata. Include it in every new published package's full hash inventory. Root `discovery.json` stays on disk and counts toward package download/file limits, but is excluded from the worker's 96 KiB resource channel.

```json
{
  "schemaVersion": 1,
  "description": "Translate selected text in supported Mac apps and read the result nearby.",
  "capabilities": ["Translate selected text through the shared AI connection"],
  "exampleQueries": ["Translate text while I read in a Mac app."],
  "keywords": ["translation", "selected text", "languages"],
  "limitations": ["Requires selectable text and macOS Accessibility permission."],
  "platforms": ["macOS"],
  "translations": {
    "zh-Hans": {
      "Translate selected text in supported Mac apps and read the result nearby.": "在支持的 Mac 应用中翻译选中文字，并在附近阅读结果。"
    }
  }
}
```

Schema 1 accepts only `schemaVersion`, `description`, `capabilities`, `exampleQueries`, `keywords`, `limitations`, `platforms`, optional `identifier`, optional `installSteps`, and optional `translations`. Unknown fields, blank strings, NUL, malformed types, symbolic links, and a non-regular descriptor are rejected by publication. The descriptor is at most **64 KiB** of UTF-8 JSON. Required arrays are nonempty.

| Field | Publication bounds |
| --- | --- |
| `description` | 4,000 UTF-16 units / 16,000 UTF-8 bytes |
| `capabilities` | 1–32 strings; each 1,000 UTF-16 units / 4,000 bytes |
| `exampleQueries` | 1–8 strings; each 1,000 UTF-16 units / 4,000 bytes |
| `keywords` | 1–32 strings; each 128 UTF-16 units / 512 bytes |
| `limitations` | 1–16 strings; each 1,000 UTF-16 units / 4,000 bytes |
| `platforms` | 1–8 strings; each 128 UTF-16 units / 512 bytes |
| Optional `installSteps` | 1–16 strings; each 2,000 characters / 8,000 bytes |
| Optional `identifier` | At most 128 UTF-8 bytes; `^[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*){1,7}$`. For browser tools this stable reverse-domain ID is distinct from the browser's 32-letter ID. |
| Optional `translations` | At most 32 locale maps, 256 exact-source-string mappings each; keys at most 2,000 UTF-8 bytes, values at most 8,000 bytes; neither empty nor containing NUL |

Text bounds use UTF-16 units plus UTF-8 bytes as shown; optional manual installation-step character counts use Unicode code points. Prefer ordinary text well below the limits. Locale names match `[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}`. Supply English originals and maps for the supported interface locales: `en`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `ja`, `ko`, `pt`, `ar`, `hi`, `ru`, and `it`. English can use the original text; missing translations fall back rather than invoking AI. These public description maps are separate from the manifest-declared `localizations` resource used by installed settings. Neither changes prompts, settings values, user input, or code.

Source identity/name/version/summary come from `extension.json`; browser name/version/summary come from `manifest.json`, with a stable discovery identifier supplied by the descriptor or publisher configuration. Indexed names are at most 256 UTF-8 bytes without control characters, versions at most 80 bytes matching `major.minor.patch` with an optional prerelease suffix, and summaries at most 2,000 UTF-16 units / 8,000 bytes. Stable identifiers follow the reverse-domain rule above. Do not claim unsupported capabilities or hide material limitations. Example queries describe realistic tasks, not instructions for the search model. Metadata edits do not alter executable behavior.

`ExtensionMarket-website/discovery.py` builds `discovery-index.json` and `discovery-manifest.json` independently of the Mac app. The source-free schema-1 index contains at most **10,000** unique IDs/slugs and **16 MiB**, including identity, summary, detailed descriptions, capabilities, examples, keywords, limitations, platforms, runtime/kind, and translation maps. The adjacent manifest advertises the index's revision, timestamp, exact size, and SHA-256. Runtime manifest reads are bounded to 8 KiB. MacHelper’s headless browser AI service checks this manifest first, verifies changed index bytes, caches a complete validated pair privately, and can use a verified cache/bundled release seed with a stale indication if refresh fails. It never fetches source merely to search. Invalid network metadata cannot replace the last verified index; updated public descriptions do not require a new app release.

The website offers keyword filtering and explicit description-based AI search. A valid **Find with AI** click connects to MacHelper 6.5’s loopback service when needed, obtains browser local-access approval if requested, and searches; shared **AI Connection** settings select the model. Invalid input makes no local request, and no separate connection button is needed. No browser extension is needed for this connection. At most 40 candidates and 160,000 bytes of ranking records are sent; for a larger index, AI first expands the query into up to eight terms and local lexical retrieval shortlists up to 40. The ranking payload may truncate descriptions/capabilities or omit records to fit, so matching is not guaranteed to be globally exhaustive. AI answers must contain at most five distinct known candidate IDs, readable reasons, and `good`/`partial` fits; unknown IDs or invalid answers fail validation. Query/metadata are untrusted, inference tools stay disabled, and no result installs or runs source code. The local website contract is described in [MacHelper Protocol](MacHelper-Protocol.md#website-local-discovery-machelper-65).

## Download contract for a marketplace

A website or repository serves a catalog as JSON. Each entry declares metadata and the complete source-file inventory, including the manifest, runtime scripts, prompts, settings schema, `discovery.json`, documentation, and license. Do not distribute only a compiled extension or omit source needed to understand its behavior.

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

Root `discovery.json` is publication metadata and is excluded from the runtime resource channel; it remains part of the complete source inventory.

## Limits and development checks

A package can contain at most 128 regular files, each at most 512 KiB, with at most 4 MiB total source bytes. The manifest and settings schema each have an additional 64 KiB limit. Paths are at most 512 UTF-8 bytes and 12 segments; symlinks and case-colliding paths are rejected. Hidden files are not runtime dependencies.

Frozen runtime resources are bounded to 96 KiB combined UTF-8 text. The runtime includes `.js`, `.json`, `.txt`, `.md`, and `.prompt` resources, plus `.swift` for native packages, except root `discovery.json` and relative paths starting with `readme` (case-insensitive). Thus the manifest, schema, and other Markdown documentation count toward this limit; root discovery metadata, a root `README.md`, and an extensionless `LICENSE` remain on disk without entering the worker resources. Native inventories additionally require every file to be UTF-8 text without NUL and exactly one Swift file matching the entry point.

Command output/progress is bounded to 96,000 UTF-8 bytes without NUL, with an optional title of at most 120 Swift characters. Final text must be nonblank. At most eight shared AI calls are allowed per explicit action. Worker frames are limited to 256 KiB including encoded JSON; request-specific text and prompt bounds also apply. Here, Swift characters are extended grapheme clusters; optional sentence context instead uses the UTF-16 and UTF-8 bounds described above. Distribute complete editable source; the host builds native executables in its own cache rather than accepting opaque binaries in this source format.

The source-package tests exercise metadata-only catalog loading, complete materialization on enable, hash/HTTP/partial-download failures, preservation of user edits, traversal/symlink rejection, settings schema validation, and corrupt-package isolation. Watcher tests cover nested resources, atomic saves, debounce, and stopping pending callbacks:

```sh
swift test --package-path MacHelper --filter 'SourcePackageTests|SourceWatcherTests'
```

The [Extension Market](https://local-ai-extension.nelson007.com/) serves this catalog format. New entries use direct commit-pinned GitHub HTTPS file URLs. The website retains previously published package files and ZIPs for older catalogs. The maintainer publishes new entries by reviewing a GitHub link to the extension folder at an exact commit. See the [publisher guide](https://github.com/bosstwobread/LocalAIBaseTools/blob/main/ExtensionMarket-website/README.md#publish-a-tool).

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
