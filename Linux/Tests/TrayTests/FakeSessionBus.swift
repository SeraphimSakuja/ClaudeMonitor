import Foundation
#if canImport(Glibc)
import Glibc
#endif
import DBusWire

// CM-26 · Bus-Attrappe für D-Bus-Verhaltenstests (Testinfrastruktur).
//
// ⚠️ Diese Datei trägt **keine** Testfälle. Sie ist Werkzeug: ein echter
// `AF_UNIX`-Server im Testprozess, gegen den sich ein **unveränderter**
// `DBusConnection` mit echtem `socket()`/`connect()`/SASL/Codec verbindet. Es
// gibt hier kein Test-Double und kein zweites Protokoll — der Injektionspunkt
// ist der bereits vorhandene Parameter `DBusConnection(socketPath:)`.
//
// **Bewusster Zuschnitt (Klassen-Entscheid der Karte):** Gebaut ist nur, was
// die drei Registerfälle R-001/R-002/R-003 brauchen — SASL EXTERNAL, `Hello`,
// `RequestName` mit `DO_NOT_QUEUE`-Semantik, `NameHasOwner`, `AddMatch` samt
// Signalzustellung. **Nicht** gebaut: Introspection, `GetNameOwner`,
// `ReleaseName`, `ListNames`, `StartServiceByName`, eine
// StatusNotifierWatcher-Emulation, Big-Endian-Dekodierung, FD-Passing. Ein
// vollständiger Broker wäre mehr Code als die Anwendung, die er prüfen soll.

/// Ein minimaler Sitzungsbus für Tests.
///
/// **Nebenläufigkeit:** ein Thread für `accept()`, ein Thread je Verbindung,
/// ein Wachhund-Thread. Der gemeinsame Zustand liegt hinter `zustand`
/// (`NSLock`); deshalb `@unchecked Sendable` und nicht `actor` — die
/// Server-Threads hängen in blockierenden POSIX-Aufrufen, die sich in keine
/// Ausführungsumgebung von Swift Concurrency einfügen lassen.
final class FakeSessionBus: @unchecked Sendable {

    /// Was beim Aufbau schiefgehen kann.
    enum AufbauFehler: Error, Equatable {
        case pfadZuLang(String)
        case socketGescheitert(errno: Int32)
        case bindGescheitert(errno: Int32)
        case listenGescheitert(errno: Int32)
    }

    /// Eine vom Klienten empfangene Nachricht samt Absender.
    ///
    /// Der Absender steht hier und nicht in `DBusMessage.sender`, weil
    /// `DBusMessage.encoded()` das Kopffeld 7 gar nicht schreibt — die
    /// Zuordnung kennt nur der Server, über die Verbindung.
    struct Aufzeichnung: Sendable {
        let klient: String
        let nachricht: DBusMessage
    }

    /// Name des Busses selbst.
    static let busName = "org.freedesktop.DBus"
    /// Vorgabe der Wachhund-Leerlauffrist. Deutlich über jeder Frist, die der
    /// Tray-Prozess selbst kennt (`callBlocking` 5 s, `selftestTimeout` 20 s) —
    /// der Wachhund soll einen hängenden Suite-Lauf beenden, nicht einen
    /// langsamen Test abschneiden.
    static let standardLeerlauffrist: TimeInterval = 30

    /// Der Pfad, den ein Test an `DBusConnection(socketPath:)` weiterreicht.
    let socketPfad: String

    private let leerlauffrist: TimeInterval
    private let zustand = NSLock()

    private var lauscher: Int32 = -1
    private var verbindungen: [Verbindung] = []
    /// Well-Known-Namen und ihre Eigentümerverbindung (verbindungsbezogener
    /// Besitz — genau darum geht es bei R-003).
    private var namen: [String: Verbindung] = [:]
    private var aufzeichnungen: [Aufzeichnung] = []
    private var haltFlagge = false
    private var seriennummer: UInt32 = 0
    private var naechsteKennung = 0
    private var letzteAktivitaet = Date()
    private var wachhundSchlugIntern = false

    // MARK: - Aufbau

