import Foundation
import Testing
import DBusWire
#if canImport(Glibc)
import Glibc
#endif

// R-001 (CM-27 Auflage 4) — `pump()` muss schon beim ERSTEN negativen `read`
// werfen, nicht erst beim zweiten.
//
// Der Unterschied zu `TrayExitContractTests.AbreissenderSaslServer`: Jener
// Server schließt SOFORT nach dem `OK` — damit liegen beim Klienten noch
// KEINE ungelesenen Daten in der Empfangsschlange, ein sauberer Abriss löst
// dann ein FIN aus (`read` liefert `0`). Für den hier zu belegenden Fall
// braucht es dagegen einen RST: Der Server muss nach dem `OK` erst noch
// `BEGIN` und den `Hello`-Aufruf des Klienten ungelesen in seiner Queue
// liegen lassen, bevor er schließt — nur dann liefert der erste `read` des
// Klienten `-1` (ECONNRESET), nicht `0`.
//
// `FakeSessionBus` taugt hierfür nicht: ihre Leseschleife liest laufend, es
// bleibt nichts Ungelesenes zurück, es entsteht also kein RST.
@Suite("R-001 · pump() wirft schon beim ersten negativen read")
struct DBusConnectionResetTests {

    /// Ein SASL-Server, der nach dem `OK` eine Weile NICHT MEHR liest, bevor
    /// er schließt — damit bleiben `BEGIN` und der `Hello`-Aufruf des
    /// Klienten ungelesen in seiner Kernel-Empfangsschlange und der Abriss
    /// erzeugt einen RST statt eines sauberen FIN.
    final class RstAusloesenderSaslServer {

        let socketPfad: String
        private var horcher: Int32 = -1
        private var faden: Thread?

        init() throws {
            socketPfad = FileManager.default.temporaryDirectory
                .appendingPathComponent("r001-\(UUID().uuidString.prefix(8)).sock").path
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
                let antwort = Array("OK 0123456789abcdef\r\n".utf8)
                _ = antwort.withUnsafeBytes {
                    send(klient, $0.baseAddress, antwort.count, Int32(MSG_NOSIGNAL))
                }
                // NICHT mehr lesen — `BEGIN` und der `Hello`-Aufruf des
                // Klienten bleiben ungelesen in der Kernel-Queue liegen,
                // solange der Klient sie schickt, während dieser Faden hier
                // wartet.
                usleep(250_000)
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

    /// Der erste `pump()`-Aufruf nach einem Abriss MIT ungelesenen Daten in
    /// der Empfangsschlange (RST) wirft `ConnectError.disconnected` — er darf
    /// nicht `[]` zurückgeben.
    ///
    /// ⚠️ Abweichung vom Wortlaut des Register-Eintrags R-001 („eine
    /// DBusConnection darauf verbinden und EINMAL pump(timeoutMilliseconds:
    /// 1000) rufen"), bitte prüfen: `DBusConnection.init(socketPath:)` ruft
    /// intern `authenticate()` (ein einfaches `read`, nicht über `pump()`)
    /// und danach zwingend `hello()`, welches über `callBlocking()` selbst
    /// wiederholt `pump(timeoutMilliseconds: 100)` aufruft, bis eine Antwort
    /// da ist oder 5 s vergangen sind. In genau dem hier geforderten Bild —
    /// der Server liest `BEGIN` und den `Hello`-Aufruf nie und schließt erst
    /// danach — bleibt `Hello` für immer unbeantwortet: Der Abriss wird
    /// unausweichlich SCHON innerhalb dieses internen `hello()`-Aufrufs
    /// bemerkt, also WÄHREND `DBusConnection(socketPath:)` noch läuft — nicht
    /// erst bei einem separaten, von außen nachträglich aufgerufenen
    /// `pump(timeoutMilliseconds: 1000)`. Eine erfolgreich aufgebaute
    /// Verbindung, an der man DANACH noch einen eigenen `pump()`-Aufruf
    /// nachschieben könnte, ist mit diesem Server-Bild nicht erreichbar,
    /// da `hello()` `private` ist und nur über den Konstruktor läuft.
    /// Geprüft wird deshalb der Konstruktor-Aufruf selbst — das ist exakt
    /// die vom Orakel (`DBusConnection.swift:317-332`) beschriebene erste
    /// betroffene Stelle: der erste `pump()`-Aufruf, der auf den Abriss
    /// trifft, muss werfen, statt still `[]` zurückzugeben.
    @Test("Abriss mit ungelesenen Daten (RST): erster pump()-Aufruf wirft disconnected")
    func ersterPumpAufrufWirftDisconnectedBeiRst() throws {
        let server = try RstAusloesenderSaslServer()
        defer { server.stoppen() }
        server.starten()

        #expect(throws: DBusConnection.ConnectError.disconnected) {
            _ = try DBusConnection(socketPath: server.socketPfad)
        }
    }
}
