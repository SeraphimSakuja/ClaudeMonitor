import Foundation
import Testing
import DBusWire
@testable import claude_monitor_tray

// CM-26 · R-002 — Verhalten des Tray-Prozesses am Bus.
//
// Der Registereintrag R-002 („kommt der Watcher zurück, meldet sich der Tray
// erneut an") wird hier abgelöst: Der echte `TrayProcess` läuft gegen die
// Bus-Attrappe, das Signal kommt über den Draht, und was der Tray daraufhin
// sendet, liest der Test aus der Aufzeichnung der Attrappe.
//
// Fachentscheid 10 der Karte: **temporäres Home je Test**, nie das echte —
// sonst läse der Test den Store des ausführenden Rechners.

@Suite("CM-26 · R-002: Tray-Verhalten am Bus", .serialized)
struct TrayBusBehaviourTests {

    /// Legt ein temporäres Home mit der Store-Ablage von claude-swap an
    /// (`<home>/.claude-swap-backup/cache/usage.json`).
    private func temporaeresHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm26-home-\(UUID().uuidString)", isDirectory: true)
        let cache = home.appending(path: ".claude-swap-backup").appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\": 2, \"accounts\": {}}".utf8)
            .write(to: cache.appending(path: "usage.json"))
        return home
    }

    private static let registerRuf = "org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem"

    /// R-002 — der Watcher kommt zurück, der Tray meldet sich erneut an; und
    /// er tut es **nicht**, wenn der Watcher geht (Fachentscheid 4).
    @Test("Watcher kommt zurück ⇒ genau eine erneute Anmeldung; Watcher geht ⇒ keine weitere")
    func watcherRueckkehrLoestGenauEineAnmeldungAus() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }

        let home = try temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: Date()
        )
        prozess.observeWatcher()
        #expect(warteBis { bus.abgelegteRegeln.count == 1 })

        // Watcher erscheint.
        bus.einspeisenNameOwnerChanged(
            name: TrayProcess.watcherName,
            alterEigentuemer: "",
            neuerEigentuemer: ":1.9"
        )
        try pumpen(verbindung, prozess, durchgaenge: 20, bis: {
            bus.gesehen(ruf: Self.registerRuf).count >= 1
        })

        let anmeldungen = bus.gesehen(ruf: Self.registerRuf)
        #expect(anmeldungen.count == 1, "erwartet: genau eine Anmeldung, gezählt: \(anmeldungen.count)")
        if let anmeldung = anmeldungen.first {
            #expect(anmeldung.path == TrayProcess.watcherPath)
            #expect(anmeldung.destination == TrayProcess.watcherName)
            var leser = anmeldung.bodyReader()
            #expect((try? leser.readString()) == TrayProcess.itemPath)
        }

        // Gegenprobe: der Watcher geht — kein weiteres Signal, nur interner
        // Zustand (Fachentscheid 4).
        bus.einspeisenNameOwnerChanged(
            name: TrayProcess.watcherName,
            alterEigentuemer: ":1.9",
            neuerEigentuemer: ""
        )
        try pumpen(verbindung, prozess, durchgaenge: 10, bis: { false })
        // Faire Frist für eine (unerwünschte) zweite Anmeldung: erst danach
        // ist „es kam keine" eine belastbare Aussage.
        _ = warteBis(1) { bus.gesehen(ruf: Self.registerRuf).count > 1 }

        #expect(
            bus.gesehen(ruf: Self.registerRuf).count == 1,
            "Abgang des Watchers löste eine weitere Anmeldung aus: \(bus.gesehen(ruf: Self.registerRuf).count)"
        )
        #expect(bus.wachhundSchlug == false)
    }

    /// Fährt die Pump-Schleife des Produktivpfads
    /// (`run(selftestDeadline:)` ist dafür ungeeignet — sie blockiert über ein
    /// globales Abbruchflag).
    private func pumpen(
        _ verbindung: DBusConnection,
        _ prozess: TrayProcess,
        durchgaenge: Int,
        bis fertig: () -> Bool
    ) throws {
        for _ in 0..<durchgaenge {
            for nachricht in try verbindung.pump(timeoutMilliseconds: 100) {
                prozess.handle(signal: nachricht)
            }
            if fertig() { return }
        }
    }
}