    init(leerlauffrist: TimeInterval = FakeSessionBus.standardLeerlauffrist) throws {
        // ⚠️ Testziel-only-Abweichung vom Auslieferzustand (Auflage 2 der
        // Karte): `DBusConnection.writeAll` schreibt mit `write()` ohne
        // `MSG_NOSIGNAL`, und `SIGPIPE` wird im Produktivcode nirgends
        // behandelt. Ein Verbindungsabriss während eines Schreibversuchs würde
        // damit den **gesamten** Testprozess beenden — nicht nur den einen
        // Test. Dass der ausgelieferte Tray-Prozess an derselben Stelle
        // stirbt, statt den zugesagten Exit 6 zu liefern, ist ein
        // Produktivbefund mit eigener Backlog-Card und wird hier ausdrücklich
        // **nicht** geheilt.
        _ = Self.sigpipeIgnoriert

        self.leerlauffrist = leerlauffrist
        // Immer unter `NSTemporaryDirectory()`, nie im Paketverzeichnis: ein
        // liegengebliebener Socket im Baum verfälscht den Quell-Scan der
        // Ordnungswächter. `sun_path` fasst 108 Byte inklusive Nullbyte,
        // deshalb die gekürzte Kennung und die Prüfung darunter.
        let kennung = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        socketPfad = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cm26-\(kennung).sock")
        guard socketPfad.utf8.count < 107 else { throw AufbauFehler.pfadZuLang(socketPfad) }
    }

    deinit {
        // Absicherung für den Fall, dass ein Test `stop()` vergisst: ohne sie
        // bliebe ein Accept-Thread über das Testende hinaus am Leben.
        stop()
    }

