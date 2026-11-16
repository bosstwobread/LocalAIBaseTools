# External Greeting — legacy bundle fixture

This example is an independently buildable schema-1 bundle retained for isolated CLI verification and migration reference. MacHelper 6 does not load or auto-start this format in the normal app. It demonstrates lifecycle callbacks, an embedded settings view, a private counter preference, and a button that opens the host's AI settings. It makes no network or AI calls and requests no system permissions.

It needs the public `MacHelperExtensionSDK.h` header and the macOS command-line tools. It does not import MacHelper source, link a MacHelper Swift module, or create an `.app`.

From the repository root:

```sh
python3 examples/ExternalGreeting/build.py \
  --sdk-header MacHelper/ExtensionSDK/Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h \
  --output /tmp/ExternalGreeting.machextension
```

The output must not already exist. Use `--sign-identity 'YOUR SIGNING IDENTITY'` for your own distribution build; the default is local ad-hoc signing for development. Copy this entire example folder anywhere else and pass a separately copied SDK header to build it outside the repository.

For a current installable native tool, use the schema-2 [Native Greeting source example](../NativeGreeting/README.md) and [native worker guide](../../docs/Native-Extensions.md). The old embedded `NSViewController` settings need schema-based migration; changing a bundle name or manifest flag does not convert this fixture into a worker. The separate Native Plug-ins interface has been removed.

For isolated verification that installs nothing in your account:

```sh
python3 scripts/test-extension-plugin.py
python3 scripts/test-extension-plugin.py \
  --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The script copies the example and just the public SDK header into a temporary directory outside this repository, builds it there, loads its principal class, tests lifecycle/settings/persistence with a stub context, and optionally verifies the real MacHelper registry with isolated preferences.

See [Native source extensions](../../docs/Native-Extensions.md) for the current contract and legacy migration.
