// swift-tools-version: 6.0
import PackageDescription

// Gemeinsame Schicht zwischen Menüleisten-App und WidgetKit-Extension:
// Snapshot-Transport über den App-Group-Container und alle Anzeigeregeln
// (Prozentformat, Ampeltext, Restzeit-Zustände).
//
// Bewusst ein eigenes Paket neben `Core`:
//
// 1. Die Widget-Extension braucht **exakt dieselbe** Formatierung wie die
//    Menüleiste. Läge sie im App-Target, müsste die Extension sie nachbauen —
//    und zwei Kopien laufen garantiert auseinander.
// 2. Framework-frei und ohne Test-Host testbar: `swift test` statt eines
//    Xcode-Testrunners, der eine LSUIElement-App als Host starten müsste.
//
// `Core` bleibt unverändert und weiß von dieser Schicht nichts.
let package = Package(
    name: "ClaudeMonitorShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeMonitorShared", targets: ["ClaudeMonitorShared"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "ClaudeMonitorShared",
            dependencies: [.product(name: "ClaudeMonitorCore", package: "Core")]
        ),
        .testTarget(
            name: "ClaudeMonitorSharedTests",
            dependencies: ["ClaudeMonitorShared"]
        ),
    ]
)