    /// Öffnet den Lauschsocket und startet Accept-, Verbindungs- und
    /// Wachhund-Betrieb.
    func start() throws {
        let deskriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard deskriptor >= 0 else { throw AufbauFehler.socketGescheitert(errno: errno) }

        unlink(socketPfad)
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
                bind(deskriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard gebunden == 0 else {
            let grund = errno
            Glibc.close(deskriptor)
            throw AufbauFehler.bindGescheitert(errno: grund)
        }
        guard listen(deskriptor, 8) == 0 else {
            let grund = errno
            Glibc.close(deskriptor)
            unlink(socketPfad)
            throw AufbauFehler.listenGescheitert(errno: grund)
        }

        zustand.lock()
        lauscher = deskriptor
        letzteAktivitaet = Date()
        zustand.unlock()

        Thread.detachNewThread { [self] in annehmen(lauschDeskriptor: deskriptor) }
        Thread.detachNewThread { [self] in wachhundLauf() }
    }

    /// Beendet alles und räumt den Socketpfad ab.
    ///
    /// Mehrfachaufruf ist ausdrücklich erlaubt (`stop()` im Test **und** im
    /// `deinit`).
    func stop() {
        zustand.lock()
        guard !haltFlagge else { zustand.unlock(); return }
        haltFlagge = true
        let alterLauscher = lauscher
        lauscher = -1
        let offene = verbindungen
        verbindungen = []
        namen = [:]
        zustand.unlock()

        if alterLauscher >= 0 { schliesseDeskriptor(alterLauscher) }
        for verbindung in offene { verbindung.schliessen() }
        unlink(socketPfad)
    }

    // MARK: - Abfragen für Tests

    /// Alle vom Klienten empfangenen Nachrichten, in Ankunftsreihenfolge.
    var gesehen: [Aufzeichnung] {
        zustand.lock()
        defer { zustand.unlock() }
        return aufzeichnungen
    }

    /// Alle empfangenen Nachrichten mit diesem `interface.member`.
    func gesehen(ruf schluessel: String) -> [DBusMessage] {
        gesehen.map(\.nachricht).filter { $0.callKey == schluessel }
    }

    /// Hat der Wachhund zugeschlagen? Ein `true` hier heißt: der Lauf hing,
    /// das Ergebnis des Tests ist nicht aussagekräftig.
    var wachhundSchlug: Bool {
        zustand.lock()
        defer { zustand.unlock() }
        return wachhundSchlugIntern
    }

    /// Der eindeutige Name der Verbindung, die diesen Well-Known-Namen hält.
    func eigentuemer(von name: String) -> String? {
        zustand.lock()
        defer { zustand.unlock() }
        return namen[name]?.eindeutigerName
    }

    /// Wie viele Verbindungen gerade offen sind.
    var verbindungsZahl: Int {
        zustand.lock()
        defer { zustand.unlock() }
        return verbindungen.count
    }

    /// Die rohen `AddMatch`-Regeln aller offenen Verbindungen.
    var abgelegteRegeln: [String] {
        zustand.lock()
        defer { zustand.unlock() }
        return verbindungen.flatMap { $0.rohRegeln }
    }

    // MARK: - Signaleinspeisung

    /// Stellt ein Signal allen Verbindungen zu, deren `AddMatch`-Regeln passen.
    ///
    /// - Returns: die Zahl der belieferten Verbindungen. `0` ist ein gültiges
    ///   Ergebnis und heißt „niemand hat das abbestellt".
    @discardableResult
    func einspeisen(signal nachricht: DBusMessage) -> Int {
        zustand.lock()
        let empfaenger = verbindungen.filter { verbindung in
            verbindung.regeln.contains { passt($0, zu: nachricht) }
        }
        zustand.unlock()

        for verbindung in empfaenger {
            var ausgehend = nachricht
            ausgehend.type = .signal
            // `NO_REPLY_EXPECTED` — ein Signal beantwortet niemand.
            ausgehend.flags |= 1
            ausgehend.serial = naechsteSeriennummer()
            verbindung.schreiben(ausgehend.encoded())
        }
        return empfaenger.count
    }

    /// Der Standardfall dieser Karte: `org.freedesktop.DBus.NameOwnerChanged`.
    @discardableResult
    func einspeisenNameOwnerChanged(
        name: String,
        alterEigentuemer: String,
        neuerEigentuemer: String
    ) -> Int {
        var schreiber = DBusWriter()
        schreiber.write(.string(name))
        schreiber.write(.string(alterEigentuemer))
        schreiber.write(.string(neuerEigentuemer))
        return einspeisen(signal: DBusMessage(
            type: .signal,
            path: "/org/freedesktop/DBus",
            interface: Self.busName,
            member: "NameOwnerChanged",
            bodySignature: "sss",
            body: schreiber.bytes
        ))
    }

    // MARK: - Accept

    private func annehmen(lauschDeskriptor: Int32) {
        while !haeltAn {
            var beobachtet = pollfd(fd: lauschDeskriptor, events: Int16(POLLIN), revents: 0)
            // Nicht blockierend warten: Ohne Zeitlimit hinge dieser Thread in
            // `accept()` und käme beim Abbau nur über einen harten Abbruch
            // heraus. Mit `poll` prüft er die Halt-Flagge viermal je Sekunde.
            let bereit = poll(&beobachtet, 1, 250)
            if bereit < 0 {
                if errno == EINTR { continue }
                return
            }
            guard bereit > 0 else { continue }

            let deskriptor = accept(lauschDeskriptor, nil, nil)
            guard deskriptor >= 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            guard !haeltAn else { schliesseDeskriptor(deskriptor); return }

            zustand.lock()
            naechsteKennung += 1
            let verbindung = Verbindung(
                deskriptor: deskriptor,
                eindeutigerName: ":1.\(naechsteKennung)"
            )
            verbindungen.append(verbindung)
            zustand.unlock()

            // Ein Thread je Verbindung: R-003 verlangt eine **zweite**
            // Verbindung, während die erste den Namen hält. Eine Attrappe mit
            // nur einem `accept()` blockiert dabei den gesamten Suite-Lauf.
            Thread.detachNewThread { [self] in bedienen(verbindung) }
        }
    }

    // MARK: - Verbindungsbetrieb

    private enum Phase { case sasl, nachrichten }

    private func bedienen(_ verbindung: Verbindung) {
        var puffer: [UInt8] = []
        var phase = Phase.sasl
        var nullbyteGesehen = false
        var lesepuffer = [UInt8](repeating: 0, count: 8192)

        schleife: while !haeltAn {
            let anzahl = recv(verbindung.deskriptor, &lesepuffer, lesepuffer.count, 0)
            if anzahl < 0 && errno == EINTR { continue }
            guard anzahl > 0 else { break }
            puffer += lesepuffer[0..<anzahl]
            merkeAktivitaet()

            if phase == .sasl {
                switch saslSchritt(
                    puffer: &puffer,
                    nullbyteGesehen: &nullbyteGesehen,
                    verbindung: verbindung
                ) {
                case .warten:
                    continue
                case .abgelehnt:
                    break schleife
                case .fertig:
                    // Auflage 9: Nach `BEGIN\r\n` können die ersten
                    // Nachrichtenbytes **im selben `read()`** liegen. Der
                    // Puffer wird deshalb weitergereicht und nicht verworfen —
                    // sonst fehlte `Hello` und der Klient liefe in sein
                    // 5-s-Zeitlimit.
                    phase = .nachrichten
                }
            }

            do {
                while let entschluesselt = try DBusMessage.decode(from: puffer) {
                    puffer.removeFirst(entschluesselt.consumed)
                    verarbeiten(entschluesselt.message, von: verbindung)
                }
            } catch {
                notiz("Nachricht unlesbar (\(error)) — Verbindung \(verbindung.eindeutigerName) beendet")
                break
            }
        }

        beenden(verbindung)
    }

    private enum SASLErgebnis { case warten, fertig, abgelehnt }

    /// Der SASL-EXTERNAL-Gegenpart — bewusst **kein** vollständiger
    /// Bus-Handshake.
    ///
    /// Geprüft wird, was `DBusConnection.authenticate()` tatsächlich schickt:
    /// führendes Nullbyte, dann `AUTH EXTERNAL <uid-als-hex>`, dann `BEGIN`.
    /// Keine Mechanismenaushandlung (`AUTH` ohne Argument), kein
    /// `NEGOTIATE_UNIX_FD`, keine GUID-Prüfung auf Klientenseite — alles drei
    /// benutzt dieser Klient nicht, und ein nie durchlaufener Pfad in einer
    /// Attrappe ist schlimmer als sein Fehlen.
    private func saslSchritt(
        puffer: inout [UInt8],
        nullbyteGesehen: inout Bool,
        verbindung: Verbindung
    ) -> SASLErgebnis {
        while true {
            if !nullbyteGesehen {
                guard let erstes = puffer.first else { return .warten }
                guard erstes == 0 else {
                    verbindung.schreiben(Array("REJECTED\r\n".utf8))
                    return .abgelehnt
                }
                puffer.removeFirst()
                nullbyteGesehen = true
            }
            guard let zeile = naechsteZeile(&puffer) else { return .warten }

            if zeile == "BEGIN" { return .fertig }
            if zeile.hasPrefix("AUTH EXTERNAL "),
               istHex(String(zeile.dropFirst("AUTH EXTERNAL ".count))) {
                verbindung.schreiben(Array("OK \(Self.busKennung)\r\n".utf8))
                continue
            }
            verbindung.schreiben(Array("REJECTED\r\n".utf8))
            return .abgelehnt
        }
    }

    private func naechsteZeile(_ puffer: inout [UInt8]) -> String? {
        guard puffer.count >= 2 else { return nil }
        for index in 0..<(puffer.count - 1) where puffer[index] == 13 && puffer[index + 1] == 10 {
            let zeile = String(decoding: puffer[0..<index], as: UTF8.self)
            puffer.removeFirst(index + 2)
            return zeile
        }
        return nil
    }

    private func istHex(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isHexDigit }
    }

