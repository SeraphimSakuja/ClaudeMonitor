import Foundation

/// Vollständiger, in sich abgeschlossener Zustand aller Accounts zu einem Zeitpunkt.
///
/// `Codable`, weil die Menüleisten-App diesen Snapshot in den App-Group-Container
/// schreibt und die WidgetKit-Extension ihn dort liest — die Extension darf weder
/// fremde Prozesse starten noch beliebige Home-Pfade lesen.
public struct AccountsSnapshot: Sendable, Codable, Equatable {

    /// Version des **Codable-Layouts dieses Snapshots** — nicht zu verwechseln
    /// mit ``sourceSchemaVersion``, die claude-swaps Dateiformat verfolgt.
    ///
    /// Beide ändern sich unabhängig: Kommt hier später ein neuer
    /// ``LimitWindow/Kind``- oder ``AccountState``-Fall dazu, scheitert eine
    /// noch nicht aktualisierte Widget-Extension sonst *still* am Decodieren.
    /// Mit dieser Versionsnummer scheitert sie stattdessen laut und definiert.
    public static let currentFormatVersion = 1

    /// Layout-Version, mit der dieser Snapshot geschrieben wurde.
    public let formatVersion: Int
    /// Accounts in der Reihenfolge, in der sie gelesen wurden (Ranking macht ``AccountRanking``).
    public let accounts: [MonitoredAccount]
    /// Zeitpunkt, zu dem dieser Snapshot gebildet wurde.
    public let capturedAt: Date
    /// `schemaVersion` der gelesenen Quelle — damit ein alter Snapshot im
    /// App-Group-Container später noch einordbar bleibt.
    public let sourceSchemaVersion: Int

    public init(
        accounts: [MonitoredAccount],
        capturedAt: Date,
        sourceSchemaVersion: Int,
        formatVersion: Int = AccountsSnapshot.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.accounts = accounts
        self.capturedAt = capturedAt
        self.sourceSchemaVersion = sourceSchemaVersion
    }

    /// Prüft die Layout-Version beim Decodieren hart: Ein Snapshot aus einer
    /// neueren (oder unbekannt alten) Version wird abgelehnt, statt teilweise
    /// interpretiert zu werden.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Snapshots ohne Feld stammen aus der ersten Fassung des Layouts.
        let version = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? AccountsSnapshot.currentFormatVersion
        guard version == AccountsSnapshot.currentFormatVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: """
                    Snapshot-Format \(version) ist nicht lesbar                     (erwartet \(AccountsSnapshot.currentFormatVersion)).
                    """
                )
            )
        }
        formatVersion = version
        accounts = try container.decode([MonitoredAccount].self, forKey: .accounts)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sourceSchemaVersion = try container.decode(Int.self, forKey: .sourceSchemaVersion)
    }

    /// Accounts nach Verfügbarkeit sortiert, bester zuerst.
    public func rankedAccounts(now: Date = Date()) -> [MonitoredAccount] {
        AccountRanking.ranked(accounts, now: now)
    }
}
