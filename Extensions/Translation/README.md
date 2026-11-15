# Translation — editable source extension

This folder contains the complete source of the Translation tool. It is JavaScript plus a prompt, a settings schema, and a manifest; no compiler or separate app is needed to edit its behavior.

Enable Translation in MacHelper → Extensions. MacHelper installs the complete package into its per-user Extensions folder. **Edit Source** opens that working folder in VS Code when available. Save a change to `main.js`, `prompts/translate.txt`, or `settings.schema.json` and only Translation reloads. The MacHelper app and other tools stay running.

- `main.js`: selected-text handling, AI request, and result formatting.
- `prompts/translate.txt`: translation guidance.
- `prompts/word-in-context.txt`: selected-word meaning and supplied-sentence translation guidance.
- `settings.schema.json`: editable central settings form and defaults.
- `extension.json`: identity, commands, runtime, and declared capabilities.
- `LICENSE`: MIT license for this source package.

`MacHelper.define` registers the tool. `MacHelper.readText` reads frozen package resources. `MacHelper.ai.transform` calls the shared AI helper only during an explicit tool action. The native MacHelper platform handles Accessibility, floating icons/results, cancellation, and clipboard actions.

With MacHelper 4.1 or later, Translation shows text as the provider generates it. The second callback passed to `MacHelper.ai.transform` receives cumulative partial text and forwards it through `input.reportProgress`. Customize both that callback and the returned final result if adding a prefix or changing formatting. Copy becomes available after completion. Cancelling, changing selection, or reloading prevents old chunks from appearing; a failed stream is clearly marked incomplete.

With MacHelper 4.3 or later, selecting one lexical word can also provide the optional `input.sentence`. Translation makes one streamed AI request containing a JSON data object with `selectedWord` and `surroundingSentence`. The result explains the word's meaning in that supplied context first, with the full sentence translation below it. Section labels and output use your configured target language. Contractions and hyphenated words are supported; CJK and other unspaced-script selections use word segmentation when available so an entire phrase does not become a word lookup. Word lookup is limited to 128 UTF-16 units; longer selections use the normal translation path.

If the app cannot expose a surrounding sentence, or the supplied context is invalid, too large, or does not contain the selected word, `surroundingSentence` is `null`. The tool returns a general word meaning and appends an honest note in the configured language. It never invents a sentence for this fallback. Context is bounded to 2,000 UTF-16 units and 8,000 UTF-8 bytes. The word, sentence, and any instructions inside them remain untrusted data; the existing answer-only, tool-disabled AI connection is unchanged. Selecting multiple words keeps the original translation behavior.

This behavior is editable in `main.js`, including word detection, localized labels, and the context-unavailable notes. Edit `prompts/word-in-context.txt` to change how contextual meanings and sentence translations are explained. The native platform supplies optional context; translation policy lives in this source tool.

A reload starts a fresh worker after the new script validates. Syntax errors keep the previous working version active and appear in Settings. Settings live separately from source, and downloading a newer package does not overwrite local edits. New permissions require explicit re-enabling.

For a quick test, change the returned result to `{text: "译文：" + response.text, title: "My Translation"}` and save. Restore the original line to return to the normal result. Press Esc or click elsewhere to dismiss a translation.

The marketplace-ready catalog format lists every package file and its SHA-256. A remote catalog can be served by a future website; MacHelper lists its metadata first and downloads source when the user enables a tool. See `docs/Source-Extensions.md` in the main repository for the protocol.