    // MARK: - Bus-Methoden

    private func verarbeiten(_ nachricht: DBusMessage, von verbindung: Verbindung) {
        zustand.lock()
        aufzeichnungen.append(Aufzeichnung(klient: verbindung.eindeutigerName, nachricht: nachricht))
        zustand.unlock()

        guard nachricht.type == .methodCall else { return }
        // Alles, was nicht an den Bus selbst geht (etwa
        // `RegisterStatusNotifierItem` an den Watcher), wird nur aufgezeichnet:
        // Diese Attrappe emuliert ausdrücklich keine fremden Dienste. Der
        // Klient wartet auf solche Aufrufe auch nicht (`call`, nicht
        // `callBlocking`).
        guard nachricht.interface == Self.busName else { return }

        var leser = nachricht.bodyReader()
        switch nachricht.member {
        case "Hello":
            var schreiber = DBusWriter()
            schreiber.write(.string(verbindung.eindeutigerName))
            antworten(verbindung, auf: nachricht, signatur: "s", rumpf: schreiber.bytes)

        case "RequestName":
            let name = (try? leser.readString()) ?? ""
            let flaggen = (try? leser.readUInt32()) ?? 0
            var schreiber = DBusWriter()
            schreiber.write(.uint32(namenAnfordern(name, flaggen: flaggen, fuer: verbindung)))
            antworten(verbindung, auf: nachricht, signatur: "u", rumpf: schreiber.bytes)

        case "NameHasOwner":
            let name = (try? leser.readString()) ?? ""
            zustand.lock()
            let belegt = namen[name] != nil
            zustand.unlock()
            var schreiber = DBusWriter()
            schreiber.write(.bool(belegt))
            antworten(verbindung, auf: nachricht, signatur: "b", rumpf: schreiber.bytes)

        case "AddMatch":
            let regel = (try? leser.readString()) ?? ""
            verbindung.regelHinzufuegen(roh: regel, geparst: regelParsen(regel))
            antworten(verbindung, auf: nachricht)

        default:
            // Auflage 14: eine unbekannte Bus-Methode wird **beantwortet**,
            // nicht verschluckt. Sonst wartet ein `callBlocking` volle 5 s und
            // meldet am Ende nur „timedOut", ohne dass irgendwo steht, welcher
            // Aufruf gefehlt hat.
            fehlerAntworten(
                verbindung,
                auf: nachricht,
                name: "org.freedesktop.DBus.Error.UnknownMethod",
                text: "FakeSessionBus kennt \(nachricht.callKey) nicht"
            )
        }
    }

