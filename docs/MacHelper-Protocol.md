# MacHelper client protocol

MacHelper is implemented by the Swift package in `MacHelper`. This document describes its framed AI host protocol for browser native messaging and standalone local clients, plus its separate local HTTP protocol for website discovery. The unified schema-2 extension system runs editable JavaScript or native Swift source in independent workers. Those extensions use `MacHelper.ai.transform` or `MacHelperNativeInput.transform`; MacHelper validates the capability and invokes this AI host on their behalf. Extension authors should use the [source API](Source-Extensions.md) rather than implement this transport.

Browser extensions use native messaging; standalone local clients can launch the installed host directly without importing MacHelper's private Swift implementation. The old schema-1 SDK's executable context is a legacy verification/migration interface and is not loaded by the normal app. MacHelper 6.5 also runs a narrow loopback HTTP service for extension-free website discovery, documented separately below; native messaging remains a compatibility transport for retired MessageHelper-Upwork and other local text clients. Translation and Polish-input use host-managed source capabilities and need no browser extension.

Installed executable: `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host`.
Browser host name: `com.localaibasetools.mac_helper`.

Each request and response is a four-byte unsigned little-endian length followed by one UTF-8 JSON object. Frames are limited to 256 KiB. Keep stdin open until receiving the answer; close it afterward so the helper disconnects. Stdout is reserved for framed protocol output. Text belongs in stdin, never command arguments. Use a timeout and cancel/close the process when a request is abandoned.

```json
{"id":"unique-id","action":"translate","text":"Hello","targetLanguage":"zh-CN","model":""}
```

Actions: `ping`, `listModels`, `translate`, `polish`, and (MacHelper 6.3+) `searchExtensions`. Discovery uses the separate contract below; legacy text-operation fields do not configure it. Legacy text operations accept nonblank text of at most 24,000 Swift characters (extended grapheme clusters)/96,000 UTF-8 bytes, without NUL. The character limits in this document use this Swift count; sentence context in the source API separately uses UTF-16 code units. Translation languages: `zh-CN`, `zh-TW`, `en`, `ja`, `ko`, `fr`, `de`, `es`, `pt`, `it`. Polishing produces English and accepts `professional`, `friendly`, or `concise` tone. IDs are required, nonempty, bounded to 128 UTF-8 bytes, and cannot contain control characters; use UUIDs.

Optional `guidance` carries an editable tool's translation/editing style, such as the contents of its prompt resource. It is limited to 12,000 characters/48,000 UTF-8 bytes and cannot contain a null character. The helper keeps `guidance` separate from untrusted `text` in its JSON AI request. Guidance can refine the transformation; it cannot authorize tools, sending messages, invented facts, or instructions embedded in the source text. Omit it for the standard behavior.

Editable tools can instead opt in to `systemPrompt`. Its supplied string becomes the exact system message for Ollama/LM Studio or the exact `developerInstructions` value for the ChatGPT app-server thread. The exact `text` string becomes the user message. MacHelper does not trim either message, append its standard transformation instructions, add language/tone/guidance text, or wrap the user message in its legacy action JSON. The extension owns its prompt and any structured source-data format. `systemPrompt` must contain non-whitespace text, be at most 12,000 characters/48,000 UTF-8 bytes, and contain no null character. Validation does not rewrite it. Omit the field to retain the legacy behavior used by existing browser clients.

```json
{"id":"unique-id","action":"translate","systemPrompt":"The extension's complete prompt.\n","text":"  Original input, or JSON prepared by the extension.\n"}
```

This prompt choice does not grant additional capabilities. Tool/MCP/web-search restrictions, read-only verification, ephemeral ChatGPT threads, model validation, response limits, and cancellation remain in force. Provider-level instructions and policies are controlled by the provider, rather than by this transport.

When `systemPrompt` is supplied, `text` is opaque extension-prepared data and may contain up to 192,000 UTF-8 bytes. This leaves room for JSON keys and escaping around an original selection of up to 24,000 characters/96,000 UTF-8 bytes; the selection reader's limit remains unchanged. Null characters remain invalid. The complete encoded native frame, including both messages and JSON escaping, must still fit the 256 KiB transport limit.

Missing/empty `model` uses the model saved in MacHelper. A nonempty model overrides it without changing preferences. Optional `provider` (`chatgpt`, `ollama`, `lmstudio`) and `baseURL` fields let the settings UI test unsaved choices. A changed provider resets inherited model/address; the client must supply any desired override. These are per-request settings, never persisted by the host. HTTP addresses must be loopback; remote endpoints and redirects are rejected.

