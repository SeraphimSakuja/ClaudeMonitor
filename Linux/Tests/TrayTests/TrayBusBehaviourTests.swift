import Foundation
import Testing
import DBusWire
import TrayPresentation
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

    /// Überschreibt die Store-Ablage des temporären Homes mit **einem**
    /// Account. Schema wie im echten Store (`schemaVersion 2`, `lastGood`,
    /// `fetchedAt` als Unix-Zeit).
    private func schreibeEinenAccount(in home: URL, fetchedAt: Date) throws {
        let json = """
        {
          "schemaVersion": 2,
          "accounts": {
            "1": {
              "email": "user1@example.com",
              "lastGood": { "five_hour": { "pct": 10.0 } },
              "fetchedAt": \(fetchedAt.timeIntervalSince1970)
            }
          }
        }
        """
        try Data(json.utf8).write(
            to: home.appending(path: ".claude-swap-backup")
                .appending(path: "cache")
                .appending(path: "usage.json")
        )
    }

    private static let registerRuf = "org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem"
    private static let layoutRuf = "com.canonical.dbusmenu.LayoutUpdated"
    private static let eigenschaftenRuf = "com.canonical.dbusmenu.ItemsPropertiesUpdated"

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

    /// R-001 — `LayoutUpdated` ist ein Signal über die **Struktur** des Menüs:
    /// Es kommt genau dann, wenn sich die Menüstruktur ändert, und sonst nie.
    /// Der Lesevorgang allein — gleiche Datei, gleicher Inhalt — ist keine
    /// Änderung.
    ///
    /// Die Δ der `now`-Werte bleibt weit unter `AccountStatusLine.staleThreshold`
    /// (300 s), damit keine Statuszeile über die Alterung selbst eine
    /// Struktur-Änderung erzeugt.
    @Test("Menü-Struktur unverändert ⇒ kein LayoutUpdated; ein Account kommt hinzu ⇒ genau eines")
    func layoutUpdatedNurBeiStrukturAenderung() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }

        let home = try temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let t0 = Date()
        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: t0
        )

        // Erster Lesevorgang, Datei unverändert: derselbe leere Store.
        prozess.refresh(now: t0.addingTimeInterval(1))

        // `refresh` ruft `publish` synchron auf; asynchron ist nur das
        // Schreiben auf den Socket. Deshalb zusätzlich zur Sofortprüfung eine
        // faire Frist, wie bei der Watcher-Abgang-Gegenprobe in R-002.
        _ = warteBis(1) { !bus.gesehen(ruf: Self.layoutRuf).isEmpty }
        #expect(
            bus.gesehen(ruf: Self.layoutRuf).isEmpty,
            "LayoutUpdated ohne Struktur-Änderung: \(bus.gesehen(ruf: Self.layoutRuf).count)"
        )

        // Jetzt kommt ein Account hinzu — das ist eine Struktur-Änderung.
        try schreibeEinenAccount(in: home, fetchedAt: t0)
        prozess.refresh(now: t0.addingTimeInterval(2))

        #expect(
            warteBis { bus.gesehen(ruf: Self.layoutRuf).count == 1 },
            "erwartet: genau ein LayoutUpdated, gezählt: \(bus.gesehen(ruf: Self.layoutRuf).count)"
        )

        let signale = bus.gesehen(ruf: Self.layoutRuf)
        #expect(signale.count == 1)
        if let signal = signale.first {
            var leser = signal.bodyReader()
            _ = try? leser.readUInt32()             // Revision
            #expect((try? leser.readInt32()) == TrayMenuIdentifiers.root)
        }

        // Die beiden Zweige in `publish(_:)` schließen sich gegenseitig aus:
        // zur Struktur-Änderung gehört KEIN ItemsPropertiesUpdated.
        #expect(
            bus.gesehen(ruf: Self.eigenschaftenRuf).isEmpty,
            "ItemsPropertiesUpdated begleitete die Struktur-Änderung: \(bus.gesehen(ruf: Self.eigenschaftenRuf).count)"
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