    /// `RequestName` mit `DO_NOT_QUEUE`-Semantik.
    ///
    /// Der Besitz hängt an der **Verbindung**, nicht am Prozess — genau das
    /// prüft R-003: Die zweite Verbindung bekommt bei gesetztem
    /// `DBUS_NAME_FLAG_DO_NOT_QUEUE` (4) eine sofortige Absage (`exists`, 3)
    /// statt eines Warteplatzes (`inQueue`, 2).
    private func namenAnfordern(_ name: String, flaggen: UInt32, fuer verbindung: Verbindung) -> UInt32 {
        zustand.lock()
        defer { zustand.unlock() }
        if let eigentuemer = namen[name] {
            if eigentuemer === verbindung { return 4 }
            return (flaggen & 4) != 0 ? 3 : 2
        }
        namen[name] = verbindung
        return 1
    }

    private func antworten(
        _ verbindung: Verbindung,
        auf aufruf: DBusMessage,
        signatur: String = "",
        rumpf: [UInt8] = []
    ) {
        var antwort = DBusMessage(
            type: .methodReturn,
            flags: 1,
            replySerial: aufruf.serial,
            destination: verbindung.eindeutigerName,
            bodySignature: signatur,
            body: rumpf
        )
        antwort.serial = naechsteSeriennummer()
        verbindung.schreiben(antwort.encoded())
    }

    private func fehlerAntworten(
        _ verbindung: Verbindung,
        auf aufruf: DBusMessage,
        name: String,
        text: String
    ) {
        var schreiber = DBusWriter()
        schreiber.write(.string(text))
        var antwort = DBusMessage(
            type: .error,
            flags: 1,
            replySerial: aufruf.serial,
            errorName: name,
            destination: verbindung.eindeutigerName,
            bodySignature: "s",
            body: schreiber.bytes
        )
        antwort.serial = naechsteSeriennummer()
        verbindung.schreiben(antwort.encoded())
    }

    // MARK: - Match-Regeln

