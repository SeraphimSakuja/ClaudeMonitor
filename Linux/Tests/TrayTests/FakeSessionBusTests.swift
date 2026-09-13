import Foundation
import Testing
import DBusWire
@testable import claude_monitor_tray

// CM-26 · Selbstnachweis der Bus-Attrappe.
//
// Diese Datei prüft das Werkzeug, nicht die Anwendung: Ein `DBusConnection`
// aus dem Produktivpfad verbindet sich mit echtem `socket()`/`connect()`/
// SASL/Codec gegen `FakeSessionBus` — und die Zusicherungen hier beschreiben,
// worauf sich die späteren Verhaltenstests verlassen dürfen.
//
// Alle Zustandsprüfungen laufen über `warteBis`: Aufzeichnung und
// Zustandsänderung der Attrappe geschehen in ihren Server-Threads, eine
// Sofortprüfung wäre ein flackernder Test.

/// Pollt, bis `bedingung` zutrifft oder die Frist abgelaufen ist.
///
/// - Returns: `true`, wenn die Bedingung innerhalb der Frist eintrat.
func warteBis(_ frist: TimeInterval = 5, _ bedingung: () -> Bool) -> Bool {
    let ende = Date().addingTimeInterval(frist)
    while Date() < ende {
        if bedingung() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return bedingung()
}

/// Fehler der Testhilfen dieser Datei.
enum FakeSessionBusTestsFehler: Error {
    /// `/proc/self/status` enthielt keine lesbare `Threads:`-Zeile.
    case threadZahlUnlesbar
}

@Suite("CM-26 · Selbstnachweis der Bus-Attrappe", .serialized)
struct FakeSessionBusTests {

    /// Fall 1 — Handshake, `Hello` und eindeutige Namen.
    ///
    /// ⚠️ `DBusConnection.hello()` ist `private`; der Aufruf geschieht im
    /// Initialisierer. Geprüft wird deshalb `uniqueName` nach dem Aufbau —
    /// dieselbe Wirkung, nur ohne den (nicht erreichbaren) Einzelaufruf.
    @Test("Handshake läuft durch, jede Verbindung bekommt ihren eigenen Namen")
    func handshakeVergibtEindeutigeNamen() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let erste = try DBusConnection(socketPath: bus.socketPfad)
        defer { erste.close() }
        let zweite = try DBusConnection(socketPath: bus.socketPfad)
        defer { zweite.close() }

        #expect(erste.uniqueName == ":1.1")
        #expect(zweite.uniqueName == ":1.2")
        #expect(warteBis { bus.verbindungsZahl == 2 }, "Attrappe zählt \(bus.verbindungsZahl) statt 2 Verbindungen")
        #expect(warteBis { bus.gesehen(ruf: "org.freedesktop.DBus.Hello").count == 2 })
        #expect(bus.wachhundSchlug == false)
    }

    /// Fall 2 — `RequestName` mit `DO_NOT_QUEUE`: Absage statt Warteplatz,
    /// und der Besitz endet mit der Verbindung.
    @Test("Zweiter Anforderer bekommt exists statt inQueue, Besitz endet mit der Verbindung")
    func namensbesitzHaengtAnDerVerbindung() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let erste = try DBusConnection(socketPath: bus.socketPfad)
        let zweite = try DBusConnection(socketPath: bus.socketPfad)
        defer { zweite.close() }

        let name = TrayProcess.wellKnownName
        #expect(try erste.requestName(name) == .primaryOwner)
        #expect(try zweite.requestName(name) == .exists)
        #expect(bus.eigentuemer(von: name) == ":1.1")

        erste.close()
        #expect(
            warteBis { bus.eigentuemer(von: name) == nil },
            "Name blieb nach dem Schließen bei \(bus.eigentuemer(von: name) ?? "nil")"
        )
        #expect(bus.wachhundSchlug == false)
    }

    /// Fall 3 — `AddMatch`: das passende Signal wird zugestellt, das mit
    /// falschem `arg0` nicht.
    @Test("AddMatch stellt nur das Signal mit passendem arg0 zu")
    func addMatchFiltertNachArg0() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }

        // Wörtlich die Regel aus `TrayProcess.observeWatcher()`.
        verbindung.addMatch(
            "type='signal',sender='org.freedesktop.DBus',"
            + "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
            + "arg0='\(TrayProcess.watcherName)'"
        )
        #expect(warteBis { bus.abgelegteRegeln.count == 1 })

        bus.einspeisenNameOwnerChanged(
            name: "org.example.Fremd",
            alterEigentuemer: "",
            neuerEigentuemer: ":1.9"
        )
        // Nach `type == .signal` filtern: die `method_return`-Antwort auf
        // `AddMatch` kommt hier legitim mit herein.
        var signale = try eingehendeSignale(verbindung, durchgaenge: 5)
        #expect(signale.isEmpty, "unpassendes Signal wurde zugestellt: \(signale.map(\.callKey))")

        bus.einspeisenNameOwnerChanged(
            name: TrayProcess.watcherName,
            alterEigentuemer: "",
            neuerEigentuemer: ":1.9"
        )
        signale = try eingehendeSignale(verbindung, durchgaenge: 20, bisMindestens: 1)
        #expect(signale.count == 1)
        #expect(signale.first?.member == "NameOwnerChanged")
        #expect(bus.abgelegteRegeln.count == 1)
        #expect(bus.wachhundSchlug == false)
    }

    /// Fall 4 (a) — eine unbekannte Bus-Methode wird beantwortet, statt in die
    /// 5-Sekunden-Frist von `callBlocking` zu laufen.
    @Test("Unbekannte Bus-Methode kommt sofort als Fehlerantwort zurück")
    func unbekannteMethodeWirdBeantwortet() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }

        let beginn = Date()
        var fehler: DBusConnection.ConnectError?
        do {
            _ = try verbindung.callBlocking(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                member: "ListNames"
            )
        } catch let grund as DBusConnection.ConnectError {
            fehler = grund
        }
        let dauer = Date().timeIntervalSince(beginn)

        #expect(fehler == .errorReply, "erwartet: Fehlerantwort des Busses, bekommen: \(String(describing: fehler))")
        #expect(dauer < 2, "Antwort brauchte \(dauer) s — das ist die Zeitlimit-Frist, keine Fehlerantwort")
        #expect(bus.wachhundSchlug == false)
    }

    /// Fall 4 (b) — `stop()` räumt Socketdatei und Verbindungen ab.
    @Test("stop() entfernt die Socketdatei und schließt alle Verbindungen")
    func stopRaeumtAb() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }
        #expect(warteBis { bus.verbindungsZahl == 1 })

        bus.stop()
        #expect(warteBis { !FileManager.default.fileExists(atPath: bus.socketPfad) })
        #expect(bus.verbindungsZahl == 0)
    }

    /// Fall 4 (c) — Teardown ohne Klient und ohne `stop()`.
    ///
    /// ⚠️ Hier **kein** `defer { bus.stop() }`: Dass der Abbau auch ohne
    /// `stop()` läuft, ist genau die Zusicherung dieses Falls. Der Bus lebt
    /// deshalb nur im inneren Geltungsbereich.
    @Test("Teardown räumt auch ohne stop() ab — ohne Klient")
    func teardownOhneKlient() throws {
        let pfad = try { () -> String in
            let bus = try FakeSessionBus()
            try bus.start()
            #expect(FileManager.default.fileExists(atPath: bus.socketPfad))
            return bus.socketPfad
        }()

        // Warteschleife statt Sofortprüfung: der Abbau läuft verzögert auf
        // einem Server-Thread (gemessen: in ~10 % der Läufe existiert die
        // Datei im Moment des Austritts noch).
        #expect(
            warteBis(5) { !FileManager.default.fileExists(atPath: pfad) },
            "Socketdatei \(pfad) überlebte das Ende des Geltungsbereichs"
        )
    }

    /// Fall 4 (d) — Teardown ohne `stop()`, aber mit offener, aktiver
    /// Verbindung. Der Unterschied zu (c) ist die schwache Erfassung in den
    /// Verbindungsthreads.
    @Test("Teardown räumt auch ohne stop() ab — mit offener, aktiver Verbindung")
    func teardownMitOffenerVerbindung() throws {
        let (pfad, verbindung) = try { () -> (String, DBusConnection) in
            let bus = try FakeSessionBus()
            try bus.start()
            let verbindung = try DBusConnection(socketPath: bus.socketPfad)
            // `Hello` läuft im Initialisierer; ein zweiter Aufruf belegt, dass
            // die Verbindung wirklich bedient wird.
            _ = try verbindung.nameHasOwner(TrayProcess.wellKnownName)
            #expect(verbindung.uniqueName == ":1.1")
            return (bus.socketPfad, verbindung)
        }()
        defer { verbindung.close() }

        #expect(
            warteBis(5) { !FileManager.default.fileExists(atPath: pfad) },
            "Socketdatei \(pfad) überlebte das Ende des Geltungsbereichs trotz offener Verbindung"
        )
    }

    /// CM-26-B — die Attrappe darf sich über viele Läufe nicht anhäufen.
    ///
    /// Jede Instanz startet zwei Hintergrund-Threads (Accept-Schleife und
    /// Wachhund). Bleibt auch nur einer je Instanz stehen, wächst der
    /// Thread-Bestand mit der Zahl der Tests — und der Suite-Lauf wird über
    /// die Zeit unzuverlässig, ohne dass ein einzelner Test rot wird.
    @Test("50 Bus-Instanzen nacheinander gestartet und gestoppt hinterlassen nach Abklingen keine überzähligen Threads")
    func vieleInstanzenHinterlassenKeineThreads() throws {
        // Beide Messungen warten auf RUHE, nicht auf eine feste Frist: ein
        // Nachbartest kann Threads hinterlassen, die noch abbauen — eine
        // Sofort- oder Festfristmessung nähme diesen Überhang als
        // Ausgangswert und verglich ihn mit dem abgeklungenen Endwert
        // (gemessen: n0=14, n1=11 — rot ohne jedes Leck, nur
        // reihenfolgeabhängig).
        let n0 = try stabileThreadZahl()

        for _ in 0..<50 {
            let bus = try FakeSessionBus()
            try bus.start()
            bus.stop()
        }

        let n1 = try stabileThreadZahl()
        #expect(n1 == n0, "Threads vorher: \(n0), nachher: \(n1)")
    }

    // MARK: - Hilfen

    /// Liest die Zahl der Threads dieses Prozesses aus `/proc/self/status`.
    private func threadZahl() throws -> Int {
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        for zeile in status.split(separator: "\n") where zeile.hasPrefix("Threads:") {
            let wert = zeile.dropFirst("Threads:".count).trimmingCharacters(in: .whitespaces)
            if let zahl = Int(wert) { return zahl }
        }
        throw FakeSessionBusTestsFehler.threadZahlUnlesbar
    }

    /// Liest die Threadzahl, bis sie **steht**: zwei aufeinanderfolgende
    /// Messungen mit demselben Wert gelten als Ruhe, dieser Wert kommt zurück.
    ///
    /// Der Abstand liegt bewusst über der 250-ms-Zeitscheibe, mit der die
    /// Server-Threads der Attrappe ihr Halt-Signal prüfen — sonst könnten zwei
    /// Messungen innerhalb derselben Zeitscheibe zufällig gleich sein und
    /// mitten im Abbau „Ruhe" melden. Läuft die Frist ab, zählt der letzte
    /// Wert; der Test scheitert dann an seiner eigenen Zusicherung, nicht an
    /// der Messung.
    private func stabileThreadZahl(
        frist: TimeInterval = 5,
        abstand: TimeInterval = 0.3
    ) throws -> Int {
        let ende = Date().addingTimeInterval(frist)
        var vorherige = try threadZahl()
        while Date() < ende {
            Thread.sleep(forTimeInterval: abstand)
            let aktuelle = try threadZahl()
            if aktuelle == vorherige { return aktuelle }
            vorherige = aktuelle
        }
        return vorherige
    }

    /// Pumpt die Verbindung und sammelt die eingegangenen **Signale**.
    private func eingehendeSignale(
        _ verbindung: DBusConnection,
        durchgaenge: Int,
        bisMindestens: Int = 0
    ) throws -> [DBusMessage] {
        var gesammelt: [DBusMessage] = []
        for _ in 0..<durchgaenge {
            gesammelt += try verbindung.pump(timeoutMilliseconds: 100).filter { $0.type == .signal }
            if bisMindestens > 0 && gesammelt.count >= bisMindestens { break }
        }
        return gesammelt
    }
}
