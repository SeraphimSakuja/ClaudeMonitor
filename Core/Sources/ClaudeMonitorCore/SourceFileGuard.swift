import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Vorprüfung, bevor eine fremdbestimmte Datei vollständig gelesen wird.
///
/// `FileManager.fileExists(atPath:)` folgt Symlinks und sagt nichts über den
/// Dateityp; `Data(contentsOf:)` liest danach vollständig ein. An einer Datei,
/// die ein anderer Prozess kontrolliert, ist beides zusammen eine Falle: Zeigt
/// der Pfad auf eine FIFO, blockiert bereits das Öffnen, bis irgendwann ein
/// Schreiber erscheint. Der Lesedurchlauf läuft in einer abgesetzten Task und
/// kehrte nie zurück — der 30-Sekunden-Poller stünde dauerhaft still, ohne
/// Fehlermeldung und ohne sichtbare Ursache, während die Anzeige die zuletzt
/// gelesenen Zahlen unverändert weiterzeigt.
///
/// **Das ist dieselbe Fehlerklasse wie die App-Group-Blockade aus Leitplanke
/// L7** (fensterloser Prozess blockiert endlos, keine sichtbare Ursache), nur
/// an einer anderen Datei — und deshalb genauso zu behandeln: prüfen, bevor
/// zugegriffen wird.
///
/// Die Prüfung arbeitet auf `stat`-Ebene und **öffnet die Datei nicht**; sie
/// kann daher selbst nicht blockieren. Sie erwirbt kein Lock und schreibt
/// nichts (L1).
public enum SourceFileGuard {

    /// Obergrenze für die Größe einer Quelldatei.
    ///
    /// claude-swaps `usage.json` liegt real bei wenigen Kilobyte. 8 MB ist um
    /// Größenordnungen darüber — und zugleich klein genug, dass ein
    /// versehentlich oder böswillig aufgeblähtes Exemplar nicht vollständig in
    /// den Speicher gelesen wird.
    public static let maximumFileSize = 8 * 1024 * 1024

    /// Ergebnis der Vorprüfung.
    public enum Verdict: Equatable, Sendable, Error {
        /// Gewöhnliche Datei innerhalb der Größengrenze — lesen ist sicher.
        case ok
        /// Nicht vorhanden oder Eigenschaften nicht lesbar.
        case unavailable
        /// Keine gewöhnliche Datei: Verzeichnis, FIFO, Socket, Gerät.
        case notRegularFile
        /// Größer als ``maximumFileSize``.
        case tooLarge

        /// Begründung für Anzeige und Protokoll — bewusst **ohne Pfad und ohne
        /// Nutzernamen**, damit sie gefahrlos protokolliert werden kann.
        public var reason: String? {
            switch self {
            case .ok, .unavailable: return nil
            case .notRegularFile: return "Die Quelldatei ist keine gewöhnliche Datei."
            case .tooLarge: return "Die Quelldatei ist unerwartet groß."
            }
        }
    }

    /// Prüft, ob die Datei gefahrlos vollständig gelesen werden kann.
    ///
    /// ⚠️ **TOCTOU-Lücke:** diese Prüfung allein reicht nicht, wenn danach
    /// getrennt gelesen wird (`Data(contentsOf:)`) — zwischen `stat` hier und
    /// dem späteren Öffnen kann der Pfad ausgetauscht werden. Für den
    /// eigentlichen Lesevorgang ``readIfSafe(_:)`` verwenden, das denselben
    /// Datei-Deskriptor prüft, den es danach liest. Diese Funktion bleibt für
    /// Stellen, die nur die Klassifikation brauchen (z. B. Anzeige/Log).
    public static func inspect(_ url: URL) -> Verdict {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceTypeKey, .fileSizeKey]) else {
            return .unavailable
        }
        // Bewusst gegen `.regular` geprüft und nicht gegen einzelne unerwünschte
        // Typen: Was nicht ausdrücklich eine gewöhnliche Datei ist, wird nicht
        // gelesen. Symlinks sind damit erlaubt, solange ihr Ziel eine
        // gewöhnliche Datei ist — `resourceValues` folgt ihnen.
        guard values.fileResourceType == .regular else { return .notRegularFile }
        if let size = values.fileSize, size > maximumFileSize { return .tooLarge }
        return .ok
    }

    /// Ergebnis von ``readIfSafe(_:)``.
    public enum ReadResult: Equatable, Sendable {
        /// Gelesen und sicher — die Datei war zum Zeitpunkt des Lesens
        /// gewöhnlich und innerhalb der Größengrenze.
        case success(Data)
        /// Kein Eintrag an diesem Pfad. Eigener Fall statt ``Verdict/unavailable``,
        /// weil er direkt aus `errno` des eigenen `open`-Aufrufs stammt — nicht
        /// aus einer zweiten, erneut fragbaren (und damit erneut TOCTOU-
        /// anfälligen) Existenzprüfung.
        case notFound
        /// Datei existiert, ist aber nicht sicher lesbar — Grund in `Verdict`.
        case rejected(Verdict)
    }

    /// Öffnet und liest eine fremdbestimmte Datei TOCTOU-sicher (CM-16).
    ///
    /// `inspect(_:)` gefolgt von einem eigenen `Data(contentsOf:)` lässt ein
    /// Rennfenster offen: gewinnt zwischen beiden Aufrufen ein anderer Prozess
    /// das Rennen und schiebt eine FIFO unter, blockiert das spätere Öffnen
    /// endlos — genau die Fehlerklasse, gegen die die Wache ursprünglich
    /// gebaut wurde. Diese Funktion prüft stattdessen **denselben
    /// Datei-Deskriptor**, den sie danach liest: `open` mit `O_NONBLOCK`
    /// (kehrt bei einer FIFO ohne Schreiber sofort zurück statt zu blockieren,
    /// für gewöhnliche Dateien wirkungslos), `fstat` auf dem Deskriptor (nicht
    /// erneut auf dem Pfad — der kann sich zwischen zwei `stat`-Aufrufen auf
    /// demselben Pfad ändern, ein bereits offener Deskriptor nicht mehr), erst
    /// danach `read`.
    public static func readIfSafe(_ url: URL) -> ReadResult {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK) }
        guard fd >= 0 else {
            // `errno` sofort auswerten, bevor irgendein weiterer Aufruf ihn
            // überschreibt — insbesondere kein `close` auf einem negativen
            // Deskriptor (das wäre selbst ein Fehlschlag und setzt `errno` neu).
            return errno == ENOENT ? .notFound : .rejected(.unavailable)
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return .rejected(.unavailable) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .rejected(.notRegularFile) }
        guard info.st_size <= maximumFileSize else { return .rejected(.tooLarge) }

        // Gewöhnliche Dateien blockieren bei `read` nie — `O_NONBLOCK` war nur
        // für den `open`-Aufruf oben gegen eine FIFO relevant.
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return .rejected(.unavailable) }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return .success(data)
    }
}
