// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitorLinux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-monitor", targets: ["claude-monitor"]),
        // CM-20: der residente Tray-Prozess. Eigenes Product neben der
        // Rauchprobe, nicht an ihrer Stelle — die Rauchprobe bleibt das
        // Werkzeug, mit dem sich die Datenkette ohne Oberfläche prüfen lässt.
        .executable(name: "claude-monitor-tray", targets: ["claude-monitor-tray"])
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
        .target(name: "DBusWire"),

        // CM-20 · Schicht 2: der EINE Übersetzungspunkt von
        // `MonitorViewState` auf Beschriftung, Symbol und Menü. Framework-frei
        // und ohne Socket — deshalb im Testziel prüfbar. Nach Auflage 12
        // gehört auch die Abbildung auf D-Bus-Werte hierher und nicht ins
        // Programm, sonst bliebe der inhaltsreichste Teil der Karte ungetestet.
        .target(
            name: "TrayPresentation",
            dependencies: [
                "DBusWire",
                .product(name: "ClaudeMonitorCore", package: "Core"),
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        ),

        // CM-20 · Schicht 3: Socket, Registrierung, Ereignisschleife. Hier
        // steht nur, was sich ohne lebende Sitzung nicht prüfen lässt.
        .executableTarget(
            name: "claude-monitor-tray",
            dependencies: [
                "DBusWire",
                "TrayPresentation",
                .product(name: "ClaudeMonitorCore", package: "Core"),
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        ),

        // CM-20 · Nachweis. Die dritte Zahl der Linux-Testbasis (Auflage 17)
        // entsteht hier; gefüllt wird der Platz vom Test-Auftrag nach dem
        // Verify-Gate.
        .testTarget(
            name: "TrayTests",
            dependencies: [
                "DBusWire",
                "TrayPresentation",
                .product(name: "ClaudeMonitorCore", package: "Core"),
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        )
    ]
)
