# Polish-input — editable source extension

Polish-input 1.0.4 requires MacHelper 6.6 or later. It polishes selected writing in supported Mac apps, including selectable text in browser fields, without a browser extension. This folder contains its complete JavaScript behavior, prompt, settings schema, UI translations, discovery metadata, and license.

## Use

Install the source folder through **MacHelper → Extensions → Install Source…**, enable it, and review its permissions. MacHelper needs Accessibility permission to read text and apply an edit you explicitly approve. Translation and Polish-input share one floating selection toolbar.

Select your writing and choose **Polish**. When the preview finishes, choose the action your editor supports.

- **Apply** replaces the original selection after MacHelper verifies the app, focused field, exact range, and selected text.
- **Paste** uses the editor’s own Paste command on the current selection in the original window. MacHelper 6.7.3 or later offers this in editors such as WPS Writer when it captured the text by copying and can verify the window and editing commands. Keep the text selected while the preview is open. The polished result stays on the clipboard.
- **Copy** puts the result on the clipboard for manual use, including when reading a document.

In WPS Writer, triple-click a paragraph, choose **Polish**, then **Paste**. MacHelper preserves the leading and trailing whitespace supplied by WPS, including a selected paragraph break. This works with the standard WPS editing commands and requires no WPS add-in.

The default prompt improves grammar and clarity while preserving the source language, meaning, and tone. Availability and editor behavior depend on macOS Accessibility support. Text inside images, protected fields, and unsupported editors is excluded. Direct edits insert plain text; do not rely on preserving rich formatting or editor-specific Undo. Try a disposable draft before using it in an important document.

For supporting Electron apps, **MacHelper → General → Improve compatibility with Electron apps** is an optional setting, off by default. Enable it only if you want MacHelper to request full Accessibility after a new text selection. This may change app behavior: VS Code may enter Screen Reader Optimized mode, affecting folding and the minimap. Turning it off stops new requests; already affected apps may need restarting. It does not turn on VoiceOver or change macOS permissions. Select text again after changing it. The actions available in the preview depend on the editor’s selection support.

For **Apply**, supported web editors use clipboard-assisted replacement. Native controls prefer a direct selected-text edit. With paste permission, MacHelper can issue **⌘V** to the verified editable field after checking the exact range, selected text, and clipboard ownership. The polished text stays on the clipboard. For the separate **Paste** button, MacHelper checks the original selection gesture, app, window, available focus anchors, and enabled Cut command. After staging the result, it checks the window, Cut and Paste commands, and clipboard ownership again before requesting Paste once.

Check your draft after a paste request. Some editors provide confirmation of a direct edit. The completed preview stays available to copy.

MacHelper 6.7 can automatically copy and restore the clipboard when a recognized text-selection gesture cannot be read through Accessibility. No manual compatibility switch is needed. The host skips unsafe, stale, unreadable, or oversized cases and never copies from ordinary clicks or polling. Capture-only text supports previews and the completed result’s Copy button, without sentence context; it cannot authorize replacement by itself. For a replacement tool, a fresh matching Accessibility read at tool click may recover the original numeric range and source-origin proof while the original context remains unchanged. Before any Copy attempt, bounded preparation checks briefly let the selection, menu, and clipboard settle. A Copy attempt is never retried. The host keeps the snapshot in memory and avoids overwriting later clipboard changes. Preservation and app coverage are best effort; clipboard-history tools may observe temporary changes. The extension has no clipboard-reading or arbitrary keyboard API.

## Customize

The **Polishing prompt** editor displays `prompts/polish.txt` directly. Save Prompt writes that source file; Revert reloads the saved file. The entire prompt is sent verbatim as `systemPrompt`, and the selected text travels separately as a JSON object with one `text` field. MacHelper adds no hidden polishing instructions. Changing the interface language does not rewrite the prompt, selected text, or AI result.

Choose **Edit Source** to open the installed working folder. Saving `main.js`, the prompt, or schema validates and reloads this tool without restarting MacHelper. Invalid edits keep the last working generation. User settings stay separate. Editing the original import folder does not change the installed copy.

The extension requests `selection.read`, `selection.replace`, `selection.paste`, `ai.transform`, and `ui.panel`. Enabling clipboard-assisted Apply requires its own access review. These permissions enable the host’s explicit Apply and Paste controls; extension JavaScript has no arbitrary field-writing, clipboard-reading, or keyboard API. Provider/model settings remain under MacHelper → AI Connection. AI runs only after the user chooses Polish; enabling or reloading does not run inference.

Public descriptions, examples, keywords, limitations, and translations belong in `discovery.json`. The marketplace searches metadata independently of source downloads. The package can live in its own repository; its prompt and behavior do not belong in MacHelper source. See the project's `AI_EXTENSION_GUIDE.md` for the authoring contract.
