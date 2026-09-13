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
        ),

        // CM-20 · Schicht 1: das D-Bus-Wire-Protokoll. Hängt an nichts außer
        // Foundation und Glibc — kein GTK, kein libdbus, keine
        // Fremdabhängigkeit im Paket.
        .target(name: "DBusWire")
    ]
)
