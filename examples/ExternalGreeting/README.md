# External Greeting

This example is an independently buildable native MacHelper extension. It demonstrates lifecycle callbacks, an embedded settings view, a private counter preference, and a button that opens the host's AI settings. It makes no network or AI calls and requests no system permissions.

It needs the public `MacHelperExtensionSDK.h` header and the macOS command-line tools. It does not import MacHelper source, link a MacHelper Swift module, or create an `.app`.

From the repository root:

```sh
python3 examples/ExternalGreeting/build.py \
  --sdk-header MacHelper/ExtensionSDK/Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h \
  --output /tmp/ExternalGreeting.machextension
```

The output must not already exist. Use `--sign-identity 'YOUR SIGNING IDENTITY'` for your own distribution build; the default is local ad-hoc signing for development. Copy this entire example folder anywhere else and pass a separately copied SDK header to build it outside the repository.

To try it interactively, open **MacHelper → Extensions → Install Extension…**, choose the built `.machextension`, and explicitly enable **External Greeting**. Its settings then appear inside MacHelper. Native extensions run trusted code in the host process; inspect the source before enabling a third-party extension.

For isolated verification that installs nothing in your account:

```sh
python3 scripts/test-extension-plugin.py
python3 scripts/test-extension-plugin.py \
  --host dist/MacHelper.app/Contents/MacOS/MacHelperApp
```

The script copies the example and just the public SDK header into a temporary directory outside this repository, builds it there, loads its principal class, tests lifecycle/settings/persistence with a stub context, and optionally verifies the real MacHelper registry with isolated preferences.

See [Extension Development](../../docs/Extension-Development.md) for the contract and packaging details.
