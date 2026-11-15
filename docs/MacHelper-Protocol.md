# MacHelper client protocol

The MacHelper implementation is a standalone Swift package in `MacHelper`. Its default extension format is an editable JavaScript source package running in an independent worker. Source tools call `MacHelper.ai.transform`; MacHelper validates that capability and invokes the AI helper on their behalf. They do not launch native executables or implement this transport themselves. See [source extensions](Source-Extensions.md) for their public interface.

Browser extensions use native messaging. Advanced native SDK extensions invoke the executable supplied by their context through the same protocol documented here. Neither requires importing MacHelper's private Swift implementation. MacHelper itself has no HTTP listener.

Installed executable: `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host`.
Browser host name: `com.localaibasetools.mac_helper`.

Each request and response is a four-byte unsigned little-endian length followed by one UTF-8 JSON object. Frames are limited to 256 KiB. Keep stdin open until receiving the answer; close it afterward so the helper disconnects. Stdout is reserved for framed protocol output. Text belongs in stdin, never command arguments. Use a timeout and cancel/close the process when a request is abandoned.

```json
{"id":"unique-id","action":"translate","text":"Hello","targetLanguage":"zh-CN","model":""}
```

Actions: `ping`, `listModels`, `translate`, `polish`. Text operations accept at most 24,000 characters/96,000 UTF-8 bytes. Translation languages: `zh-CN`, `zh-TW`, `en`, `ja`, `ko`, `fr`, `de`, `es`, `pt`, `it`. Polishing produces English and accepts `professional`, `friendly`, or `concise` tone. IDs are required and bounded to 128 bytes; use UUIDs.

Optional `guidance` carries an editable tool's translation/editing style, such as the contents of its prompt resource. It is limited to 12,000 characters/48,000 UTF-8 bytes and cannot contain a null character. The helper keeps `guidance` separate from untrusted `text` in its JSON AI request. Guidance can refine the transformation; it cannot authorize tools, sending messages, invented facts, or instructions embedded in the source text. Omit it for the standard behavior.

Missing/empty `model` uses the model saved in MacHelper. A nonempty model overrides it without changing preferences. Optional `provider` (`chatgpt`, `ollama`, `lmstudio`) and `baseURL` fields let the settings UI test unsaved choices. A changed provider resets inherited model/address; the client must supply any desired override. These are per-request settings, never persisted by the host. HTTP addresses must be loopback; remote endpoints and redirects are rejected.

```json
{"id":"unique-id","ok":true,"version":"4.0.0","model":"actual-model-id","text":"你好"}
```

`listModels` returns `models` containing `model`, `displayName`, `isDefault`, optional `defaultReasoningEffort`, and `supportedReasoningEfforts`; `defaultModel` is optional. Render backend labels rather than hard-coding model names. Local providers can return an empty catalog before any model is loaded/downloaded. `ping` verifies host reachability; `listModels` checks provider reachability. An error response contains `id`, `ok:false`, and `error`. The host permits one AI operation at a time per process and responds to ping independently.

Browser clients need explicit extension-ID registration. Native clients omit the browser origin argument. MacHelper is a per-user local executable, not an authentication boundary against other applications already running as that user.

The source-worker bridge uses its own framed process connection and generation identifiers. Source changes create a replacement worker after candidate validation; the host cancels stopped generations and ignores their stale responses. Extension JavaScript only receives declared capabilities and frozen package resources, not the helper executable path or this native-client authority. Browsing a catalog, enabling a source tool, and selecting text do not authorize AI inference; an explicit tool action is required.

Do not auto-send, auto-paste, collect entire documents, or log private content. Treat all selected/source text as untrusted input; display it as text, not executable HTML. Keep provider settings UI in MacHelper so more tools can share one configuration.
