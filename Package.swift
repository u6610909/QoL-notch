// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QoLNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "QoLNotch", path: "Sources/QoLNotch"),
        .testTarget(name: "QoLNotchTests", dependencies: ["QoLNotch"], path: "Tests/QoLNotchTests"),
    ]
)
