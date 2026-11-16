# MacHelper native worker SDK

`MacHelperNativeSDK.swift` is a standalone Swift source SDK for native extensions
in MacHelper 6.0+. It is compiled with the extension's single declared `.swift`
entry point. The app bundles this SDK; extension authors need no private host
module or SDK copy inside their package.

A schema-version-two manifest declares `runtime: "native"`, the Swift
`entryPoint`, commands, shared settings schema, and `native.execute` permission.
Use the same Extensions list, installer, settings editor, and Reload control as
JavaScript tools. Native code runs as trusted code in a separate
`MacHelperNativeWorker` process, with the current user's OS access. This is not
an OS sandbox; review code before enabling it.

Call `MacHelperNative.run(commands:start:stop:)` from an `@main` entry point. A
command receives `MacHelperNativeInput` with `text`, optional `sentence`, and
`settings`. Use `readText(_:)` for frozen resources,
`transform(request:onProgress:)` for the shared AI connection, and
`reportProgress(text:title:)` for the shared floating panel. AI and progress
require declared permissions and a currently active invocation. `start` receives
settings; `stop` cancels extension-owned work. Never print to stdout, which is
reserved for bounded framed IPC.

A complete user-editable prompt should be passed unchanged as `systemPrompt`,
with selected content supplied separately as `text`. Standard output, logs,
preferences, and resources must not become histories of selected text or AI
answers. Compile hooks, shell commands, and dependency installation are not part
of this SDK. Apple Swift command-line tools are required to compile source.

Code edits build/sign a fresh executable before its worker replaces the running
one. Resources/settings can reuse compiled code and receive a new frozen
runtime snapshot. A failed build/start retains the last working worker.
Watchers run only for enabled tools; disabled tools read saved changes when
enabled again. See [Native Greeting](../../examples/NativeGreeting/README.md)
and the public [native extension guide](../../docs/Native-Extensions.md).
