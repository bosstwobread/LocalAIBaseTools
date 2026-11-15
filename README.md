# LocalAIBaseTools

LocalAIBaseTools currently contains **MessageHelper**, a browser extension and macOS helper for using your existing desktop AI connection to translate and polish text on Upwork.

MessageHelper adds a **Translate** button beside Upwork conversation messages and a **Polish** button beside the composer’s Send button. Translation appears below the original message. Polishing shows a preview; **Apply** inserts the suggestion into the draft, **Cancel** keeps the draft, and **Undo** restores the previous draft if it has not been edited again.

MessageHelper never clicks Send, submits a message, or sends an Upwork message automatically. You review the draft and use Upwork’s Send control yourself.

On Upwork’s **Leave feedback** contract form, each visible public review or private-note field gets **Polish** and **Translate draft** controls. Polishing previews natural English before **Apply**; **Undo** restores the original while it is still unchanged. Draft translation is for reference and never replaces the field. Ratings, contract-ending reasons, and Submit feedback are untouched. MessageHelper never submits feedback. Results exceeding the field’s character limit cannot be applied.

## Components

- `extension/`: Chrome/Edge Manifest V3 extension for `https://www.upwork.com/ab/messages/*`, `https://www.upwork.com/nx/proposals/*`, and `https://www.upwork.com/ab/feedbacks/f/contract/*`.
- `Sources/MessageHelperHost/`: macOS native messaging host, named `com.messagehelper.gpt`.
- `Sources/MessageHelperCore/`: GPT transport adapted from JobInterviewRealTime. This copy is independent of that project.

The extension passes only the selected message or current draft to the helper. The helper starts the installed Codex app-server and reuses your existing ChatGPT sign-in. You do not need a separate API key or a second account. GPT inference runs online; “local helper” means the bridge runs on your Mac. Requests use an answer-only conversation with tools disabled. Text from messages and drafts is treated as data, including any instructions embedded within it.

## Requirements

- macOS 14 or later, with the Codex/ChatGPT desktop app containing the bundled Codex CLI installed and signed in to ChatGPT.
- Microsoft Edge or Google Chrome.
- Swift command-line tools to build the helper. Node.js/npm and Python 3 are used only for development and tests.

## Installation

Run these commands from this project:

```sh
./scripts/build-helper.sh
python3 scripts/install-helper.py
```

The installer copies the helper to `~/Library/Application Support/MessageHelper/message-helper-host` and registers its native messaging manifest for Chrome and Edge. The manifest allows only this extension’s stable ID: `fmhfobfddchbeibojepeocgfemkpcklo`.

In Edge, open `edge://extensions`, enable **Developer mode**, choose **Load unpacked**, and select this project’s `extension` folder. In Chrome, use `chrome://extensions` and the same folder. Keep the folder in place; the browser loads the extension from it.

Open MessageHelper’s toolbar popup and click **Test helper connection**. A successful helper connection confirms installation; choose **Open safe test page** for synthetic translation and polishing checks. The browser launches the Mac helper automatically when needed.

## Usage

1. Open a supported Upwork conversation. Reload an already-open page after installing or reloading the extension.
2. Click **Translate** beside a message. The result appears underneath it. Simplified Chinese is the default; change the target language in the popup.
3. Write a draft, then click **Polish**. Select **Apply** to use the suggestion or **Cancel** to retain your draft.
4. Review the result and click Upwork’s Send button yourself when ready.

If you edit the draft or change conversations while polishing is in progress, MessageHelper prevents an old suggestion from overwriting the changed draft. Undo also checks that the applied text is still present before restoring the original.

## Choosing a GPT model

Open the extension popup and use **GPT model** to choose the model for both translation and polishing. **Desktop default** uses the installed backend’s default; choosing a named model applies only to MessageHelper requests and does not change the desktop app’s global configuration.

The dropdown retrieves the current model catalog from the installed Codex backend every time the popup opens. **Refresh models** fetches it again. Model IDs, display names, and ordering come from the backend rather than a hard-coded list. New models can therefore appear without an extension update as long as the backend’s catalog protocol stays compatible. Your selection is saved locally and retained when the catalog refreshes.