```json
{"id":"unique-id","ok":true,"version":"6.8.0","model":"actual-model-id","text":"你好"}
```

Opt in to incremental output with `"stream": true` on a text request. The helper sends ordered progress frames as the provider produces text:

```json
{"id":"unique-id","event":"delta","delta":"你","model":"actual-model-id"}
{"id":"unique-id","event":"delta","delta":"好","model":"actual-model-id"}
{"id":"unique-id","ok":true,"version":"6.8.0","model":"actual-model-id","text":"你好"}
```

Progress is provisional. Append `delta` for display, keep reading until the ordinary terminal `ok` response, and replace the displayed text with that validated final answer. A terminal error after partial output remains a failed/incomplete answer. Closing stdin cancels the request and stops further progress. Missing/false `stream` retains one terminal response, including for existing browser clients. `ping` and `listModels` do not stream.

`listModels` returns `models` containing `model`, `displayName`, `isDefault`, optional `defaultReasoningEffort`, and `supportedReasoningEfforts`; `defaultModel` is optional. Render backend labels rather than hard-coding model names. Local providers can return an empty catalog before any model is loaded/downloaded. `ping` verifies host reachability; `listModels` checks provider reachability. An error response contains `id`, `ok:false`, and `error`. The host permits one AI operation at a time per process and responds to ping independently.

Browser clients need explicit extension-ID registration. Native clients omit the browser origin argument. MacHelper is a per-user local executable, not an authentication boundary against other applications already running as that user.

The source-worker bridge uses its own framed process connection and generation identifiers. Source changes create a replacement worker after candidate validation; the host cancels stopped generations and ignores their stale responses. Extension JavaScript only receives declared capabilities and frozen package resources, not the helper executable path or this native-client authority. Browsing a catalog, enabling a source tool, and selecting text do not authorize AI inference; an explicit tool action is required.

Do not auto-send, paste without an approved, explicit Apply action, collect entire documents, or log private content. Both clipboard-assisted Apply methods belong to the source host’s separately approved `selection.paste` capability, not this framed AI transport; it provides no general clipboard or keyboard endpoint. Treat all selected/source text as untrusted input; display it as text, not executable HTML. Keep provider settings UI in MacHelper so more tools can share one configuration.

### Local companion protocol (MacHelper 6.8.0)

The companion project owns its Chrome Native Messaging registration and bridge. Register only its exact Chrome origin and verify the origin Chrome supplies before forwarding a message. The bridge is a same-user local client. MacHelper rechecks the declared extension ID and approved command scope. Its socket is separate from website discovery and the legacy framed host.

Resolve the macOS per-user temporary directory using `confstr(_CS_DARWIN_USER_TEMP_DIR)` and open `mh-companion/endpoint` in that directory. The app creates the directory with mode `0700`. The regular endpoint file contains a generated socket basename of 32 lowercase hexadecimal characters followed by `.sock`. Verify same-user ownership and file types, and refuse symlinks. Connect to the Unix socket in the same directory.

Frames use a four-byte little-endian length followed by UTF-8 JSON. The complete JSON frame limit is 128 KiB. Opaque request and response strings are limited to 32 KiB each. An invocation accepts one request per connection.

```json
{"type":"invoke","extension":"com.example.tool","companion":"abcdefghijklmnopabcdefghijklmnop","command":"receive","payload":"{\"text\":\"example\"}"}
```

The result is `{"ok":true,"payload":"..."}` with the worker’s `text` string. Errors use `{"ok":false,"error":"..."}` with `invalid`, `unavailable`, `busy`, or `failed`. Parallel work is bounded and each source extension has at most one in-flight companion command. Closing the connection, disabling the tool, pausing MacHelper, or replacing the worker generation cancels pending work.

A separate connection can send `{"type":"watchStatus","extension":"com.example.tool","companion":"abcdefghijklmnopabcdefghijklmnop"}`. It receives `{"type":"status","enabled":true}` or `{"type":"status","enabled":false}` immediately and when effective state changes. It can remain open while the approved source is installed. Changing or removing its scope closes the connection. The bridge should reconnect and request fresh status after disconnect.

## Extension discovery (MacHelper 6.3)

This native action remains available for compatible local clients, including historical Connector versions. The current website uses the separate local HTTP service below. Discovery searches public descriptions using the provider/model already saved in **AI Connection**. It returns recommendations only: no source download, installation, execution, permission approval, arbitrary AI prompt, or provider override is part of this action.