    /// Zerlegt eine `AddMatch`-Regel in ihre Schlüssel-Wert-Paare.
    ///
    /// Bewusst einfach: Trennung an `,`, Werte in einfachen Anführungszeichen.
    /// Werte mit eingebettetem Komma kommen in diesem Projekt nicht vor
    /// (`TrayProcess.observeWatcher`), und eine vollständige Zerlegung samt
    /// Maskierung wäre Broker-Code ohne Prüfgewinn.
    private func regelParsen(_ regel: String) -> [String: String] {
        var ergebnis: [String: String] = [:]
        for teil in regel.split(separator: ",") {
            guard let trenner = teil.firstIndex(of: "=") else { continue }
            let schluessel = String(teil[teil.startIndex..<trenner])
                .trimmingCharacters(in: .whitespaces)
            var wert = String(teil[teil.index(after: trenner)...])
            if wert.hasPrefix("'") && wert.hasSuffix("'") && wert.count >= 2 {
                wert = String(wert.dropFirst().dropLast())
            }
            ergebnis[schluessel] = wert
        }
        return ergebnis
    }

    /// Wertet `type=`, `interface=`, `member=` und `arg0=` aus.
    ///
    /// ⚠️ **`sender=` wird bewusst NICHT ausgewertet** (Fachentscheid 5 der
    /// Karte): `DBusMessage.encoded()` schreibt das Kopffeld 7 (sender)
    /// überhaupt nicht (`DBusMessage.swift:79-85` schreibt nur 1,2,3,4,5,6,8),
    /// und diese Datei bleibt in dieser Karte unverändert. Eine Auswertung
    /// würde deshalb **jedes** eingespeiste Signal verwerfen — die Regel des
    /// Tray-Prozesses nennt `sender='org.freedesktop.DBus'`. Alle weiteren
    /// Schlüssel (`path=`, `arg0namespace=` …) werden aus demselben Grund
    /// ignoriert: sie kommen im geprüften Code nicht vor.
    private func passt(_ regel: [String: String], zu nachricht: DBusMessage) -> Bool {
        for (schluessel, wert) in regel {
            switch schluessel {
            case "type":
                guard typName(nachricht.type) == wert else { return false }
            case "interface":
                guard nachricht.interface == wert else { return false }
            case "member":
                guard nachricht.member == wert else { return false }
            case "arg0":
                guard erstesStringArgument(nachricht) == wert else { return false }
            default:
                continue
            }
        }
        return true
    }

    private func typName(_ art: DBusMessageType) -> String {
        switch art {
        case .methodCall: return "method_call"
        case .methodReturn: return "method_return"
        case .error: return "error"
        case .signal: return "signal"
        }
    }

    private func erstesStringArgument(_ nachricht: DBusMessage) -> String? {
        guard nachricht.bodySignature.first == "s" || nachricht.bodySignature.first == "o" else {
            return nil
        }
        var leser = nachricht.bodyReader()
        return try? leser.readString()
    }

    // MARK: - Wachhund

    /// Beendet den Bus, wenn **im Leerlauf** zu lange nichts mehr ankam.
    ///
    /// Ausdrücklich eine Leerlauffrist und keine Gesamtlauffrist: Ein Test, der
    /// laufend Nachrichten austauscht, darf beliebig lange dauern; ein Test,
    /// der auf eine Antwort wartet, die nie kommt, soll nach
    /// `leerlauffrist` enden — mit sichtbarem Merker `wachhundSchlug`, sonst
    /// erscheint das Hängen später als beliebiger Folgefehler.
    private func wachhundLauf() {
        while !haeltAn {
            Thread.sleep(forTimeInterval: 0.25)
            zustand.lock()
            let ruhe = Date().timeIntervalSince(letzteAktivitaet)
            let laeuft = !haltFlagge
            zustand.unlock()
            guard laeuft else { return }
            if ruhe > leerlauffrist {
                zustand.lock()
                wachhundSchlugIntern = true
                zustand.unlock()
                notiz("Wachhund: \(Int(ruhe)) s ohne Nachricht — Bus wird abgebaut")
                stop()
                return
            }
        }
    }

    private func merkeAktivitaet() {
        zustand.lock()
        letzteAktivitaet = Date()
        zustand.unlock()
    }

    // MARK: - Abbau

