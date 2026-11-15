# Translation — editable source extension

This folder contains the complete source of the Translation tool. It is JavaScript plus a prompt, a settings schema, and a manifest; no compiler or separate app is needed to edit its behavior.

Enable Translation in MacHelper → Extensions. MacHelper installs the complete package into its per-user Extensions folder. **Edit Source** opens that working folder in VS Code when available. Save a change to `main.js`, `prompts/translate.txt`, or `settings.schema.json` and only Translation reloads. The MacHelper app and other tools stay running.

- `main.js`: selected-text handling, AI request, and result formatting.
- `prompts/translate.txt`: translation guidance.
- `settings.schema.json`: editable central settings form and defaults.
- `extension.json`: identity, commands, runtime, and declared capabilities.
- `LICENSE`: MIT license for this source package.

`MacHelper.define` registers the tool. `MacHelper.readText` reads frozen package resources. `MacHelper.ai.transform` calls the shared AI helper only during an explicit tool action. The native MacHelper platform handles Accessibility, floating icons/results, cancellation, and clipboard actions.

With MacHelper 4.1 or later, Translation shows text as the provider generates it. The second callback passed to `MacHelper.ai.transform` receives cumulative partial text and forwards it through `input.reportProgress`. Customize both that callback and the returned final result if adding a prefix or changing formatting. Copy becomes available after completion. Cancelling, changing selection, or reloading prevents old chunks from appearing; a failed stream is clearly marked incomplete.

A reload starts a fresh worker after the new script validates. Syntax errors keep the previous working version active and appear in Settings. Settings live separately from source, and downloading a newer package does not overwrite local edits. New permissions require explicit re-enabling.

For a quick test, change the returned result to `{text: "译文：" + response.text, title: "My Translation"}` and save. Restore the original line to return to the normal result. Press Esc or click elsewhere to dismiss a translation.

The marketplace-ready catalog format lists every package file and its SHA-256. A remote catalog can be served by a future website; MacHelper lists its metadata first and downloads source when the user enables a tool. See `docs/Source-Extensions.md` in the main repository for the protocol.
