# MacHelper Connector

A small Chrome/Edge extension that connects the official Extension Market to MacHelper for description-based AI search. It uses your shared MacHelper AI connection; it is not an AI provider or another Mac app.

## Install

1. Install MacHelper 6.3 or later in Applications, open it, and choose **MacHelper → Install Browser Support…** from the app menu.
2. Download and extract this complete extension folder. In Chrome or Edge, open the Extensions page, enable Developer mode, choose **Load unpacked**, and select this folder.
3. Keep the `key` in `manifest.json`. The stable extension ID is `kkmffpbghoojlnldpdolonpjmkhdenkh`, already authorized by MacHelper's installer.
4. Open <https://local-ai-extension.nelson007.com/>. Describe the tool you need and explicitly start AI search. The ordinary keyword search works without this connector.

Search is available on the website. MacHelper manages the shared provider/model settings and serves AI search requests; it has no search screen.

Use the toolbar button to open the marketplace. The connector does not request access to Upwork, browsing history, page contents, or browser storage. It accepts requests only from the official HTTPS marketplace's top-level page. Browser stores may assign a different ID; such a release must update the website connector ID and register its exact ID in MacHelper first.

## Public browser protocol

The website calls `chrome.runtime.sendMessage` with the extension ID above and one of:

```js
{ type: "machelper.discovery", action: "status" }
{ type: "machelper.discovery", action: "search", requestId: "unique_123", query: "Translate selected text in Mac apps", language: "en" }
{ type: "machelper.discovery", action: "cancel", requestId: "unique_123" }
```

`requestId` must contain 1–80 ASCII letters, digits, `_`, or `-`. Search accepts at most 2,000 UTF-16 code units and 8,000 UTF-8 bytes, with a nonblank query. MacHelper also enforces its own text limit. Supported interface languages are `en`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `ja`, `ko`, `pt`, `ar`, `hi`, `ru`, and `it`; omitted language defaults to `en`. The query is forwarded unchanged.

Status replies include `ok`, `version`, `connectorVersion`, and `compatible`. Search replies contain `ok`, `version`, and `search`, whose fields are `revision`, `updatedAt`, `stale`, `model`, `matches` (`id`, `reason`, `fit`), and optional `noMatchReason`. Errors contain `ok: false` and `error`. Cancellation replies contain `ok: true` and `cancelled`.

The connector pings `com.localaibasetools.mac_helper`, checks MacHelper is at least 6.3, then sends the narrow native request `{id, action: "searchExtensions", text, interfaceLanguage}`. It never offers arbitrary AI prompts, local file access, shell commands, settings access, or extension installation to the website. General native-host actions remain inaccessible through this bridge.

One search can run per tab; only its originating document can cancel it. Cancellation disconnects that search's native port, allowing MacHelper to cancel the AI operation. Closing a tab also disconnects its search. Connection checks time out after 10 seconds; searches after 4 minutes. Navigation to another document is cleaned up when that document starts a new search, or by the timeout. Results do not stream through this protocol; the website shows a searching state until the ranked result arrives. The connector does not persist queries or results.

## Development

Edit this source folder, then use Reload on the browser's Extensions page. The stable public key is safe to publish; no private signing key is stored in this project. The marketplace exposes only public catalog metadata to search. Actual extension source is downloaded when a user chooses to install it.

Run `node --test test/connector.test.cjs` from the repository root. Tests use fake browser/native ports and synthetic text, with no real AI or browser settings changes. See the repository's `DEVELOPMENT.md` and `AI_EXTENSION_GUIDE.md` before changing the shared protocol.