If a selected model is retired or otherwise unavailable, MessageHelper keeps the saved selection and reports the problem. It does not silently use a different model. Open the popup and choose an available model or **Desktop default**. Model discovery does not submit any conversation text for inference. While a translation or polishing request is running, wait for it to finish before refreshing the catalog.

## Permissions and data

The extension requests `nativeMessaging` to communicate with the Mac helper and `storage` to save language, tone, and model preferences. Its content scripts run only on the two supported Upwork routes. It does not request access to other websites or Upwork’s messaging API. Message translation and polishing happen only after you click the relevant button. The source text is sent through your authenticated GPT connection for that request; inference requires internet access and uses your account’s available usage.

## Updates and reinstalling

After helper changes, rerun `./scripts/build-helper.sh` and `python3 scripts/install-helper.py`, then reload the extension in the browser’s extensions page. After extension-only changes, click **Reload** on the extension and refresh the Upwork tab. The stable manifest key keeps its extension ID unchanged. A development build using a different ID must register it explicitly with `python3 scripts/install-helper.py --extension-id YOUR_EXTENSION_ID`.

## Verification

```sh
npm ci --ignore-scripts
npm test
swift test
swift build -c release
python3 scripts/test-native.py
python3 scripts/test-native.py --catalog
python3 scripts/test-native.py --live
python3 scripts/test-native.py --live --model MODEL_ID_FROM_CATALOG
```

The JavaScript regressions use synthetic conversation/editor fixtures with Send-event sentinels. Popup tests use future model names supplied by a mock backend and check discovery on each open, manual refresh, saved selection, and unavailable-selection handling. Requests and translation caches are checked for model isolation. Native smoke tests check framing, connectivity, and invalid request rejection. `--catalog` discovers models without inference. `--live` optionally translates and polishes a synthetic fixture with a fake client name and an `example.invalid` URL; `--model` checks that both operations use the explicitly selected model. The live smoke test checks Chinese translation and preservation of the name, date, amount and URL while polishing. These tests do not send anything on Upwork.

Upwork can change its page structure. If buttons stop appearing after an Upwork update, the extension’s page adapter may need updating. Use the private test page to distinguish a page integration issue from a helper connection issue.

### Verified installation on this Mac — October 12, 2026

- MessageHelper 1.1.0 is enabled in Microsoft Edge, with the helper installed and registered for Edge and Chrome.
- 38 Swift tests and 25 JavaScript regressions pass. Tests cover dynamic catalogs, future model IDs, pagination, selected-model routing, effort compatibility, removed models, and the existing draft safeguards.
- The installed Model dropdown retrieves all seven models currently listed by the desktop service. Selected models survive catalog refresh and reopening the popup. Synthetic browser translation and polishing confirmed that choosing GPT-6-Luna uses `gpt-6-luna`. Desktop default was restored after testing.
- Live tests on the installed helper translate synthetic text to Chinese and polish English with the explicitly selected model while preserving a name, date, amount, and URL.
- The installed browser extension connects to the helper. Real GPT translation, polishing, Apply, and Undo pass in the safe test page.
- The proposal conversation frame and the main Messages page both display Translate controls and Polish immediately before Send. Live proposal-message translation and polishing preview/Cancel pass; the pre-existing `ddd` draft is preserved.
- Live Upwork draft insertion was intentionally left to the user; Apply/Undo were tested in the sandbox. No Upwork messages were sent during testing.

### Feedback support verified — October 19, 2026

- MessageHelper 1.2.0 is loaded and enabled in Edge. No native helper update is required.
- All 36 JavaScript tests pass, including 10 feedback regressions covering separate public/private drafts, character limits, disabled/hidden fields, stale results, safe recovery, and zero submission events.
- Real GPT polishing, Apply, Undo, and read-only draft translation pass with synthetic feedback in the extension’s safe test page.
- The live Leave feedback form displays both controls for the public review and the dynamically opened private note. Its original tab, draft, rating, and ending reason were preserved; no feedback or messages were submitted.
- An already-open feedback tab must be refreshed to load the new content script. Preserve unsaved text and form selections before refreshing.

## License

MIT. See [LICENSE](LICENSE).
