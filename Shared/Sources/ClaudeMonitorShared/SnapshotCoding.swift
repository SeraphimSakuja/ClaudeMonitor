import Foundation
import ClaudeMonitorCore

/// Der Codier-Vertrag zwischen Menüleisten-App (Schreiber) und Widget-Extension
/// (Leser).
///
/// Bewusst **eine** Stelle für Encoder und Decoder: Driften die Einstellungen
/// auseinander — etwa unterschiedliche `dateEncodingStrategy` —, scheitert das
/// Widget still und zeigt nichts an, ohne dass jemand einen Fehler sieht.
/// Deshalb gibt es hier keine zweite Konfigurationsmöglichkeit.
public enum SnapshotCoding {

    /// Zeitstempel werden als Epochensekunden übertragen — verlustfrei und
    /// dieselbe Einheit, die claude-swap selbst benutzt. `.iso8601` wäre besser
    /// lesbar, schneidet aber die Sekundenbruchteile ab; ein Snapshot ließe sich
    /// dann nicht mehr identisch zurücklesen und der Vertragstest mit der
    /// Widget-Extension wäre wertlos.
    ///
    /// Encoder für den App-Group-Snapshot.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        // Sortierte Schlüssel: Ein unveränderter Zustand ergibt byteidentische
        // Dateien — das macht überflüssige Schreibvorgänge erkennbar.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Decoder für den App-Group-Snapshot.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Kodiert einen Snapshot.
    public static func encode(_ snapshot: AccountsSnapshot) throws -> Data {
        try makeEncoder().encode(snapshot)
    }

    /// Dekodiert einen Snapshot.
    public static func decode(_ data: Data) throws -> AccountsSnapshot {
        try makeDecoder().decode(AccountsSnapshot.self, from: data)
    }
}
