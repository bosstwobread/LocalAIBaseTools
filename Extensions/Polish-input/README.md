# Polish-input — editable source extension

Polish-input 1.0.0 requires MacHelper 6.6 or later. It polishes selected writing in supported Mac apps, including selectable text in browser fields, without a browser extension. This folder contains its complete JavaScript behavior, prompt, settings schema, UI translations, discovery metadata, and license.

## Use

Install the source folder through **MacHelper → Extensions → Install Source…**, enable it, and review its permissions. MacHelper needs Accessibility permission to read text and apply an edit you explicitly approve. Translation and Polish-input share one floating selection toolbar.

Select your writing and choose **Polish**. The result streams into a movable preview panel. After it finishes, choose **Apply** to replace the original selection in a supported editable field. MacHelper rechecks the source app, field, selected range, and exact text before requesting the edit. **Copy** is available for manual use when editing is unavailable, including read-only text. No message is sent automatically.

The default prompt improves grammar and clarity while preserving the source language, meaning, and tone. Availability and editor behavior depend on macOS Accessibility support. Text inside images, protected fields, and unsupported editors is excluded. Direct edits insert plain text; do not rely on preserving rich formatting or editor-specific Undo. Try a disposable draft before using it in an important document.

For supporting Electron apps, **MacHelper → General → Improve compatibility with Electron apps** is an optional setting, off by default. Enable it only if you want MacHelper to request full Accessibility after a new text selection. This may change app behavior: VS Code may enter Screen Reader Optimized mode, affecting folding and the minimap. Turning it off stops new requests; already affected apps may need restarting. It does not turn on VoiceOver or change macOS permissions. Select text again after changing it. The option does not guarantee Apply support; unsupported fields still use Copy.

MacHelper checks whether the selected field belongs to a web editor or a native control. Supported web editors, including those embedded in desktop apps, use approved **clipboard-assisted Apply** before any write because an advertised selected-text setter may ignore direct edits. Verified native controls prefer direct selected-text editing and can use approved paste when direct editing is unavailable. If the bounded check cannot determine the editor type, only approved paste is eligible with the same strict editable-field and selection checks. Fields without that evidence keep Copy. The permission lets MacHelper put the completed result on the clipboard and issue a fixed **⌘V** to the verified source app. The result stays on the clipboard, just as with Copy. MacHelper never reads or restores your previous clipboard contents, never changes focus or forces a selection, and never presses Enter or Send. It checks clipboard ownership and the original selection again before requesting Paste. Missing paste approval, insufficient editable-field evidence, unsupported or changed targets keep the manual Copy fallback. A failed direct edit never starts an automatic paste retry. No browser extension or whole-field reconstruction is used.

A paste request alone does not prove the editor accepted it; check your draft. Direct edits are confirmed only where the app supports read-back. MacHelper does not automatically retry or roll back edits. After an Apply attempt, the completed preview stays copyable through selection updates caused by the editor. Dismiss it, select text again, or switch apps to leave that result.

## Customize

The **Polishing prompt** editor displays `prompts/polish.txt` directly. Save Prompt writes that source file; Revert reloads the saved file. The entire prompt is sent verbatim as `systemPrompt`, and the selected text travels separately as a JSON object with one `text` field. MacHelper adds no hidden polishing instructions. Changing the interface language does not rewrite the prompt, selected text, or AI result.

Choose **Edit Source** to open the installed working folder. Saving `main.js`, the prompt, or schema validates and reloads this tool without restarting MacHelper. Invalid edits keep the last working generation. User settings stay separate. Editing the original import folder does not change the installed copy.

The extension requests `selection.read`, `selection.replace`, `selection.paste`, `ai.transform`, and `ui.panel`. Enabling clipboard-assisted Apply requires its own access review. These permissions enable the host's explicit Apply control; extension JavaScript has no arbitrary field-writing, clipboard-reading, or keyboard API. Provider/model settings remain under MacHelper → AI Connection. AI runs only after the user chooses Polish; enabling or reloading does not run inference.

Public descriptions, examples, keywords, limitations, and translations belong in `discovery.json`. The marketplace searches metadata independently of source downloads. The package can live in its own repository; its prompt and behavior do not belong in MacHelper source. See the project's `AI_EXTENSION_GUIDE.md` for the authoring contract.
