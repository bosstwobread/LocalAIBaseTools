# Native Greeting

An independent native Swift extension for MacHelper 6.0 or later. Import this
folder with **MacHelper → Extensions → Install Source…** and enable it after
reviewing native execution access. Native code is trusted code with the current
user's OS access; a worker process is not an OS sandbox.

The sample uses a manual command for isolated developer verification; MacHelper
currently has no general manual-command launcher in Settings. It reports one
partial result and returns a greeting without reading the clipboard, making AI
requests, or requiring Accessibility.

`Main.swift` is compiled with MacHelper's bundled `MacHelperNativeSDK.swift`.
Apple's Swift command-line tools are required to compile edited native source.
There are no custom build scripts, external dependencies, or shell hooks. Save
changes in the installed source folder while enabled to rebuild and replace
only its worker. Disabled tools read saved changes when enabled again.
Changing ordinary resources/settings restarts the worker with a new frozen
snapshot and may reuse the cached executable. A build or startup failure keeps
the last working worker active. The host renders the settings schema directly.
