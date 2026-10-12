# MessageHelper

MessageHelper adds a **Translate** button beside Upwork conversation messages and a **Polish** button beside the composer’s Send button. Translation appears below the original message. Polishing shows a preview; **Apply** inserts the suggestion into the draft, **Cancel** keeps the draft, and **Undo** restores the previous draft if it has not been edited again.

MessageHelper never clicks Send, submits a message, or sends an Upwork message automatically. You review the draft and use Upwork’s Send control yourself.

## Components

- `extension/`: Chrome/Edge Manifest V3 extension for `https://www.upwork.com/ab/messages/*` and `https://www.upwork.com/nx/proposals/*`.
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

## Permissions and data

The extension requests `nativeMessaging` to communicate with the Mac helper and `storage` to save language/tone preferences. Its content scripts run only on the two supported Upwork routes. It does not request access to other websites or Upwork’s messaging API. Message translation and polishing happen only after you click the relevant button. The source text is sent through your authenticated GPT connection for that request; inference requires internet access and uses your account’s available usage.

## Updates and reinstalling

After helper changes, rerun `./scripts/build-helper.sh` and `python3 scripts/install-helper.py`, then reload the extension in the browser’s extensions page. After extension-only changes, click **Reload** on the extension and refresh the Upwork tab. The stable manifest key keeps its extension ID unchanged. A development build using a different ID must register it explicitly with `python3 scripts/install-helper.py --extension-id YOUR_EXTENSION_ID`.

## Verification

```sh
npm ci --ignore-scripts
npm test
swift test
swift build -c release
python3 scripts/test-native.py
python3 scripts/test-native.py --live
```

The JavaScript regressions use synthetic conversation/editor fixtures with Send-event sentinels. Native smoke tests check framing, connectivity, invalid request rejection, and optionally live translation/polishing of a synthetic fixture with a fake client name and an `example.invalid` URL. The live smoke test checks Chinese translation and preservation of the name, date, amount and URL while polishing. These tests do not send anything on Upwork.

Upwork can change its page structure. If buttons stop appearing after an Upwork update, the extension’s page adapter may need updating. Use the private test page to distinguish a page integration issue from a helper connection issue.

### Verified installation on this Mac — October 12, 2026

- MessageHelper 1.0.0 is enabled in Microsoft Edge, with the helper installed and registered for Edge and Chrome.
- 29 Swift tests and 14 JavaScript regressions pass. Live tests on the installed helper translate synthetic text to Chinese and polish English while preserving a name, date, amount, and URL.
- The installed browser extension connects to the helper. Real GPT translation, polishing, Apply, and Undo pass in the safe test page.
- The proposal conversation frame and the main Messages page both display Translate controls and Polish immediately before Send. Live proposal-message translation and polishing preview/Cancel pass; the pre-existing `ddd` draft is preserved.
- Live Upwork draft insertion was intentionally left to the user; Apply/Undo were tested in the sandbox. No Upwork messages were sent during testing.
