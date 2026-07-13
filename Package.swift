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
        .executable(name: "ping-cli", targets: ["ping-cli"]),
    ],
    dependencies: [
        // Documentation build plugin only; PingKit has no runtime dependencies.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(name: "PingKit"),
        .executableTarget(name: "ping-cli", dependencies: ["PingKit"]),
        .testTarget(name: "PingKitTests", dependencies: ["PingKit"]),
    ]
)