```json
{"id":"discovery-example","action":"searchExtensions","text":"Translate selected words in Mac apps","interfaceLanguage":"en"}
```

`text` must be nonblank, contain no NUL, and fit **2,000 UTF-16 code units / 8,000 UTF-8 bytes**. Search trims outer whitespace after validation. Optional `interfaceLanguage` defaults to `en` and accepts `en`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `ja`, `ko`, `pt`, `ar`, `hi`, `ru`, or `it`. Search rejects `targetLanguage`, `tone`, `model`, `provider`, `baseURL`, `guidance`, `systemPrompt`, and `stream: true`. It has one terminal response and does not stream progress frames. Existing request-ID and frame bounds still apply.

```json
{
  "id": "discovery-example",
  "ok": true,
  "version": "6.8.0",
  "search": {
    "revision": "<64 lowercase hexadecimal characters>",
    "updatedAt": "2026-11-17T00:00:00Z",
    "stale": false,
    "model": "actual-model-id",
    "matches": [
      {"id": "com.localaibasetools.translation", "reason": "Translates selected text across supported Mac apps.", "fit": "good"}
    ]
  }
}
```

The model may return at most five distinct IDs from the actual candidate set, each with a nonblank reason (1,000 UTF-16 units / 4,000 UTF-8 bytes) and `fit` of `good` or `partial`. Empty matches include `noMatchReason`. A completely empty catalog may return an empty model because no inference was needed. Invalid/unknown/duplicate IDs or malformed answers fail rather than inventing a listing. Use the terminal `ok:false`/`error` response for failures. Closing stdin/native-port disconnection cancels pending search and provider work.

