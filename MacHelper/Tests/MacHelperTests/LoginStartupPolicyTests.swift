import Foundation
import XCTest
@testable import MacHelper

final class LoginStartupPolicyTests: XCTestCase {
    func testFirstManualInstalledLaunchRegistersTheRequestedDefault() {
        // A first-time SMAppService may report either state before register().
        for status: LoginStartupStatus in [.notRegistered, .notFound] {
            XCTAssertEqual(LoginStartupPolicy.initialSetupAction(completed: false, isLoginLaunch: false,
                                                                isInstalledApplication: true,
                                                                status: status), .register)
        }
    }

    func testCompletedSetupNeverReenablesAUserDisabledItem() {
        for status: LoginStartupStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unavailable] {
            XCTAssertEqual(LoginStartupPolicy.initialSetupAction(completed: true, isLoginLaunch: false,
                                                                isInstalledApplication: true, status: status), .none)
        }
    }

    func testLoginLaunchAndDevelopmentBuildsDoNotAutomaticallyRegister() {
        XCTAssertEqual(LoginStartupPolicy.initialSetupAction(completed: false, isLoginLaunch: true,
                                                            isInstalledApplication: true,
                                                            status: .notRegistered), .none)
        XCTAssertEqual(LoginStartupPolicy.initialSetupAction(completed: false, isLoginLaunch: false,
                                                            isInstalledApplication: false,
                                                            status: .notRegistered), .none)
    }

    func testExistingRegistrationAndApprovalStateAreRespected() {
        for status: LoginStartupStatus in [.enabled, .requiresApproval] {
            XCTAssertEqual(LoginStartupPolicy.initialSetupAction(completed: false, isLoginLaunch: false,
                                                                isInstalledApplication: true, status: status), .recordComplete)
        }
        XCTAssertEqual(LoginStartupPolicy.initialSetupAction(completed: false, isLoginLaunch: false,
                                                            isInstalledApplication: true, status: .unavailable), .none)
    }

    func testOnlyInstalledApplicationsDirectoriesQualifyForTheDefault() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        for path in ["/Applications/MacHelper.app", "/Applications/Tools/MacHelper.app",
                     "/Users/fixture/Applications/LocalAIBaseTools/MacHelper.app"] {
            XCTAssertTrue(LoginStartupPolicy.isInstalledApplication(URL(fileURLWithPath: path), homeDirectory: home), path)
        }
        for path in ["/tmp/MacHelper.app", "/Users/fixture/Project/dist/MacHelper.app",
                     "/Users/fixture/ApplicationsOther/MacHelper.app", "/ApplicationsOther/MacHelper.app",
                     "/Applications/MacHelper", "/Users/another/Applications/MacHelper.app"] {
            XCTAssertFalse(LoginStartupPolicy.isInstalledApplication(URL(fileURLWithPath: path), homeDirectory: home), path)
        }
    }

    func testTheLoginAppleEventAndExplicitFixtureFlagUseSilentStartup() {
        XCTAssertTrue(LoginStartupPolicy.isLoginLaunch(arguments: ["MacHelper", "--login"],
                                                      eventClass: nil, eventID: nil, launchReason: nil))
        XCTAssertTrue(LoginStartupPolicy.isLoginLaunch(arguments: ["MacHelper"],
                                                      eventClass: 0x61657674, eventID: 0x6f617070, launchReason: 0x6c676974))
        XCTAssertFalse(LoginStartupPolicy.isLoginLaunch(arguments: ["MacHelper"],
                                                       eventClass: nil, eventID: nil, launchReason: nil))
        XCTAssertFalse(LoginStartupPolicy.isLoginLaunch(arguments: ["MacHelper"],
                                                       eventClass: 0x61657674, eventID: 0x6f617070, launchReason: 0x73766963))
        XCTAssertFalse(LoginStartupPolicy.isLoginLaunch(arguments: ["MacHelper"],
                                                       eventClass: 0x61657674, eventID: 0x72617070, launchReason: 0x6c676974))
    }
}
