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
}
