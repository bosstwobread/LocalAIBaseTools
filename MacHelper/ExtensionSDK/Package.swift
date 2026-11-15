// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHelperExtensionSDK",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MacHelperExtensionSDK", targets: ["MacHelperExtensionSDK"])],
    targets: [.target(name: "MacHelperExtensionSDK", publicHeadersPath: "include")]
)
