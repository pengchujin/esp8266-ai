// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIClockUSB",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "aiclock-usb",
            path: ".",
            sources: [
                "usb-cli/main.swift",
                "mac-app/Sources/AIClockBridge/CodexPetPackage.swift",
                "mac-app/Sources/AIClockBridge/StatusReader.swift",
                "mac-app/Sources/AIClockBridge/UsageFetcher.swift",
            ]
        )
    ]
)
