// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitorLinux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-monitor", targets: ["claude-monitor"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Shared")
    ],
    targets: [
        .executableTarget(
            name: "claude-monitor",
            dependencies: [
                .product(name: "ClaudeMonitorCore", package: "Core"),
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        )
    ]
)
