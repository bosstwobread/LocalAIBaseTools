import AppKit
import ServiceManagement
import Carbon
import MacHelper

/// Registers MacHelper itself, rather than installing another login helper app.
/// The system remains the source of truth if the user later disables Login Items.
@MainActor
final class LoginItemManager {
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let homeDirectory: URL
    private let setupKey = "MacHelper.didConfigureLoginItem.v1"
    private var service: SMAppService { .mainApp }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.bundle = bundle
        self.homeDirectory = homeDirectory
    }

    var status: LoginStartupStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusMessage: String {
        switch status {
        case .notRegistered: return L("MacHelper will not open automatically.")
        case .enabled: return L("MacHelper starts in the background when you log in. Open Settings from its Dock icon or menu bar.")
        case .requiresApproval:
            return L("Allow MacHelper in System Settings → General → Login Items & Extensions.")
        case .notFound:
            return L("Launch at login is not set up yet. Enable it to register MacHelper.")
        case .unavailable: return L("The system could not determine MacHelper’s login status.")
        }
    }

    /// Call on an explicit installed-app launch, after the user has requested
    /// the default. A later user disablement is never silently reversed.
    @discardableResult
    func configureDefaultIfNeeded(isLoginLaunch: Bool) throws -> Bool {
        let action = LoginStartupPolicy.initialSetupAction(
            completed: defaults.bool(forKey: setupKey), isLoginLaunch: isLoginLaunch,
            isInstalledApplication: LoginStartupPolicy.isInstalledApplication(bundle.bundleURL,
                                                                               homeDirectory: homeDirectory),
            status: status)
        switch action {
        case .none: return false
        case .recordComplete:
            defaults.set(true, forKey: setupKey)
            return false
        case .register:
            try register()
            return true
        }
    }

    func register() throws {
        if status == .enabled || status == .requiresApproval {
            defaults.set(true, forKey: setupKey)
            return
        }
        do {
            try service.register()
            defaults.set(true, forKey: setupKey)
        } catch {
            // If the OS requires approval or the user has denied launch, keep
            // that decision instead of retrying automatically on every launch.
            let error = error as NSError
            if status == .requiresApproval || error.code == Int(kSMErrorLaunchDeniedByUser) {
                defaults.set(true, forKey: setupKey)
            }
            throw error
        }
    }

    func unregister() throws {
        if status != .notRegistered { try service.unregister() }
        defaults.set(true, forKey: setupKey)
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    static var isLoginLaunch: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return LoginStartupPolicy.isLoginLaunch(
            arguments: CommandLine.arguments, eventClass: event?.eventClass,
            eventID: event?.eventID,
            launchReason: event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue)
    }
}
