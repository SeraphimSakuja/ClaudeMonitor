import Foundation
import Testing
import DBusWire
import Autostart
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

        let attrappe = SystemctlAttrappe(isEnabled: "disabled")
        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: Date(),
            environment: attrappe.umgebung(home: home),
            runner: attrappe
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
        let attrappe = SystemctlAttrappe(isEnabled: "disabled")
        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: t0,
            environment: attrappe.umgebung(home: home),
            runner: attrappe
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

    // MARK: - CM-30 · „Start at login" im Menü

    /// T1 — Terminal-Änderung wird beim Öffnen sichtbar, Abwählen entfernt.
    @Test("CM-30: Start at login — Terminal-Änderung beim Öffnen sichtbar, Abwählen entfernt")
    func startAtLogin_oeffnenZeigtTerminalAenderung_abwaehlenEntfernt() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()
        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }
        let home = try temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try schreibeEinenAccount(in: home, fetchedAt: Date())

        let attrappe = SystemctlAttrappe(isEnabled: "disabled", timerIsEnabled: "enabled")
        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: Date(),
            environment: attrappe.umgebung(home: home),
            runner: attrappe
        )

        // (a) direkt nach dem Start
        var menue = try layoutLesen(bus, verbindung, prozess)
        var index = try #require(menue.firstIndex { $0.label == "Start at login" }, "Menü: \(menue)")
        let eintrag = menue[index]
        #expect(eintrag.eigenschaften["toggle-type"] == .string("checkmark"))
        #expect(eintrag.eigenschaften["toggle-state"] == .int32(0))
        #expect(eintrag.eigenschaften["enabled"] == .bool(true))
        #expect(menue.indices.contains(index + 1) && menue[index + 1].label == "Automatic updates",
                "nach „Start at login“ folgt nicht „Automatic updates“: \(menue)")
        // CM-37 · FE 2: „Automatic updates“ liest den Timer, nicht die Autostart-Unit.
        let update = try #require(menue.first { $0.label == "Automatic updates" }, "Menü: \(menue)")
        #expect(update.eigenschaften["toggle-state"] == .int32(1), "Automatic updates: \(update)")
        #expect(update.eigenschaften["enabled"] == .bool(true))
        // CM-37 · FE 6: „Check for updates now“ liegt vor der Fußzeile.
        let pruefen = try #require(menue.firstIndex { $0.label == "Check for updates now" }, "Menü: \(menue)")
        let fusszeile = try #require(menue.firstIndex { $0.label?.hasPrefix("Checked ") == true }, "Menü: \(menue)")
        #expect(pruefen < fusszeile, "„Check for updates now“ nicht vor der Fußzeile: \(menue)")

        // (b) im Terminal eingerichtet, Menü geöffnet
        attrappe.isEnabled = "enabled"
        try ereignis(bus, verbindung, prozess, id: TrayMenuIdentifiers.root, art: "opened")
        _ = prozess.handleMenuEvents()
        menue = try layoutLesen(bus, verbindung, prozess)
        index = try #require(menue.firstIndex { $0.label == "Start at login" })
        #expect(menue[index].eigenschaften["toggle-state"] == .int32(1), "nach „opened“: \(menue[index])")

        // (b1) CM-34: eigene Unit zeigt auf das laufende Binary ⇒ kein Hinweis.
        let unitVerzeichnis = home.appendingPathComponent(".local/share/systemd/user", isDirectory: true)
        try FileManager.default.createDirectory(at: unitVerzeichnis, withIntermediateDirectories: true)
        let unitDatei = unitVerzeichnis.appendingPathComponent("claude-monitor-tray.service")
        func unitText(execStart: String) -> String {
            """
            # generated by claude-monitor-tray --install-autostart
            [Unit]
            Description=ClaudeMonitor tray icon

            [Service]
            ExecStart=\(execStart)

            [Install]
            WantedBy=graphical-session.target

            """
        }
        let laufendes = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        try unitText(execStart: AutostartUnit.execStartValue(for: laufendes)).write(to: unitDatei, atomically: true, encoding: .utf8)
        try ereignis(bus, verbindung, prozess, id: TrayMenuIdentifiers.root, art: "opened")
        _ = prozess.handleMenuEvents()
        menue = try layoutLesen(bus, verbindung, prozess)
        index = try #require(menue.firstIndex { $0.label == "Start at login" })
        #expect(menue[index].eigenschaften["toggle-state"] == .int32(1), "b1: \(menue[index])")
        #expect(menue.indices.contains(index + 1) && menue[index + 1].label == "Automatic updates",
                "b1: Hinweis beim eigenen Binary: \(menue)")

        // (b2) CM-34: Binary verschoben ⇒ Häkchen bleibt, Hinweiszeile folgt.
        try unitText(execStart: home.appendingPathComponent("bin-weg/claude-monitor-tray").path)
            .write(to: unitDatei, atomically: true, encoding: .utf8)
        try ereignis(bus, verbindung, prozess, id: TrayMenuIdentifiers.root, art: "opened")
        _ = prozess.handleMenuEvents()
        menue = try layoutLesen(bus, verbindung, prozess)
        index = try #require(menue.firstIndex { $0.label == "Start at login" })
        #expect(menue[index].eigenschaften["toggle-state"] == .int32(1), "b2: \(menue[index])")
        #expect(
            menue.indices.contains(index + 1) && menue[index + 1].label
                == "Autostart starts another binary — untick and tick again; details: claude-monitor-tray --autostart-status",
            "b2: Zeile unter „Start at login“: \(menue)"
        )

        // (c) Abwählen
        try ereignis(bus, verbindung, prozess, id: eintrag.id, art: "clicked")
        _ = prozess.handleMenuEvents()
        #expect(attrappe.aufrufe.contains("--user disable claude-monitor-tray.service"), "Aufrufe: \(attrappe.aufrufe)")
        #expect(!attrappe.aufrufe.contains { $0.hasPrefix("--user enable") }, "Aufrufe: \(attrappe.aufrufe)")
        menue = try layoutLesen(bus, verbindung, prozess)
        index = try #require(menue.firstIndex { $0.label == "Start at login" })
        #expect(menue[index].eigenschaften["toggle-state"] == .int32(0), "nach dem Klick: \(menue[index])")
        #expect(menue.indices.contains(index + 1) && menue[index + 1].label == "Automatic updates",
                "Hinweiszeile nach dem Abwählen: \(menue)")

        // (d) CM-37: „Automatic updates“ abwählen — nur der Timer wird ausgeschaltet.
        let updateEintrag = try #require(menue.first { $0.label == "Automatic updates" })
        try ereignis(bus, verbindung, prozess, id: updateEintrag.id, art: "clicked")
        _ = prozess.handleMenuEvents()
        #expect(attrappe.aufrufe.contains("--user disable claude-monitor-tray-update.timer"), "Aufrufe: \(attrappe.aufrufe)")
        #expect(!attrappe.aufrufe.contains { $0.hasPrefix("--user enable") && $0.hasSuffix("claude-monitor-tray-update.timer") },
                "Aufrufe: \(attrappe.aufrufe)")
        menue = try layoutLesen(bus, verbindung, prozess)
        index = try #require(menue.firstIndex { $0.label == "Automatic updates" })
        #expect(menue[index].eigenschaften["toggle-state"] == .int32(0), "nach dem Klick: \(menue[index])")
        #expect(menue.indices.contains(index + 1) && menue[index + 1].label == "Check for updates now",
                "unter „Automatic updates“ keine Hinweiszeile: \(menue)")
        let autostartZeile = try #require(menue.first { $0.label == "Start at login" })
        #expect(autostartZeile.eigenschaften["toggle-state"] == .int32(0), "Start at login: \(autostartZeile)")
    }

    /// J2 — „Check for updates now“: startet `--update`, sperrt während der
    /// Prüfung, zeigt das Ergebnis.
    @Test("CM-37: Check for updates now — startet --update, sperrt während der Prüfung, zeigt das Ergebnis")
    func checkForUpdatesNow_startetUpdate_sperrtWaehrendPruefung_zeigtErgebnis() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()
        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }
        let home = try temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try schreibeEinenAccount(in: home, fetchedAt: Date())

        let attrappe = SystemctlAttrappe(isEnabled: "disabled")
        let starter = StarterAttrappe()
        // Ohne XDG_RUNTIME_DIR: Nutzermanager nicht erreichbar.
        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: Date(),
            environment: ["HOME": home.path],
            runner: attrappe,
            starter: starter
        )

        // (1) immer sichtbar und bedienbar, obwohl „Automatic updates“ gesperrt ist.
        var menue = try layoutLesen(bus, verbindung, prozess)
        let automatisch = try #require(menue.first { $0.label == "Automatic updates" }, "Menü: \(menue)")
        #expect(automatisch.eigenschaften["enabled"] == .bool(false))
        let pruefen = try #require(menue.first { $0.label == "Check for updates now" }, "Menü: \(menue)")
        #expect(pruefen.eigenschaften["enabled"] == .bool(true))

        // (2) Klick startet genau ein Kind; während der Prüfung gesperrt, Zweitklick wirkungslos.
        try ereignis(bus, verbindung, prozess, id: pruefen.id, art: "clicked")
        _ = prozess.handleMenuEvents()
        #expect(starter.starts.count == 1, "Starts: \(starter.starts)")
        #expect(starter.starts.first?.arguments == ["--update"])
        #expect(starter.starts.first?.executable.hasPrefix("/") == true, "Starts: \(starter.starts)")
        menue = try layoutLesen(bus, verbindung, prozess)
        let eintrag = try #require(menue.first { $0.id == pruefen.id }, "Menü: \(menue)")
        #expect(eintrag.eigenschaften["enabled"] == .bool(false), "während der Prüfung: \(eintrag)")
        try ereignis(bus, verbindung, prozess, id: pruefen.id, art: "clicked")
        _ = prozess.handleMenuEvents()
        #expect(starter.starts.count == 1, "Zweitklick startete erneut: \(starter.starts)")

        // (3) Exit 13 ⇒ wieder bedienbar, Ergebniszeile „refused“.
        starter.pollErgebnis = .exited(13)
        prozess.pollUpdateCheck()
        menue = try layoutLesen(bus, verbindung, prozess)
        var index = try #require(menue.firstIndex { $0.id == pruefen.id }, "Menü: \(menue)")
        #expect(menue[index].eigenschaften["enabled"] == .bool(true), "nach Exit 13: \(menue[index])")
        #expect(menue.indices.contains(index + 1) && menue[index + 1].label?.contains("refused") == true,
                "Zeile unter dem Eintrag: \(menue)")

        // (4) Zweiter Lauf, Exit 0, Pfad unverändert ⇒ „up to date“, „refused“ weg.
        starter.pollErgebnis = .running
        try ereignis(bus, verbindung, prozess, id: pruefen.id, art: "clicked")
        _ = prozess.handleMenuEvents()
        starter.pollErgebnis = .exited(0)
        prozess.pollUpdateCheck()
        #expect(starter.starts.count == 2, "Starts: \(starter.starts)")
        menue = try layoutLesen(bus, verbindung, prozess)
        index = try #require(menue.firstIndex { $0.id == pruefen.id }, "Menü: \(menue)")
        #expect(menue.indices.contains(index + 1) && menue[index + 1].label?.contains("up to date") == true,
                "Zeile unter dem Eintrag: \(menue)")
        #expect(!menue.contains { $0.label?.contains("refused") == true }, "Menü: \(menue)")

        // (5) CM-36 · Suche ab Werk, eigener Tray bei ausgeschaltetem Timer (FE-15):
        // erste Suche nach 15 min, Exit 12 still mit einem Nachversuch, Exit 14 zeigt die Zeile.
        let t0 = Date()
        let sucheStarter = StarterAttrappe()
        let suche = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: t0,
            environment: ["HOME": home.path],
            runner: SystemctlAttrappe(isEnabled: "disabled"),
            starter: sucheStarter
        )
        func suchStarts() -> [(executable: String, arguments: [String])] {
            sucheStarter.starts.filter { $0.arguments == ["--check-update"] }
        }
        menue = try layoutLesen(bus, verbindung, suche)
        let sucheEintrag = try #require(menue.first { $0.label == "Check for updates now" }, "Menü: \(menue)")

        suche.pollAutomaticCheck(now: t0.addingTimeInterval(899))
        #expect(suchStarts().isEmpty, "Start vor 15 min: \(sucheStarter.starts)")
        suche.pollAutomaticCheck(now: t0.addingTimeInterval(900))
        #expect(suchStarts().count == 1, "Starts: \(sucheStarter.starts)")
        menue = try layoutLesen(bus, verbindung, suche)
        let laeuft = try #require(menue.first { $0.id == sucheEintrag.id }, "Menü: \(menue)")
        #expect(laeuft.eigenschaften["enabled"] == .bool(false), "während der Suche: \(laeuft)")

        // Exit 12: nichts gemessen ⇒ keine Zeile, Eintrag wieder bedienbar.
        sucheStarter.pollErgebnis = .exited(12)
        suche.pollUpdateCheck()
        menue = try layoutLesen(bus, verbindung, suche)
        let nachZwoelf = try #require(menue.first { $0.id == sucheEintrag.id }, "Menü: \(menue)")
        #expect(nachZwoelf.eigenschaften["enabled"] == .bool(true), "nach Exit 12: \(nachZwoelf)")
        #expect(!menue.contains { $0.label?.contains("Last check") == true }, "Menü: \(menue)")

        // Genau ein Nachversuch 15 min nach dem Start der Suche.
        suche.pollAutomaticCheck(now: t0.addingTimeInterval(900 + 899))
        #expect(suchStarts().count == 1, "Starts: \(sucheStarter.starts)")
        suche.pollAutomaticCheck(now: t0.addingTimeInterval(1800))
        #expect(suchStarts().count == 2, "Starts: \(sucheStarter.starts)")

        // Exit 14: neuere Fassung ⇒ Zeile unter dem Eintrag.
        sucheStarter.pollErgebnis = .exited(14)
        suche.pollUpdateCheck()
        menue = try layoutLesen(bus, verbindung, suche)
        let nachVierzehn = try #require(menue.firstIndex { $0.id == sucheEintrag.id }, "Menü: \(menue)")
        #expect(menue.indices.contains(nachVierzehn + 1)
                && menue[nachVierzehn + 1].label?.contains("newer version is available") == true,
                "Zeile unter dem Eintrag: \(menue)")
    }

    /// T2 — maskiert: gesperrt, mit unmask-Hinweis, Klick ohne Wirkung.
    @Test("CM-30: Start at login maskiert — gesperrt mit unmask-Hinweis, Klick wirkungslos")
    func startAtLogin_maskiert_gesperrtMitHinweis_klickWirkungslos() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()
        let verbindung = try DBusConnection(socketPath: bus.socketPfad)
        defer { verbindung.close() }
        let home = try temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let attrappe = SystemctlAttrappe(isEnabled: "masked")
        let prozess = TrayProcess(
            connection: verbindung,
            homeDirectory: home,
            log: TrayLog(homeDirectory: home),
            now: Date(),
            environment: attrappe.umgebung(home: home),
            runner: attrappe
        )

        let menue = try layoutLesen(bus, verbindung, prozess)
        let index = try #require(menue.firstIndex { $0.label == "Start at login" }, "Menü: \(menue)")
        let eintrag = menue[index]
        #expect(eintrag.eigenschaften["enabled"] == .bool(false))
        #expect(eintrag.eigenschaften["toggle-state"] == .int32(0))
        #expect(
            menue.indices.contains(index + 1) && menue[index + 1].label
                == "Masked in systemd — undo with: systemctl --user unmask claude-monitor-tray.service",
            "Zeile unter „Start at login“: \(menue)"
        )

        try ereignis(bus, verbindung, prozess, id: eintrag.id, art: "clicked")
        _ = prozess.handleMenuEvents()
        let wirkend = attrappe.aufrufe.filter { aufruf in
            ["enable", "disable", "daemon-reload"].contains(aufruf.split(separator: " ").dropFirst().first.map(String.init))
        }
        #expect(wirkend.isEmpty, "Klick auf gesperrten Eintrag rief: \(wirkend)")
    }

    /// Ein Menüeintrag, wie ihn die Gegenstelle aus `GetLayout` liest.
    private struct Eintrag: CustomStringConvertible {
        let id: Int32
        let eigenschaften: [String: DBusValue]
        var label: String? {
            if case .string(let text)? = eigenschaften["label"] { return text }
            return nil
        }
        var description: String { "\(id) \(label ?? "-") \(eigenschaften)" }
    }

    /// `GetLayout(0, -1, [])` über den Draht; liefert die Kinder der Wurzel.
    private func layoutLesen(
        _ bus: FakeSessionBus,
        _ verbindung: DBusConnection,
        _ prozess: TrayProcess
    ) throws -> [Eintrag] {
        let seriennummer = bus.aufrufen(
            pfad: TrayProcess.menuPath,
            interface: "com.canonical.dbusmenu",
            member: "GetLayout",
            argumente: [.int32(TrayMenuIdentifiers.root), .int32(-1), .array(elementSignature: "s", elements: [])]
        )
        try pumpen(verbindung, prozess, durchgaenge: 30, bis: { bus.antwort(auf: seriennummer) != nil })
        let antwort = try #require(bus.antwort(auf: seriennummer), "keine Antwort auf GetLayout")

        var leser = antwort.bodyReader()
        _ = try leser.readUInt32()          // Revision
        try leser.align(to: 8)
        _ = try leser.readInt32()           // Wurzel
        try leser.skipValue("a{sv}")
        return try leser.readArray(elementSignature: "v") { kind in
            _ = try kind.readSignature()
            try kind.align(to: 8)
            let id = try kind.readInt32()
            let paare = try kind.readArray(elementSignature: "{sv}") { paar -> (String, DBusValue) in
                try paar.align(to: 8)
                let name = try paar.readString()
                let signatur = try paar.readSignature()
                switch signatur {
                case "s": return (name, .string(try paar.readString()))
                case "b": return (name, .bool(try paar.readBool()))
                case "i": return (name, .int32(try paar.readInt32()))
                default:
                    try paar.skipValue(signatur)
                    return (name, .signature(signatur))
                }
            }
            try kind.skipValue("av")
            return Eintrag(id: id, eigenschaften: Dictionary(paare, uniquingKeysWith: { $1 }))
        }
    }

    /// `com.canonical.dbusmenu.Event` über den Draht, wie gnome-shell es schickt.
    private func ereignis(
        _ bus: FakeSessionBus,
        _ verbindung: DBusConnection,
        _ prozess: TrayProcess,
        id: Int32,
        art: String
    ) throws {
        let seriennummer = bus.aufrufen(
            pfad: TrayProcess.menuPath,
            interface: "com.canonical.dbusmenu",
            member: "Event",
            argumente: [.int32(id), .string(art), .variant(.int32(0)), .uint32(0)]
        )
        try pumpen(verbindung, prozess, durchgaenge: 30, bis: { bus.antwort(auf: seriennummer) != nil })
        #expect(bus.antwort(auf: seriennummer) != nil, "keine Antwort auf Event \(art)")
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

/// `systemctl`-Attrappe im Prozess: protokolliert jeden Aufruf, antwortet auf
/// `is-enabled <unit>` aus einer Tabelle je Unit und stellt nach `disable <unit>`
/// nur diese Unit auf `disabled` um. ``isEnabled`` ist der Zustand der
/// Autostart-Unit; der Update-Timer steht in ``timerIsEnabled``.
final class SystemctlAttrappe: CommandRunner {
    private var zustand: [String: String]
    private(set) var aufrufe: [String] = []

    init(isEnabled: String, timerIsEnabled: String = "disabled") {
        zustand = [
            "claude-monitor-tray.service": isEnabled,
            "claude-monitor-tray-update.timer": timerIsEnabled
        ]
    }

    var isEnabled: String {
        get { zustand["claude-monitor-tray.service"] ?? "disabled" }
        set { zustand["claude-monitor-tray.service"] = newValue }
    }
    var timerIsEnabled: String { zustand["claude-monitor-tray-update.timer"] ?? "disabled" }

    func umgebung(home: URL) -> [String: String] {
        ["HOME": home.path, "XDG_RUNTIME_DIR": "/run/user/1000"]
    }

    func run(executable: String, arguments: [String]) -> CommandOutcome {
        aufrufe.append(arguments.joined(separator: " "))
        switch arguments.dropFirst().first {
        case "is-enabled":
            let wert = zustand[arguments.last ?? ""] ?? "disabled"
            return CommandOutcome(
                exitStatus: wert == "enabled" ? 0 : 1,
                standardOutput: wert + "\n",
                standardError: ""
            )
        case "disable":
            zustand[arguments.last ?? ""] = "disabled"
            return CommandOutcome(exitStatus: 0, standardOutput: "", standardError: "")
        case "is-active":
            return CommandOutcome(exitStatus: 0, standardOutput: "active\n", standardError: "")
        default:
            return CommandOutcome(exitStatus: 0, standardOutput: "", standardError: "")
        }
    }
}

/// `BackgroundStarter`-Attrappe: zeichnet Starts auf, liefert eine pid, `poll`
/// antwortet mit dem vom Test gesetzten Wert (anfangs `.running`).
final class StarterAttrappe: BackgroundStarter {
    private(set) var starts: [(executable: String, arguments: [String])] = []
    var pollErgebnis: BackgroundPoll = .running

    func start(executable: String, arguments: [String]) -> pid_t? {
        starts.append((executable, arguments))
        return 4242
    }

    func poll(_ pid: pid_t) -> BackgroundPoll { pollErgebnis }
}
