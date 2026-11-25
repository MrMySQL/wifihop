// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WiFiHop",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RoamCore"),
        .executableTarget(name: "WiFiHop", dependencies: ["RoamCore"]),
        .testTarget(name: "RoamCoreTests", dependencies: ["RoamCore"]),
    ]
)