    private func beenden(_ verbindung: Verbindung) {
        zustand.lock()
        verbindungen.removeAll { $0 === verbindung }
        // Namensbesitz endet mit der Verbindung — wie auf einem echten Bus.
        for (name, eigentuemer) in namen where eigentuemer === verbindung {
            namen.removeValue(forKey: name)
        }
        zustand.unlock()
        verbindung.schliessen()
    }

    private var haeltAn: Bool {
        zustand.lock()
        defer { zustand.unlock() }
        return haltFlagge
    }

    private func naechsteSeriennummer() -> UInt32 {
        zustand.lock()
        defer { zustand.unlock() }
        seriennummer += 1
        return seriennummer
    }

    private func notiz(_ text: String) {
        // Swift-6-Strenge: kein Zugriff auf die C-Globalen `stdout`/`stderr`
        // aus nebenläufigem Code.
        FileHandle.standardError.write(Data("FakeSessionBus: \(text)\n".utf8))
    }

    /// Immer `shutdown` **vor** `close` (Auflage 1, gemessen): `close()` allein
    /// weckt einen im selben Prozess blockierenden `read()`/`recv()` auf der
    /// Gegenseite nicht — der Thread hing bis zum Zeitlimit der Suite.
    fileprivate static func abbauen(_ deskriptor: Int32) {
        shutdown(deskriptor, Int32(SHUT_RDWR))
        Glibc.close(deskriptor)
    }

    private func schliesseDeskriptor(_ deskriptor: Int32) {
        Self.abbauen(deskriptor)
    }

    /// Einmalig je Prozess, nicht je Test (Auflage 2).
    private static let sigpipeIgnoriert: Bool = {
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
        return true
    }()

    /// Die GUID, die der Bus im `OK` nennt. Fest, weil sie niemand prüft.
    private static let busKennung = "00112233445566778899aabbccddeeff"
}

// MARK: - Verbindung

/// Eine angenommene Klientenverbindung.
///
/// Eigene Sperre, weil hierauf zwei Threads zugreifen: der Verbindungsthread
/// (Antworten) und der Testthread (Signaleinspeisung). Sie wird **nie**
/// gehalten, während die Bus-Sperre genommen wird — die Reihenfolge ist immer
/// Bus-Sperre zuerst, danach frei, dann Schreiben.
private final class Verbindung: @unchecked Sendable {

    let deskriptor: Int32
    let eindeutigerName: String

    private let sperre = NSLock()
    private var geschlossen = false
    private var regelnIntern: [[String: String]] = []
    private var rohRegelnIntern: [String] = []

    init(deskriptor: Int32, eindeutigerName: String) {
        self.deskriptor = deskriptor
        self.eindeutigerName = eindeutigerName
    }

    var regeln: [[String: String]] {
        sperre.lock()
        defer { sperre.unlock() }
        return regelnIntern
    }

    var rohRegeln: [String] {
        sperre.lock()
        defer { sperre.unlock() }
        return rohRegelnIntern
    }

    func regelHinzufuegen(roh: String, geparst: [String: String]) {
        sperre.lock()
        rohRegelnIntern.append(roh)
        regelnIntern.append(geparst)
        sperre.unlock()
    }

    func schreiben(_ bytes: [UInt8]) {
        sperre.lock()
        defer { sperre.unlock() }
        guard !geschlossen else { return }
        var versatz = 0
        bytes.withUnsafeBytes { roh in
            guard let basis = roh.baseAddress else { return }
            while versatz < bytes.count {
                // `MSG_NOSIGNAL` auf der Serverseite: Ein abgebrochener Klient
                // darf den Testprozess nicht über SIGPIPE mitnehmen.
                let geschrieben = Glibc.send(
                    deskriptor,
                    basis + versatz,
                    bytes.count - versatz,
                    Int32(MSG_NOSIGNAL)
                )
                if geschrieben > 0 {
                    versatz += geschrieben
                    continue
                }
                if geschrieben < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    func schliessen() {
        sperre.lock()
        guard !geschlossen else { sperre.unlock(); return }
        geschlossen = true
        sperre.unlock()
        FakeSessionBus.abbauen(deskriptor)
    }
}
