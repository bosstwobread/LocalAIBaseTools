# MacHelper Extension SDK

The version-one native extension contract is a small Objective-C header imported by Swift or Objective-C. It uses Foundation and AppKit types, so extensions do not link MacHelper's implementation or depend on its private Swift ABI. The SDK adds no implementation classes or shared dynamic library to distribute.

An independently built `.machextension` bundle supplies an `NSPrincipalClass` implementing `MacHelperExtension`. MacHelper calls the factory, starts the instance with a typed `MacHelperExtensionContext`, and embeds the extension's settings view controller in its Extensions window. Lifecycle and settings methods run on the main thread. The context exposes the installed helper path, a private per-extension settings directory, the host version, and callbacks to show AI settings or hide the settings window.

External extensions are discovered without loading their code. The user enables an extension before MacHelper loads it. External executable/manifest changes require enabling the new version again. Native extensions run trusted code inside the app; this interface is not a sandbox.

See [the development guide](../../docs/Extension-Development.md) for the manifest, packaging, example, and independent integration check. The full API is in [MacHelperExtensionSDK.h](Sources/MacHelperExtensionSDK/include/MacHelperExtensionSDK.h).
