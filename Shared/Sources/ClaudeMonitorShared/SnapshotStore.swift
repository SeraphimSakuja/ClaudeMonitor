import Foundation
import ClaudeMonitorCore

/// Die Ablage im App-Group-Container — Schreiber ist die Menüleisten-App,
/// Leser ist die (sandboxed) WidgetKit-Extension.
///
/// Die Extension darf weder `~/.claude-swap-backup/…` lesen noch fremde
/// Prozesse starten; diese Datei ist ihre einzige Datenquelle. Beide Seiten
/// benutzen deshalb **dieselbe** Implementierung, statt sie je Ziel nachzubauen.
///
/// Geschrieben wird **atomar**. Ein Widget-Reload kann jederzeit mitten in einen
/// Schreibvorgang fallen; ohne Atomarität läse er halbe Dateien und das Widget
/// zeigte stillschweigend nichts an.
///
/// Der Store fasst ausschließlich den eigenen Container an — niemals
/// claude-swaps `usage.json` (Leitplanke L1).
public struct SnapshotStore: Sendable {

    /// Ergebnis eines Schreibversuchs. Jeder Fehlfall ist ein definierter
    /// Zustand, den die App protokollieren kann, ohne abzustürzen.
    public enum WriteResult: Equatable, Sendable {
        /// Erfolgreich geschrieben.
        case written(URL)
        /// Kein App-Group-Container verfügbar — typischerweise, weil das
        /// Entitlement mangels Team-ID noch nicht greift (SSOT-Punkt CM-01).
        /// Die Menüleiste funktioniert weiter, nur die Widgets bekommen keine
        /// Daten.
        case containerUnavailable(groupIdentifier: String)
        /// Container vorhanden, Schreiben trotzdem fehlgeschlagen.
        case failed(reason: String)
    }

    /// Kennung der App Group.
    public let groupIdentifier: String
    /// Dateiname im Container.
    public let fileName: String

    public init(
        groupIdentifier: String = AppGroup.identifier,
        fileName: String = AppGroup.snapshotFileName
    ) {
        self.groupIdentifier = groupIdentifier
        self.fileName = fileName
    }

    /// Verzeichnis des App-Group-Containers; `nil`, wenn das Entitlement nicht
    /// greift.
    public var containerDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    // MARK: - Schreiben (Menüleisten-App)

    /// Schreibt in den App-Group-Container.
    ///
    /// Fehlt der Container, ist das **kein** Absturzgrund: Der Zustand wird
    /// zurückgegeben, die aufrufende App protokolliert ihn und läuft weiter.
    @discardableResult
    public func write(_ snapshot: AccountsSnapshot) -> WriteResult {
        guard let directory = containerDirectory else {
            return .containerUnavailable(groupIdentifier: groupIdentifier)
        }
        return write(snapshot, into: directory)
    }

    /// Schreibt in ein konkretes Verzeichnis. Getrennt vom Container-Lookup,
    /// damit der Vertrag mit der Widget-Extension ohne App-Group-Entitlement
    /// geprüft werden kann.
    @discardableResult
    public func write(_ snapshot: AccountsSnapshot, into directory: URL) -> WriteResult {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        do {
            let data = try SnapshotCoding.encode(snapshot)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomar: Ein Leser sieht entweder den alten oder den neuen Stand,
            // nie einen halben.
            try data.write(to: url, options: [.atomic])
            return .written(url)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    // MARK: - Lesen (Widget-Extension)

    /// Liest den Snapshot aus dem App-Group-Container.
    public func read() throws -> AccountsSnapshot {
        guard let directory = containerDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try read(from: directory)
    }

    /// Liest den Snapshot aus einem konkreten Verzeichnis — genau der Weg, den
    /// die Widget-Extension geht.
    public func read(from directory: URL) throws -> AccountsSnapshot {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        return try SnapshotCoding.decode(try Data(contentsOf: url))
    }
}
