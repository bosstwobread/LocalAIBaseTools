import Foundation

/// App-independent startup decisions, separated from ServiceManagement so tests
/// never change a user's Login Items or system authorization.
public enum LoginStartupStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable
}

public enum LoginInitialSetupAction: Equatable, Sendable {
    case none
    case recordComplete
    case register
}

public enum LoginStartupPolicy {
    public static func initialSetupAction(completed: Bool, isLoginLaunch: Bool,
                                          isInstalledApplication: Bool,
                                          status: LoginStartupStatus) -> LoginInitialSetupAction {
        guard !completed, !isLoginLaunch, isInstalledApplication else { return .none }
        switch status {
        case .notRegistered, .notFound: return .register
        case .enabled, .requiresApproval: return .recordComplete
        case .unavailable: return .none
        }
    }

    /// Development/scratch bundles must not register themselves at login.
    /// Only the installed app in an Applications directory gets the default.
    public static func isInstalledApplication(_ applicationURL: URL, homeDirectory: URL) -> Bool {
        let application = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard application.pathExtension.lowercased() == "app" else { return false }
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
        return roots.contains {
            let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return application.path.hasPrefix(root + "/")
        }
    }

    /// Apple documents the 'lgit' launch reason in the 'prdt' parameter of the
    /// 'aevt'/'oapp' Apple event. --login exercises the same silent path in tests.
    /// https://developer.apple.com/documentation/coreservices/apple_events/1556410-launch_apple_event_constants
    public static func isLoginLaunch(arguments: [String], eventClass: UInt32?,
                                     eventID: UInt32?, launchReason: UInt32?) -> Bool {
        if arguments.contains("--login") { return true }
        return eventClass == 0x61657674 && eventID == 0x6f617070 && launchReason == 0x6c676974
    }
}
