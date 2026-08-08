import Foundation

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
    public enum Verdict: Equatable, Sendable {
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
}
