import AppKit
import MacHelperExtensionSDK

/// Version-one Objective-C entry point loaded by MacHelper. Only the public SDK
/// crosses the boundary; this package does not import the helper implementation.
@MainActor
@objc(TranslationExtension)
public final class TranslationExtension: NSObject, @preconcurrency MacHelperExtension {
    private let controller = TranslationController()
    private var context: (any MacHelperExtensionContext)?

    public static func makeExtension() -> any MacHelperExtension {
        TranslationExtension()
    }

    public func start(context: any MacHelperExtensionContext) {
        self.context = context
        controller.configure(helperExecutableURL: URL(fileURLWithPath: context.helperExecutablePath),
                             settingsDirectory: URL(fileURLWithPath: context.settingsDirectory, isDirectory: true))
        controller.onOpenAISettings = { [weak context] in context?.openAISettings() }
        controller.onPresentOverlay = { [weak context] in context?.hideSettings() }
        controller.start()
    }

    public func stop() {
        controller.stop()
        controller.onOpenAISettings = nil
        controller.onPresentOverlay = nil
        context = nil
    }

    public func makeSettingsViewController() -> NSViewController {
        controller.makeSettingsViewController()
    }
}
