// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AISwitcher",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AISwitcher",
            path: "Sources/AISwitcher",
            resources: [
                .copy("Resources/codex.icns"),
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "AISwitcherTests",
            dependencies: ["AISwitcher"]
        )
    ]
)
