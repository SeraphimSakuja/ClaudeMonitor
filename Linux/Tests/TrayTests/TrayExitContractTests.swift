import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#endif

// CM-27 — der Exit-Vertrag des Tray-Prozesses unter Busabriss.
//
// Diese Zusicherungen laufen bewusst auf PROZESSEBENE gegen das echte
// `claude-monitor-tray`-Binary und nicht im Testprozess:
//
// * `runTray(arguments:)` ist der Ort, an dem `signal(SIGPIPE, SIG_IGN)` steht;
//   die bestehenden Tests (`FakeSessionBusTests`, `TrayBusBehaviourTests`)
//   sprechen `TrayProcess`/`DBusConnection` direkt an und durchlaufen diesen
//   Einstieg nie.
// * `FakeSessionBus` setzt `signal(SIGPIPE, SIG_IGN)` PROZESSWEIT. Jede
//   In-Process-Zusicherung über „stirbt der Prozess an SIGPIPE?" wäre damit
//   falsch grün — die Disposition käme vom Testaufbau, nicht vom Produktivcode.
// * Nur `waitpid` unterscheidet „mit Code 6 beendet" von „per Signal gestorben".
//
// Deshalb ein eigener, kleiner Helferbau in dieser Datei statt einer Erweiterung
// von `FakeSessionBus`: Die Attrappe hat keinen Haken zum gezielten Schließen
// direkt nach `OK`, und ein Eingriff dort stünde quer zu den bestehenden Tests.
@Suite("CM-27 · Exit-Vertrag des Tray-Prozesses", .serialized)
struct TrayExitContractTests {

    // MARK: - Helfer

    /// Ein SASL-Server, der nach dem `OK` SOFORT schließt.
    ///
    /// Er beantwortet genau eine Verbindung: liest bis einschließlich `\r\n`
    /// (die Zeile `\0AUTH EXTERNAL <hex>\r\n`), schickt `OK <16 Hex>\r\n` und
    /// schließt, ohne die nächste Anfrage abzuwarten. Der nächste Schreibversuch
    /// des Klienten trifft damit auf eine tote Gegenstelle.
    final class AbreissenderSaslServer {

        let socketPfad: String
        private var horcher: Int32 = -1
        private var faden: Thread?

