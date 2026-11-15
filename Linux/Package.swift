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
        .package(path: "../Shared"),
        // CM-36: die EINE Fremdabhängigkeit des Pakets — nur für die
        // Ed25519-Prüfung des Update-Manifests im Ziel `Update`. Exakt
        // gepinnt; die transitive `swift-asn1` pinnt `Package.resolved`
        // (versioniert, `.gitignore`-Ausnahme). Statisch gebunden hält das
        // Release-Binary die ldd-Sollmenge (gemessen, CM-36 Spec §7 M1–M3).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
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
        // Fremdabhängigkeit in diesem Ziel (die einzige des Pakets,
        // `swift-crypto`, hängt nur an `Update`, CM-36).
        .target(name: "DBusWire"),

        // CM-20 · Schicht 2: der EINE Übersetzungspunkt von
        // `MonitorViewState` auf Beschriftung, Symbol und Menü. Framework-frei
        // und ohne Socket — deshalb im Testziel prüfbar. Nach Auflage 12
        // gehört auch die Abbildung auf D-Bus-Werte hierher und nicht ins
        // Programm, sonst bliebe der inhaltsreichste Teil der Karte ungetestet.
        .target(
            name: "TrayPresentation",
            dependencies: [
                // CM-30: der Menüeintrag „Start at login" braucht die
                // Zustandsabbildung (`AutostartStatus.Reading`) und den
                // Unit-Namen für den Masken-Hinweis — aus EINER Quelle.
                // Kein Zyklus: `Autostart` hängt nur an `ClaudeMonitorShared`.
                "Autostart",
                // CM-37: Timer-Name für den Masken-Hinweis aus EINER Quelle
                // (`UpdateUnits.timerName`). Kein Zyklus: `Update` hängt nur
                // an `Autostart`.
                "Update",
                "DBusWire",
                .product(name: "ClaudeMonitorCore", package: "Core"),
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        ),

        // CM-21 · dieselbe Schicht wie `TrayPresentation`: die REGELN des
        // systemd-Nutzerdienstes — Pfadauflösung aus einem injizierten
        // Environment, Unit-Text, Auswertung von `systemctl is-enabled`,
        // Entscheidungstabelle und alle kundensichtbaren Texte. Kein
        // Dateizugriff, kein Prozessstart; beides liegt im Programm-Ziel.
        .target(
            name: "Autostart",
            dependencies: [
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        ),

        // CM-29 · dieselbe Schicht wie `Autostart`: die REGELN des
        // Linux-Auto-Updates — Adressen, Manifest-Prüfung, Versionsvergleich,
        // Abbildung der Werkzeug-Rückgabecodes, Unit-Texte von Timer und
        // Service und alle kundensichtbaren Texte. Kein Dateizugriff, kein
        // Prozessstart, kein Netz; das liegt im Programm-Ziel (`UpdateClient`).
        // Kein Zyklus: `Autostart` hängt nur an `ClaudeMonitorShared`; die
        // Abhängigkeit trägt die EINE Quoting-Regel für `ExecStart=`
        // (`AutostartUnit.execStartValue`) — eine Kopie liefe auseinander.
        //
        // CM-36: dazu die Signaturprüfung des Manifests (`UpdateSignature`)
        // über `Crypto` aus `swift-crypto` — Ed25519, ohne I/O.
        .target(
            name: "Update",
            dependencies: [
                "Autostart",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),

        // CM-43 · dieselbe Schicht wie `Autostart`: die GNOME-Extension als
        // Nutzlast im Binary plus ihre Regeln — Pfade, Zeilenlisten-Format von
        // `gsettings` (`parseStrv`/`renderStrv`), Plan für `enabled-extensions`
        // und alle kundensichtbaren Texte. Kein Dateizugriff, kein
        // Prozessstart; beides liegt im Programm-Ziel (`GnomeExtensionInstaller`).
        //
        // Gemessen (Spec CM-43 §7 M1–M4): `.embedInCode` je EINZELDATEI über
        // `../../Extension/<Datei>` baut und liefert gleiche Bytes. Ein
        // Verzeichnis außerhalb des Zielordners scheitert („Is a directory"),
        // deshalb kein Verzeichnis-Eintrag und `tests/` bleibt draußen. Die
        // Namen werden flachgelegt (`extension_js`), `PackageResources` ist
        // `internal` (→ `GnomeExtensionPayload` als öffentliche Hülle), die
        // ldd-Menge des Release-Binaries bleibt bei 6 Sonamen.
        .target(
            name: "GnomeExtension",
            dependencies: ["Autostart"],
            resources: [
                .embedInCode("../../Extension/extension.js"),
                .embedInCode("../../Extension/metadata.json"),
                .embedInCode("../../Extension/popoverState.js"),
                .embedInCode("../../Extension/stylesheet.css"),
                .embedInCode("../../Extension/stylesheet-dark.css"),
                .embedInCode("../../Extension/stylesheet-light.css"),
                .embedInCode("../../Extension/schemas/org.gnome.shell.extensions.claudemonitor.gschema.xml")
            ]
        ),

        // CM-20 · Schicht 3: Socket, Registrierung, Ereignisschleife des
        // residenten Tray-Prozesses. Seit CM-26 ist das **nicht** mehr
        // gleichbedeutend mit „ungeprüft": Die Bus-Attrappe in `TrayTests`
        // (`FakeSessionBus.swift`) ist ein echter `AF_UNIX`-Server im
        // Testprozess, gegen den diese Schicht laufen kann — prüfbar ist
        // davon, was nicht `private` ist.
        .executableTarget(
            name: "claude-monitor-tray",
            dependencies: [
                "Autostart",
                "DBusWire",
                "GnomeExtension",
                "TrayPresentation",
                "Update",
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
                "Autostart",
                "DBusWire",
                "GnomeExtension",
                "TrayPresentation",
                "Update",
                // CM-26: das Executable-Ziel selbst. Ohne diese Abhängigkeit
                // bliebe `TrayProcess` aus dem Testkontext unerreichbar und die
                // Bus-Attrappe hätte nichts, womit sie sprechen könnte.
                "claude-monitor-tray",
                .product(name: "ClaudeMonitorCore", package: "Core"),
                .product(name: "ClaudeMonitorShared", package: "Shared")
            ]
        )
    ]
)
