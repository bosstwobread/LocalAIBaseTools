// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageHelper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MessageHelperCore", targets: ["MessageHelperCore"]),
        .executable(name: "message-helper-host", targets: ["MessageHelperHost"])
    ],
    targets: [
        .target(name: "MessageHelperCore"),
        .executableTarget(name: "MessageHelperHost", dependencies: ["MessageHelperCore"]),
        .testTarget(name: "MessageHelperCoreTests", dependencies: ["MessageHelperCore"])
    ],
    swiftLanguageModes: [.v5]
)