        init() throws {
            socketPfad = FileManager.default.temporaryDirectory
                .appendingPathComponent("cm27-\(UUID().uuidString.prefix(8)).sock").path
            horcher = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            guard horcher >= 0 else { throw Fehler.socket }

            var adresse = sockaddr_un()
            adresse.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutablePointer(to: &adresse.sun_path) { roh in
                roh.withMemoryRebound(to: CChar.self, capacity: 108) { pfad in
                    for (index, byte) in socketPfad.utf8.enumerated() where index < 107 {
                        pfad[index] = CChar(bitPattern: byte)
                    }
                }
            }
            let gebunden = withUnsafePointer(to: &adresse) { zeiger in
                zeiger.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(horcher, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard gebunden == 0, listen(horcher, 4) == 0 else { throw Fehler.bind }
        }

        enum Fehler: Error { case socket, bind }

        func starten() {
            let faden = Thread { [horcher] in
                let klient = accept(horcher, nil, nil)
                guard klient >= 0 else { return }
                var gelesen: [UInt8] = []
                var puffer = [UInt8](repeating: 0, count: 512)
                while gelesen.count < 4096 {
                    let anzahl = puffer.withUnsafeMutableBytes {
                        read(klient, $0.baseAddress, 512)
                    }
                    if anzahl <= 0 { break }
                    gelesen += puffer[0..<anzahl]
                    if gelesen.count >= 2,
                       gelesen[gelesen.count - 2] == 0x0D, gelesen[gelesen.count - 1] == 0x0A {
                        break
                    }
                }
                // `send` mit `MSG_NOSIGNAL`, damit der TESTPROZESS nie an
                // SIGPIPE stirbt — er darf seine eigene SIGPIPE-Disposition
                // nicht anfassen (siehe Kontrollzusicherung in Fall 1).
                let antwort = Array("OK 0123456789abcdef\r\n".utf8)
                _ = antwort.withUnsafeBytes {
                    send(klient, $0.baseAddress, antwort.count, Int32(MSG_NOSIGNAL))
                }
                // SOFORT schließen — das ist der ganze Zweck dieses Servers.
                _ = Glibc.close(klient)
            }
            faden.start()
            self.faden = faden
        }

        func stoppen() {
            if horcher >= 0 { _ = Glibc.close(horcher) }
            unlink(socketPfad)
        }
    }

    /// Startet ein Kind per `posix_spawn` mit ZURÜCKGESETZTER SIGPIPE-Disposition.
    ///
    /// `POSIX_SPAWN_SETSIGDEF` plus `SIGPIPE` im Signalsatz ist hier Pflicht und
    /// keine Sorgfaltsgeste: Foundations `Process.run()` sichert das nicht zu.
    /// Erbt das Kind ein `SIG_IGN` aus dem Testprozess (das setzt z. B.
    /// `FakeSessionBus`), wäre die Zusicherung dieser Datei unbemerkt
    /// ausgehebelt — der Test wäre grün, ohne den Produktivcode zu prüfen.
    static func starte(
        binaer: String,
        argumente: [String] = [],
        umgebung: [String: String],
        sigpipeZuruecksetzen: Bool = true,
        stderrZiel: Int32? = nil,
        imKindSchliessen: [Int32] = []
    ) -> pid_t? {
        var attribute = posix_spawnattr_t()
        posix_spawnattr_init(&attribute)
        defer { posix_spawnattr_destroy(&attribute) }
        if sigpipeZuruecksetzen {
            var satz = sigset_t()
            sigemptyset(&satz)
            sigaddset(&satz, SIGPIPE)
            posix_spawnattr_setsigdefault(&attribute, &satz)
            posix_spawnattr_setflags(&attribute, Int16(POSIX_SPAWN_SETSIGDEF))
        }

        var aktionen = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&aktionen)
        defer { posix_spawn_file_actions_destroy(&aktionen) }
        if let stderrZiel { posix_spawn_file_actions_adddup2(&aktionen, stderrZiel, 2) }
        for deskriptor in imKindSchliessen {
            posix_spawn_file_actions_addclose(&aktionen, deskriptor)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([binaer] + argumente).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = umgebung.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for zeiger in argv + envp { free(zeiger) } }

        var kind: pid_t = 0
        let ergebnis = posix_spawn(&kind, binaer, &aktionen, &attribute, &argv, &envp)
        return ergebnis == 0 ? kind : nil
    }

    /// Der Pfad des echten Tray-Binärprogramms.
    ///
    /// Aus `CommandLine.arguments[0]` abgeleitet statt `debug` hartkodiert: Der
    /// Docker-Testlauf kann die `release`-Konfiguration nutzen.
    static var trayBinaer: String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("claude-monitor-tray")
            .path
    }

    /// Ein eigenes, leeres Home für das Kind — nie das echte.
    static func temporaeresHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm27-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Wartet auf das Ende des Kindes; `nil` heißt „Frist abgelaufen"
    /// (das Kind ist dann bereits eingesammelt und getötet).
    static func warteAufEnde(_ kind: pid_t, fristSekunden: Double = 15) -> Int32? {
        let ende = Date().addingTimeInterval(fristSekunden)
        var status: Int32 = 0
        while Date() < ende {
            let ergebnis = waitpid(kind, &status, WNOHANG)
            if ergebnis == kind { return status }
            if ergebnis < 0 { return nil }
            usleep(20_000)
        }
        kill(kind, SIGKILL)
        _ = waitpid(kind, &status, 0)
        return nil
    }

    // `WIFEXITED` und Geschwister sind C-Makros und stehen Swift nicht zur
    // Verfügung; hier die Auswertung nach `<bits/waitstatus.h>`.
    static func regulaerBeendet(_ status: Int32) -> Bool { (status & 0x7F) == 0 }
    static func endeCode(_ status: Int32) -> Int32 { (status >> 8) & 0xFF }
    static func perSignalGestorben(_ status: Int32) -> Bool {
        let signal = status & 0x7F
        return signal != 0 && signal != 0x7F
    }

    /// Liest `SigIgn:` aus `/proc/<pid>/status` als Bitmaske.
    static func ignorierteSignale(_ kind: pid_t) -> UInt64? {
        for _ in 0..<50 {
            if let text = try? String(contentsOfFile: "/proc/\(kind)/status", encoding: .utf8) {
                for zeile in text.split(separator: "\n") where zeile.hasPrefix("SigIgn:") {
                    let wert = zeile.dropFirst("SigIgn:".count)
                        .trimmingCharacters(in: .whitespaces)
                    return UInt64(wert, radix: 16)
                }
            }
            usleep(20_000)
        }
        return nil
    }

