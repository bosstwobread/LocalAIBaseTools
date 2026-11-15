// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacHelper", targets: ["MacHelper"]),
        .executable(name: "mac-helper-host", targets: ["MacHelperHost"]),
        .executable(name: "MacHelperApp", targets: ["MacHelperApp"]),
        .executable(name: "MacHelperScriptWorker", targets: ["MacHelperScriptWorker"])
    ],
    dependencies: [.package(path: "ExtensionSDK")],
    targets: [
        .target(name: "MacHelper", dependencies: [.product(name: "MacHelperExtensionSDK", package: "ExtensionSDK")], path: "Runtime"),
        .executableTarget(name: "MacHelperHost", dependencies: ["MacHelper"], path: "Host"),
        .target(name: "MacHelperCapabilities", path: "Capabilities"),
        .executableTarget(name: "MacHelperScriptWorker", path: "ScriptWorker"),
        .executableTarget(name: "MacHelperApp", dependencies: ["MacHelper", "MacHelperCapabilities"], path: "App"),
        .testTarget(name: "MacHelperTests", dependencies: ["MacHelper"], path: "Tests/MacHelperTests"),
        .testTarget(name: "MacHelperCapabilityTests", dependencies: ["MacHelperCapabilities"], path: "Tests/MacHelperCapabilityTests")
    ],
    swiftLanguageModes: [.v5]
)
