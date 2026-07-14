// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PingKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "PingKit", targets: ["PingKit"]),
        // Named pingkit-cli because a product named "pingkit" collides with
        // the PingKit library target on case-insensitive file systems
        // (Xcode derives per-target build directories from these names).
        .executable(name: "pingkit-cli", targets: ["PingKitCLI"]),
    ],
    dependencies: [
        // Neither dependency is linked into the PingKit library target.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .target(name: "PingKit"),
        .executableTarget(
            name: "PingKitCLI",
            dependencies: [
                "PingKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "PingKitTests", dependencies: ["PingKit"]),
        .testTarget(name: "PingKitCLITests", dependencies: ["PingKitCLI"]),
    ]
)