The host refreshes a fixed configured `discovery-manifest.json` and verifies its adjacent index against revision, timestamp, byte size, and SHA-256. The index is at most 16 MiB/10,000 entries; cache or bundled seeds can be returned with `stale:true` if refresh fails. No index/source URL can be supplied by a browser request or AI result. Ranking uses bounded public metadata, with query expansion and a local lexical shortlist when there are more than 40 entries; it is not guaranteed exhaustive semantic search. Query and metadata remain untrusted, and provider tools are disabled. Full [descriptor/index details](Source-Extensions.md#public-discovery-metadata-machelper-63) are separate from the source installation catalog.

## Website local discovery (MacHelper 6.5)

The running MacHelper app automatically serves `http://127.0.0.1:43827`. The app serves this interface while **General → Enable MacHelper** is on. It binds only IPv4 loopback. This is a discovery-only interface: status, session creation, bounded search, and cancellation. It cannot read files/settings, accept arbitrary prompts/provider overrides, perform general text transformations, install tools, or execute code. Shared **AI Connection** settings select the provider/model. Native Messaging registration and browser extensions are unnecessary for website search.

The sole production browser origin is `https://local-ai-extension.nelson007.com`, with no alternate domain, wildcard, null origin, or local development origin. Requests must supply that exact `Origin` and the exact loopback `Host` including port. Except for CORS `OPTIONS`, they must include `X-MacHelper-Client: extension-market`. JSON POSTs use `Content-Type: application/json`. The listener validates headers, method/path, request size, and allowed fields before processing; malformed, oversized, or unsupported requests fail closed. HTTP/1.1 headers are limited to 8 KiB, JSON bodies to 16 KiB, and responses to 256 KiB. It accepts one request per connection with an explicit POST Content-Length, rejects duplicate/ambiguous headers, transfer encoding, upgrades, and pipelining, and closes after its response. At most 16 connections and 16 sessions are held; initial request receipt times out after 10 seconds and a search after 240 seconds. There is no proxy to an arbitrary URL. Automated tests use isolated listeners/mocked inference rather than weakening the production origin check. Origin checks and session tokens constrain browser access; they are not an authentication boundary against other processes already running as the same macOS user.

The website’s AI search action is **Find with AI**. First validate the need locally; blank, oversized, or otherwise invalid input must not contact MacHelper. Under that valid user click, establish a session if none is held or its fixed expiry has passed, then send the search. The browser may ask for local/loopback network permission during that first connection. Status and session creation do not call the AI provider. Loading a page, editing a query, changing language, and playing preview demonstrations must not make local requests or trigger that permission prompt. A new page and a restarted app require no separate Connect/Reconnect control.

| Request | Authentication and body | Success response |
| --- | --- | --- |
| `GET /v1/status` | Client/Origin/Host headers; no token | `{ok:true,version:"6.7.7",protocolVersion:1}` |
| `POST /v1/session` | Client/Origin/Host headers; `{}` | `{ok:true,token:"<opaque random token>",expiresIn:1800}` |
| `POST /v1/search` | `Authorization: Bearer <token>`; `{requestId,query,language}` | `{ok:true,version:"6.7.7",search:<discovery result>}` |
| `POST /v1/cancel` | `Authorization: Bearer <token>`; `{requestId}` | `{ok:true,cancelled:<boolean>}` |

`requestId` is 1–80 ASCII letters, digits, `_`, or `-`. Search `query` has the native discovery bounds above: nonblank, no NUL, at most 2,000 UTF-16 units and 8,000 UTF-8 bytes. `language` uses the supported interface codes above. Additional fields are rejected. The `search` object follows the revision/model/matches contract above; results are terminal, rather than streamed. Only an explicit **Find with AI** action may start ranking.

Session tokens are random, bounded to 16, kept only in the app and page memory, and expire after a fixed 1,800 seconds. Creating a session at capacity evicts the least recently used inactive session; the active search’s owner is retained so it can cancel. An evicted tab receives an unauthorized response; its valid Find with AI action may renew the session as described below. Using a session updates its recency without extending its expiry. Expiry prevents a new search; an expired token belonging to the active search is retained only so its owner can cancel that ongoing operation. Never store them in URLs, cookies, browser local storage, logs, or files. Search/cancel need the session’s Bearer token. Cancellation can affect only the matching request owned by that token; another session cannot cancel it. Aborting/disconnecting a search cancels its owned inference. Quitting, restarting, or pausing MacHelper invalidates every session. **AI Connection → Restart Connection** also invalidates sessions while the app is enabled. A missing or expired session is renewed only within the explicit valid **Find with AI** action. If `/v1/search` returns HTTP 401 before inference begins, the website discards its token, performs one fresh status/session handshake, and retries the same search once. A second 401 ends that action. Provider failures, busy responses, network timeouts, and other AI errors must not trigger an automatic inference retry or provider fallback. There is no session refresh on page load or from background UI activity.

Error responses use `{ok:false,code:"<machine-readable code>",error:"<readable message>"}` with an appropriate non-2xx status. Invalid/unauthorized requests use 4xx; a busy search uses HTTP 429. Clients must handle unavailable service, denied browser local access, timeout/cancellation, expired sessions, and provider errors separately from a valid empty-match result. Do not interpret browser network failure as permission to fall back to a cloud AI backend or another provider. Keyword filtering remains usable without the local connection.

After a local connection error, **Open MacHelper** uses the exact `machelper://open` URL to launch/focus the installed app, with no search query or AI action, while **Get MacHelper** offers the download. The local service is unreachable when the app is paused, closed, or missing. A paused app can be resumed in **General → Enable MacHelper**. After resolving the connection issue, the user chooses **Find with AI** again. It is separate from reviewed `machelper://install` source-package links. Chrome/Edge may be installed before or after MacHelper; no per-browser/profile installation is required for this service. A new profile or browser reinstall may require local-access approval and a fresh session, while the MacHelper app and shared provider settings remain in place. The retired MessageHelper-Upwork package uses its own browser extension and Native Messaging host; the current Translation and Polish-input tools need neither a browser extension nor profile registration. The native **Website connection** status identifies a paused app. **Restart Connection** manages the loopback listener while the app is enabled.

With MacHelper running, `python3 scripts/test-marketplace-service.py` checks the installed HTTP service without inference. Its optional `--live` flag ranks one synthetic public need using the saved provider and consumes usage. Swift socket tests and website mocked-HTTP tests separately cover session expiry/eviction, cancellation, malformed requests, and unavailable service; the compatibility `scripts/test-discovery.py` still checks framed native requests.

## Unified extension worker boundary

MacHelper 6 source tools declare `runtime: "javascript"` or `"native"`. Each runtime uses its own replaceable worker but the same bounded command/capability framing. The native source SDK handles that internal worker protocol; extension authors should use `MacHelperNativeInput.transform` rather than implement it themselves. Both route explicit AI actions through the shared provider connection, preserve complete `systemPrompt` text, and receive streamed progress. Runtime migration changes the execution adapter while preserving identity and compatible settings. See [Native source extensions](Native-Extensions.md) for Swift authoring and approval rules. This worker channel is separate from the browser/native-client AI host protocol described above.