    /// Bit 12 der Signalmaske = SIGPIPE (Signal 13).
    static let sigpipeBit: UInt64 = 0x1000

    // MARK: - Fall 1

    /// Reißt der Bus während eines Schreibversuchs ab, endet der Tray REGULÄR
    /// mit `TrayExit.connectionFailed` (6) — und stirbt insbesondere NICHT per
    /// Signal an SIGPIPE (Shell-Code 141).
    ///
    /// „6" allein wäre zu wenig: Erst `WIFSIGNALED == false` belegt, dass der
    /// Prozess seinen eigenen Exit-Vertrag erfüllt hat, statt vom Kernel
    /// abgeräumt worden zu sein. Genau daran unterscheidet der systemd-Dienst
    /// aus CM-21 „falsch eingerichtet" von „gescheitert".
    @Test("Busabriss während des Schreibversuchs endet mit Exit 6, nicht per Signal")
    func CM27_busabrissWaehrendSchreibversuch_endetMitExit6_nichtPerSignal() throws {
        let server = try AbreissenderSaslServer()
        defer { server.stoppen() }
        server.starten()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let umgebung = [
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=\(server.socketPfad)",
            "HOME": home.path
        ]

        // Kontrollzusicherung VOR der eigentlichen Prüfung: Der Spawn-Helfer
        // liefert wirklich ein Kind mit ZURÜCKGESETZTER SIGPIPE-Disposition.
        // Gemessen wird das an einem Kontrollkind (`/bin/sleep`), NICHT am Tray
        // selbst — der setzt SIG_IGN ja gerade absichtlich, eine Messung dort
        // liefe gegen den eigenen Fix.
        let kontrollkind = try #require(
            Self.starte(binaer: "/bin/sleep", argumente: ["10"], umgebung: umgebung)
        )
        let ignoriert = try #require(Self.ignorierteSignale(kontrollkind))
        #expect(ignoriert & Self.sigpipeBit == 0)
        kill(kontrollkind, SIGKILL)
        var verworfen: Int32 = 0
        _ = waitpid(kontrollkind, &verworfen, 0)

        // Der Tray läuft als normales Kind DIESES Testprozesses — nie als PID 1
        // eines Namespace, sonst würde SIGPIPE ohne Handler gar nicht erst
        // zugestellt und der Test wäre falsch grün.
        let tray = try #require(Self.starte(binaer: Self.trayBinaer, umgebung: umgebung))
        let status = try #require(Self.warteAufEnde(tray), "Tray endete nicht binnen 15 s")

