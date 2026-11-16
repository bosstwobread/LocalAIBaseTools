# Legacy MacHelper bundle SDK

This schema-1 Objective-C/AppKit interface is retained for isolated CLI verification and migration reference. MacHelper 6 does not load or auto-start these bundles in its normal app flow, and the separate Native Plug-ins settings interface has been removed.

New native tools use the unified schema-2 source format with `runtime: "native"`, one Swift entry, `native.execute`, and the standalone [native worker SDK](../NativeExtensionSDK/README.md). See [Native source extensions](../../docs/Native-Extensions.md) for current authoring and runtime migration.

The old declaration-only [MacHelperExtensionSDK.h](Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h) describes a trusted in-process `.machextension` bundle whose principal class implements `MacHelperExtension`. Its context exposes a helper path, settings directory, host version, and UI callbacks. Its `makeSettingsViewController` returns an `NSViewController` for in-process embedding. Those objects cannot be passed directly to the new separate worker; migrate settings into `settings.schema.json` and move command logic into `MacHelperNative.run`.

The old [External Greeting fixture](../../examples/ExternalGreeting/README.md) and `scripts/test-extension-plugin.py` still exercise the historical factory/start/stop/settings contract with isolated state. They are not the installation path for current extensions and do not make an old loaded bundle hot reload.
