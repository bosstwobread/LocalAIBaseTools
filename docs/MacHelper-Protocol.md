# MacHelper client protocol

The MacHelper implementation is a standalone Swift package in `MacHelper`. Tools under `Extensions` must remain independently buildable. Hosted native extensions invoke the executable supplied by their SDK context; browser extensions use native messaging. There is no HTTP listener in MacHelper itself.

Installed executable: `~/Library/Application Support/LocalAIBaseTools/MacHelper/mac-helper-host`.
Browser host name: `com.localaibasetools.mac_helper`.

Each request and response is a four-byte unsigned little-endian length followed by one UTF-8 JSON object. Frames are limited to 256 KiB. Keep stdin open until receiving the answer; close it afterward so the helper disconnects. Stdout is reserved for framed protocol output. Text belongs in stdin, never command arguments. Use a timeout and cancel/close the process when a request is abandoned.

```json
{"id":"unique-id","action":"translate","text":"Hello","targetLanguage":"zh-CN","model":""}
```

Actions: `ping`, `listModels`, `translate`, `polish`. Text operations accept at most 24,000 characters/96,000 UTF-8 bytes. Translation languages: `zh-CN`, `zh-TW`, `en`, `ja`, `ko`, `fr`, `de`, `es`, `pt`, `it`. Polishing produces English and accepts `professional`, `friendly`, or `concise` tone. IDs are required and bounded to 128 bytes; use UUIDs.

Missing/empty `model` uses the model saved in MacHelper. A nonempty model overrides it without changing preferences. Optional `provider` (`chatgpt`, `ollama`, `lmstudio`) and `baseURL` fields let the settings UI test unsaved choices. A changed provider resets inherited model/address; the client must supply any desired override. These are per-request settings, never persisted by the host. HTTP addresses must be loopback; remote endpoints and redirects are rejected.

```json
{"id":"unique-id","ok":true,"version":"3.0.0","model":"actual-model-id","text":"你好"}
```

`listModels` returns `models` containing `model`, `displayName`, `isDefault`, optional `defaultReasoningEffort`, and `supportedReasoningEfforts`; `defaultModel` is optional. Render backend labels rather than hard-coding model names. Local providers can return an empty catalog before any model is loaded/downloaded. `ping` verifies host reachability; `listModels` checks provider reachability. An error response contains `id`, `ok:false`, and `error`. The host permits one AI operation at a time per process and responds to ping independently.

Browser clients need explicit extension-ID registration. Native clients omit the browser origin argument. MacHelper is a per-user local executable, not an authentication boundary against other applications already running as that user.

Do not auto-send, auto-paste, collect entire documents, or log private content. Treat all selected/source text as untrusted input; display it as text, not executable HTML. Keep provider settings UI in MacHelper so more tools can share one configuration.
