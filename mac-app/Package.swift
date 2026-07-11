// swift-tools-version:5.9
import PackageDescription

// Native menu-bar app that replaces the old Python `bridge/`. It reads the
// local Claude Code / Codex CLI session logs and serves a /status JSON endpoint
// the ESP8266 clock polls. Uses system frameworks (AppKit, Network,
// Foundation) plus Sparkle (vendored locally under Vendor/) for in-app updates.
let package = Package(
    name: "AIClockBridge",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AIClockBridge",
            dependencies: [
                .target(name: "Sparkle"),
            ],
            path: "Sources/AIClockBridge",
            resources: [.process("Resources")]
        ),
        .binaryTarget(
            name: "Sparkle",
            path: "Vendor/Sparkle.xcframework"
        ),
        .testTarget(
            name: "AIClockBridgeTests",
            dependencies: ["AIClockBridge"],
            path: "Tests/AIClockBridgeTests"
        ),
    ]
)