        #expect(Self.regulaerBeendet(status))
        #expect(Self.endeCode(status) == 6)
        #expect(Self.perSignalGestorben(status) == false)
    }

    // MARK: - Fall 2

    /// Ist stderr tot, stirbt der Tray NICHT daran.
    ///
    /// Der Protokollierer darf nie der Grund sein, warum der Prozess endet —
    /// insbesondere nicht mit 132 („Illegal instruction"), dem Trap der alten
    /// `FileHandle.standardError.write(_:)`-Brücke. Der Ausgang bleibt der
    /// Verbindungsfehler 6.
    @Test("Tote stderr-Pipe tötet den Tray nicht — der Ausgang bleibt 6")
    func CM27_toteStderrPipe_toetetDenTrayNicht() throws {
        let server = try AbreissenderSaslServer()
        defer { server.stoppen() }
        server.starten()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let umgebung = [
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=\(server.socketPfad)",
            "HOME": home.path
        ]

        // Das Schließen des Leseendes IM KIND ist hier tragend, nicht Hygiene:
        // `posix_spawn` vererbt jeden Deskriptor. Ohne das `addclose` hielte
        // das Kind selbst noch das Leseende offen — die Pipe wäre nie tot, und
        // der Test wäre falsch grün (genau so gemessen).
        var rohre: [Int32] = [-1, -1]
        #expect(pipe(&rohre) == 0)
        let leseEnde = rohre[0]
        let schreibEnde = rohre[1]

        let tray = try #require(
            Self.starte(
                binaer: Self.trayBinaer,
                umgebung: umgebung,
                stderrZiel: schreibEnde,
                imKindSchliessen: [leseEnde]
            )
        )
        // Beide Enden im Testprozess sofort schließen: Das Kind hält damit das
        // einzige Schreibende einer Pipe ohne Leser in der Hand.
        _ = Glibc.close(leseEnde)
        _ = Glibc.close(schreibEnde)

        let status = try #require(Self.warteAufEnde(tray), "Tray endete nicht binnen 15 s")

        #expect(Self.regulaerBeendet(status))
        #expect(Self.endeCode(status) == 6)
    }

    // MARK: - Fall 3 bis 5: unlesbare und ausbleibende Bus-Antworten

    /// Beobachtet ein Kind bis zur Frist und sammelt dabei laufend dessen
    /// stderr.
    ///
    /// Anders als ``warteAufEnde(_:fristSekunden:)`` **tötet** dieser Helfer
    /// bei Fristablauf nicht: Fall 5 sichert gerade zu, dass der Prozess am
    /// Leben bleibt, und braucht danach noch dessen Protokoll.
    ///
    /// - Returns: der Endestatus (`nil`, wenn das Kind bei Fristablauf noch
    ///   lief) und die bis dahin gelesene stderr-Ausgabe.
    static func beobachten(
        _ kind: pid_t,
        leseEnde: Int32,
        fristSekunden: Double
    ) -> (status: Int32?, ausgabe: String) {
        // Nicht-blockierend lesen: Ein blockierendes `read` hinge, solange
        // das Kind lebt und niemand das Schreibende geschlossen hat — genau
        // die Lage in Fall 5.
        let flaggen = fcntl(leseEnde, F_GETFL, 0)
        _ = fcntl(leseEnde, F_SETFL, flaggen | O_NONBLOCK)

        let ende = Date().addingTimeInterval(fristSekunden)
        var bytes: [UInt8] = []
        var puffer = [UInt8](repeating: 0, count: 4096)
        var status: Int32 = 0
        var beendet: Int32?

        func nachlesen() {
            while true {
                let anzahl = puffer.withUnsafeMutableBytes { read(leseEnde, $0.baseAddress, 4096) }
                guard anzahl > 0 else { return }
                bytes += puffer[0..<anzahl]
            }
        }

        while Date() < ende {
            nachlesen()
            if waitpid(kind, &status, WNOHANG) == kind {
                // Alles, was das Kind geschrieben hat, steht nach seinem Ende
                // vollständig im Pipe-Puffer — eine letzte Nachlese genügt.
                beendet = status
                nachlesen()
                break
            }
            usleep(20_000)
        }
        if beendet == nil { nachlesen() }
        return (beendet, String(decoding: bytes, as: UTF8.self))
    }

    /// Startet den Tray gegen die Bus-Attrappe, mit stderr auf einer Pipe.
    ///
    /// Das Schließen des Leseendes IM KIND ist auch hier tragend (siehe Fall
    /// 2): Ohne das `addclose` hielte das Kind selbst ein Leseende offen.
    static func starteMitStderrPipe(
        umgebung: [String: String]
    ) throws -> (kind: pid_t, leseEnde: Int32, schreibEnde: Int32) {
        var rohre: [Int32] = [-1, -1]
        #expect(pipe(&rohre) == 0)
        let leseEnde = rohre[0]
        let schreibEnde = rohre[1]
        let kind = try #require(
            Self.starte(
                binaer: Self.trayBinaer,
                umgebung: umgebung,
                stderrZiel: schreibEnde,
                imKindSchliessen: [leseEnde]
            )
        )
        return (kind, leseEnde, schreibEnde)
    }

    /// Umgebung für ein Tray-Kind an der Attrappe — eigenes Home, nie das echte.
    static func umgebung(bus: FakeSessionBus, home: URL) -> [String: String] {
        [
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=\(bus.socketPfad)",
            "HOME": home.path
        ]
    }

    // MARK: - Fall 3

    /// Ist die Antwort auf `RequestName` unlesbar (leerer Rumpf), endet der
    /// Tray mit `connectionFailed` (6) — und **nicht** als `alreadyRunning` (8).
    ///
    /// Der Unterschied ist der Kern von CM-27: Exit 8 sagt „eine zweite
    /// Instanz läuft", und der systemd-Dienst aus CM-21 wertet das als
    /// geordneten Rückzug. Eine unlesbare Busantwort ist aber kein Beleg für
    /// eine zweite Instanz — nur ein ECHTES `RequestName`-Ergebnis ist das.
    @Test("Unlesbarer RequestName-Rumpf endet mit Exit 6, nicht als alreadyRunning")
    func CM27C_requestNameLeererRumpf_endetMitExit6_nichtAlreadyRunning() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        bus.leererRumpfFuer = ["RequestName"]
        try bus.start()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let kind = try Self.starteMitStderrPipe(umgebung: Self.umgebung(bus: bus, home: home))
        // Das Schreibende im Testprozess schließen: Dann endet das Lesen mit
        // EOF, sobald das Kind seinerseits endet.
        _ = Glibc.close(kind.schreibEnde)
        let beobachtung = Self.beobachten(kind.kind, leseEnde: kind.leseEnde, fristSekunden: 15)
        _ = Glibc.close(kind.leseEnde)

        let status = try #require(beobachtung.status, "Tray endete nicht binnen 15 s")
        #expect(Self.regulaerBeendet(status))
        #expect(Self.endeCode(status) == 6)
        #expect(Self.perSignalGestorben(status) == false)
        #expect(beobachtung.ausgabe.contains("step=requestName"))
        #expect(beobachtung.ausgabe.contains("reason=malformedReply"))
        #expect(beobachtung.ausgabe.contains("instance=alreadyRunning") == false)
    }

    // MARK: - Fall 4

    /// Ist die Antwort auf `NameHasOwner` unlesbar, endet der Tray mit 6 —
    /// und **nicht** als `watcherMissing` (9).
    ///
    /// Geprüft wird ausdrücklich der Normalbetrieb (ohne `--selftest`): Der
    /// allgemeine `ConnectError`-Zweig gilt unabhängig von `isSelftest`, nur
    /// der reine Zeitablauf wird dort unterschieden.
    @Test("Unlesbarer NameHasOwner-Rumpf endet mit Exit 6, nicht als watcherMissing")
    func CM27C_nameHasOwnerLeererRumpf_endetMitExit6_nichtWatcherMissing() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        // `RequestName` bleibt normal — sonst käme der Tray gar nicht bis
        // `NameHasOwner`.
        bus.leererRumpfFuer = ["NameHasOwner"]
        try bus.start()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let kind = try Self.starteMitStderrPipe(umgebung: Self.umgebung(bus: bus, home: home))
        _ = Glibc.close(kind.schreibEnde)
        let beobachtung = Self.beobachten(kind.kind, leseEnde: kind.leseEnde, fristSekunden: 15)
        _ = Glibc.close(kind.leseEnde)

        let status = try #require(beobachtung.status, "Tray endete nicht binnen 15 s")
        #expect(Self.regulaerBeendet(status))
        #expect(Self.endeCode(status) == 6)
        #expect(Self.perSignalGestorben(status) == false)
        #expect(beobachtung.ausgabe.contains("step=nameHasOwner"))
        #expect(beobachtung.ausgabe.contains("reason=malformedReply"))
        #expect(beobachtung.ausgabe.contains("watcher=absent name=") == false)
    }

    // MARK: - Fall 5

    /// Bleibt `NameHasOwner` unbeantwortet, läuft der Tray im Normalbetrieb
    /// WEITER und wartet auf den Watcher — er endet nicht.
    ///
    /// Ein bloßer Zeitablauf ist keine Antwort des Busses. Vor dem CM-27-Fix
    /// beendete sich der Prozess hier; unter CM-21 hieße das: Der Tray stirbt
    /// bei jedem langsamen Sitzungsstart, bevor der Watcher überhaupt da ist.
    @Test("Unbeantwortetes NameHasOwner beendet den Tray im Normalbetrieb nicht")
    func CM27B_nameHasOwnerUnbeantwortet_beendetTrayImNormalbetriebNicht() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        bus.antwortVerschweigenFuerNamen = ["org.kde.StatusNotifierWatcher"]
        try bus.start()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let kind = try Self.starteMitStderrPipe(umgebung: Self.umgebung(bus: bus, home: home))
        // Das Schreibende bleibt hier im Testprozess OFFEN: Es gibt kein EOF,
        // weil das Kind gerade nicht enden soll. Gelesen wird deshalb
        // nicht-blockierend bis zur Frist.
        // 6 s liegen über dem 5-s-Zeitlimit von `callBlocking` — vorher ist
        // die Zusicherung nicht messbar.
        let beobachtung = Self.beobachten(kind.kind, leseEnde: kind.leseEnde, fristSekunden: 6)

        #expect(beobachtung.status == nil, "Tray endete, obwohl er hätte weiterlaufen müssen")
        #expect(beobachtung.ausgabe.contains("watcher=absent — waiting for org.kde.StatusNotifierWatcher"))
        #expect(beobachtung.ausgabe.contains("bus=") == false)
        #expect(beobachtung.ausgabe.contains("watcher=absent name=") == false)

        kill(kind.kind, SIGKILL)
        var verworfen: Int32 = 0
        _ = waitpid(kind.kind, &verworfen, 0)
        _ = Glibc.close(kind.leseEnde)
        _ = Glibc.close(kind.schreibEnde)
    }

    // MARK: - Fall 6 (R-003)

    /// Wartet, bis eine Bedingung über `bus.gesehen` zutrifft, oder gibt nach
    /// der Frist auf.
    ///
    /// Kein festes `sleep`: Fall 6 hängt an zwei asynchronen Vorgängen (dem
    /// ersten Kind, das seine Namensvergabe abschließt, und der Attrappe, die
    /// den injizierten `NameOwnerChanged`-Draht bedient) — ein fixer
    /// Schlafwert wäre entweder zu knapp (flackernder Test) oder unnötig lang
    /// (langsamer Test).
    private static func wartenBis(
        fristSekunden: Double = 5,
        _ bedingung: () -> Bool
    ) -> Bool {
        let ende = Date().addingTimeInterval(fristSekunden)
        while Date() < ende {
            if bedingung() { return true }
            usleep(20_000)
        }
        return bedingung()
    }

    /// R-003 — ein Zweitstart erzeugt kein zweites Panel-Item.
    ///
    /// Die Attrappe kennt keinen echten `org.kde.StatusNotifierWatcher` —
    /// ohne ihn wartet das erste Kind im Normalbetrieb nur („watcher=absent —
    /// waiting") und meldet sich nie an (siehe Fall 5). Damit die Zusicherung
    /// „genau EINE Anmeldung, nur vom ersten Kind" überhaupt etwas zu zählen
    /// hat, wird der Watcher hier — wie in `TrayBusBehaviourTests` (R-002) —
    /// über `einspeisenNameOwnerChanged` als erschienen simuliert. Das ändert
    /// am Orakel nichts: Es schafft nur die Vorbedingung, unter der die
    /// Kernzusicherung dieses Falls (Zweitstart vs. Registrierungszählung)
    /// beobachtbar wird.
    @Test("R-003: Zweitstart endet mit alreadyRunning und genau einem registrierten Panel-Item")
    func R003_zweitstart_endetMitAlreadyRunning_undGenauEinemRegistriertenItem() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        try bus.start()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let umgebung = Self.umgebung(bus: bus, home: home)

        // Erstes Kind — Normalbetrieb, ohne `--selftest`.
        let erstesKind = try #require(Self.starte(binaer: Self.trayBinaer, umgebung: umgebung))
        var erstesLebt = true
        defer {
            if erstesLebt {
                kill(erstesKind, SIGKILL)
                var verworfen: Int32 = 0
                _ = waitpid(erstesKind, &verworfen, 0)
            }
        }

        // Synchronisation: Das erste Kind hat `RequestName` gestellt — die
        // Namensvergabe für `org.claudemonitor.Tray` ist abgeschlossen, bevor
        // das zweite Kind startet.
        #expect(
            Self.wartenBis { bus.gesehen.contains { $0.nachricht.member == "RequestName" } },
            "Erstes Kind hat RequestName nicht binnen 5 s gestellt"
        )
        // Und es hat sich für `NameOwnerChanged` des Watchers eingetragen —
        // sonst liefe der gleich folgende `einspeisenNameOwnerChanged`-Draht
        // ins Leere.
        #expect(
            Self.wartenBis { bus.gesehen.contains { $0.nachricht.member == "AddMatch" } },
            "Erstes Kind hat AddMatch nicht binnen 5 s gestellt"
        )

        bus.einspeisenNameOwnerChanged(
            name: "org.kde.StatusNotifierWatcher",
            alterEigentuemer: "",
            neuerEigentuemer: ":1.99"
        )
        #expect(
            Self.wartenBis {
                bus.gesehen.contains { $0.nachricht.member == "RegisterStatusNotifierItem" }
            },
            "Erstes Kind hat sich nicht binnen 5 s beim Watcher angemeldet"
        )

        // Zweites Kind — dieselben Umgebungsvariablen, derselbe Bus-Socket.
        var rohre: [Int32] = [-1, -1]
        #expect(pipe(&rohre) == 0)
        let leseEnde = rohre[0]
        let schreibEnde = rohre[1]
        let zweitesKind = try #require(
            Self.starte(
                binaer: Self.trayBinaer,
                umgebung: umgebung,
                stderrZiel: schreibEnde,
                imKindSchliessen: [leseEnde]
            )
        )
        _ = Glibc.close(schreibEnde)

        let beobachtung = Self.beobachten(zweitesKind, leseEnde: leseEnde, fristSekunden: 15)
        _ = Glibc.close(leseEnde)

        let status = try #require(beobachtung.status, "Zweites Kind endete nicht binnen 15 s")
        #expect(Self.regulaerBeendet(status))
        #expect(Self.endeCode(status) == 8)
        #expect(beobachtung.ausgabe.contains("instance=alreadyRunning name=org.claudemonitor.Tray"))

        let anmeldungen = bus.gesehen.filter { $0.nachricht.member == "RegisterStatusNotifierItem" }
        #expect(
            anmeldungen.count == 1,
            "erwartet: genau eine Anmeldung (nur vom ersten Kind), gezählt: \(anmeldungen.count)"
        )

        kill(erstesKind, SIGKILL)
        var verworfen: Int32 = 0
        _ = waitpid(erstesKind, &verworfen, 0)
        erstesLebt = false
    }

    // MARK: - Fall 7 (CM-27-D)

    /// CM-27-D — hängt `NameHasOwner` im Selbsttest, endet der Prozess mit
    /// `selftestIncomplete` (7), nicht mit `watcherMissing` (9).
    ///
    /// Der Unterschied ist der Kern von CM-27-D: Ein bloßer Zeitablauf beim
    /// `NameHasOwner`-Aufruf ist keine ECHTE Antwort des Busses — anders als
    /// bei Fall 4 (unlesbarer Rumpf) ist hier noch nicht einmal ein Rumpf da,
    /// nur Stille. Exit 9 würde vortäuschen, der Bus habe „kein Watcher"
    /// geantwortet; das hat er nie getan.
    @Test("CM-27-D: hängender NameHasOwner im Selbsttest endet mit Exit 7, nicht Exit 9")
    func CM27D_selftestHaengenderNameHasOwner_endetMitExit7_nichtExit9() throws {
        let bus = try FakeSessionBus()
        defer { bus.stop() }
        bus.antwortVerschweigenFuerNamen = ["org.kde.StatusNotifierWatcher"]
        try bus.start()

        let home = try Self.temporaeresHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let umgebung = Self.umgebung(bus: bus, home: home)

        var rohre: [Int32] = [-1, -1]
        #expect(pipe(&rohre) == 0)
        let leseEnde = rohre[0]
        let schreibEnde = rohre[1]
        let kind = try #require(
            Self.starte(
                binaer: Self.trayBinaer,
                argumente: ["--selftest"],
                umgebung: umgebung,
                stderrZiel: schreibEnde,
                imKindSchliessen: [leseEnde]
            )
        )
        _ = Glibc.close(schreibEnde)

        // 8 s liegen über dem 5-s-Zeitlimit von `callBlocking`, das den
        // Zeitablauf bei `NameHasOwner` überhaupt erst auslöst.
        let beobachtung = Self.beobachten(kind, leseEnde: leseEnde, fristSekunden: 8)
        _ = Glibc.close(leseEnde)

        let status = try #require(beobachtung.status, "Selbsttest-Kind endete nicht binnen 8 s")
        #expect(Self.regulaerBeendet(status))
        #expect(Self.endeCode(status) == 7)
        #expect(Self.endeCode(status) != 9)
        #expect(
            beobachtung.ausgabe.contains(
                "watcher=unknown step=nameHasOwner reason=timedOut — selftest incomplete"
            )
        )
        #expect(beobachtung.ausgabe.contains("watcher=absent name=") == false)
    }
}
