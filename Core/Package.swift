// swift-tools-version: 6.0
import PackageDescription

// Framework-freie Kernlogik: Parsing, Ranking, Statusfarben, Restzeiten.
// Bewusst ohne SwiftUI/WidgetKit, damit sie mit `swift test` ohne Xcode-Projekt
// getestet werden kann. App- und Widget-Targets liegen in ../App.
let package = Package(
    name: "ClaudeMonitorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeMonitorCore", targets: ["ClaudeMonitorCore"])
    ],
    targets: [
        .target(name: "ClaudeMonitorCore"),
        .testTarget(
            name: "ClaudeMonitorCoreTests",
            dependencies: ["ClaudeMonitorCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
