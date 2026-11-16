# MacHelper client protocol

MacHelper is implemented by the Swift package in `MacHelper`. This document describes its framed AI host protocol for browser native messaging and standalone local clients. The unified schema-2 extension system runs editable JavaScript or native Swift source in independent workers. Those extensions use `MacHelper.ai.transform` or `MacHelperNativeInput.transform`; MacHelper validates the capability and invokes this AI host on their behalf. Extension authors should use the [source API](Source-Extensions.md) rather than implement this transport.

Browser extensions use native messaging; standalone local clients can launch the installed host directly without importing MacHelper's private Swift implementation. The old schema-1 SDK's executable context is a legacy verification/migration interface and is not loaded by the normal app. MacHelper itself has no HTTP listener.

Installed executable: `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host`.
Browser host name: `com.localaibasetools.mac_helper`.

Each request and response is a four-byte unsigned little-endian length followed by one UTF-8 JSON object. Frames are limited to 256 KiB. Keep stdin open until receiving the answer; close it afterward so the helper disconnects. Stdout is reserved for framed protocol output. Text belongs in stdin, never command arguments. Use a timeout and cancel/close the process when a request is abandoned.

```json
{"id":"unique-id","action":"translate","text":"Hello","targetLanguage":"zh-CN","model":""}
```

Actions: `ping`, `listModels`, `translate`, `polish`. Legacy text operations accept nonblank text of at most 24,000 Swift characters (extended grapheme clusters)/96,000 UTF-8 bytes, without NUL. The character limits in this document use this Swift count; sentence context in the source API separately uses UTF-16 code units. Translation languages: `zh-CN`, `zh-TW`, `en`, `ja`, `ko`, `fr`, `de`, `es`, `pt`, `it`. Polishing produces English and accepts `professional`, `friendly`, or `concise` tone. IDs are required, nonempty, bounded to 128 UTF-8 bytes, and cannot contain control characters; use UUIDs.

Optional `guidance` carries an editable tool's translation/editing style, such as the contents of its prompt resource. It is limited to 12,000 characters/48,000 UTF-8 bytes and cannot contain a null character. The helper keeps `guidance` separate from untrusted `text` in its JSON AI request. Guidance can refine the transformation; it cannot authorize tools, sending messages, invented facts, or instructions embedded in the source text. Omit it for the standard behavior.

Editable tools can instead opt in to `systemPrompt`. Its supplied string becomes the exact system message for Ollama/LM Studio or the exact `developerInstructions` value for the ChatGPT app-server thread. The exact `text` string becomes the user message. MacHelper does not trim either message, append its standard transformation instructions, add language/tone/guidance text, or wrap the user message in its legacy action JSON. The extension owns its prompt and any structured source-data format. `systemPrompt` must contain non-whitespace text, be at most 12,000 characters/48,000 UTF-8 bytes, and contain no null character. Validation does not rewrite it. Omit the field to retain the legacy behavior used by existing browser clients.

```json
{"id":"unique-id","action":"translate","systemPrompt":"The extension's complete prompt.\n","text":"  Original input, or JSON prepared by the extension.\n"}
```

This prompt choice does not grant additional capabilities. Tool/MCP/web-search restrictions, read-only verification, ephemeral ChatGPT threads, model validation, response limits, and cancellation remain in force. Provider-level instructions and policies are controlled by the provider, rather than by this transport.

When `systemPrompt` is supplied, `text` is opaque extension-prepared data and may contain up to 192,000 UTF-8 bytes. This leaves room for JSON keys and escaping around an original selection of up to 24,000 characters/96,000 UTF-8 bytes; the selection reader's limit remains unchanged. Null characters remain invalid. The complete encoded native frame, including both messages and JSON escaping, must still fit the 256 KiB transport limit.

Missing/empty `model` uses the model saved in MacHelper. A nonempty model overrides it without changing preferences. Optional `provider` (`chatgpt`, `ollama`, `lmstudio`) and `baseURL` fields let the settings UI test unsaved choices. A changed provider resets inherited model/address; the client must supply any desired override. These are per-request settings, never persisted by the host. HTTP addresses must be loopback; remote endpoints and redirects are rejected.

```json
{"id":"unique-id","ok":true,"version":"6.2.0","model":"actual-model-id","text":"你好"}
```

Opt in to incremental output with `"stream": true` on a text request. The helper sends ordered progress frames as the provider produces text:

```json
{"id":"unique-id","event":"delta","delta":"你","model":"actual-model-id"}
{"id":"unique-id","event":"delta","delta":"好","model":"actual-model-id"}
{"id":"unique-id","ok":true,"version":"6.2.0","model":"actual-model-id","text":"你好"}
```

Progress is provisional. Append `delta` for display, keep reading until the ordinary terminal `ok` response, and replace the displayed text with that validated final answer. A terminal error after partial output remains a failed/incomplete answer. Closing stdin cancels the request and stops further progress. Missing/false `stream` retains one terminal response, including for existing browser clients. `ping` and `listModels` do not stream.

`listModels` returns `models` containing `model`, `displayName`, `isDefault`, optional `defaultReasoningEffort`, and `supportedReasoningEfforts`; `defaultModel` is optional. Render backend labels rather than hard-coding model names. Local providers can return an empty catalog before any model is loaded/downloaded. `ping` verifies host reachability; `listModels` checks provider reachability. An error response contains `id`, `ok:false`, and `error`. The host permits one AI operation at a time per process and responds to ping independently.

Browser clients need explicit extension-ID registration. Native clients omit the browser origin argument. MacHelper is a per-user local executable, not an authentication boundary against other applications already running as that user.

The source-worker bridge uses its own framed process connection and generation identifiers. Source changes create a replacement worker after candidate validation; the host cancels stopped generations and ignores their stale responses. Extension JavaScript only receives declared capabilities and frozen package resources, not the helper executable path or this native-client authority. Browsing a catalog, enabling a source tool, and selecting text do not authorize AI inference; an explicit tool action is required.

Do not auto-send, auto-paste, collect entire documents, or log private content. Treat all selected/source text as untrusted input; display it as text, not executable HTML. Keep provider settings UI in MacHelper so more tools can share one configuration.

## Unified extension worker boundary

MacHelper 6 source tools declare `runtime: "javascript"` or `"native"`. Each runtime uses its own replaceable worker but the same bounded command/capability framing. The native source SDK handles that internal worker protocol; extension authors should use `MacHelperNativeInput.transform` rather than implement it themselves. Both route explicit AI actions through the shared provider connection, preserve complete `systemPrompt` text, and receive streamed progress. Runtime migration changes the execution adapter while preserving identity and compatible settings. See [Native source extensions](Native-Extensions.md) for Swift authoring and approval rules. This worker channel is separate from the browser/native-client AI host protocol described above.
