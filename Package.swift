// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchConsole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LaunchConsole", targets: ["LaunchConsole"]),
    ],
    targets: [
        // Everything that talks to launchd or reads plists. No UI, fully unit-tested.
        .target(name: "LaunchdKit"),
        .executableTarget(name: "LaunchConsole", dependencies: ["LaunchdKit"]),
        .testTarget(
            name: "LaunchdKitTests",
            dependencies: ["LaunchdKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
