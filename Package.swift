// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentTracker",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AgentTracker",
            path: "Sources/AgentTracker"
        )
    ]
)
