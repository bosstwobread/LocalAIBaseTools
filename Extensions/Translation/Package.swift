// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Translation",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Translation", type: .dynamic, targets: ["Translation"])],
    dependencies: [.package(path: "../../MacHelper/ExtensionSDK")],
    targets: [
        .target(name: "Translation", dependencies: [
            .product(name: "MacHelperExtensionSDK", package: "ExtensionSDK")
        ]),
        .testTarget(name: "TranslationTests", dependencies: ["Translation"])
    ],
    swiftLanguageModes: [.v5]
)
