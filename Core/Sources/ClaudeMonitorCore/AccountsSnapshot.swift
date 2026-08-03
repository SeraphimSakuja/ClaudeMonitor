import Foundation

/// Vollständiger, in sich abgeschlossener Zustand aller Accounts zu einem Zeitpunkt.
///
/// `Codable`, weil die Menüleisten-App diesen Snapshot in den App-Group-Container
/// schreibt und die WidgetKit-Extension ihn dort liest — die Extension darf weder
/// fremde Prozesse starten noch beliebige Home-Pfade lesen.
public struct AccountsSnapshot: Sendable, Codable, Equatable {

    /// Accounts in der Reihenfolge, in der sie gelesen wurden (Ranking macht ``AccountRanking``).
    public let accounts: [MonitoredAccount]
    /// Zeitpunkt, zu dem dieser Snapshot gebildet wurde.
    public let capturedAt: Date
    /// `schemaVersion` der gelesenen Quelle — damit ein alter Snapshot im
    /// App-Group-Container später noch einordbar bleibt.
    public let sourceSchemaVersion: Int

    public init(accounts: [MonitoredAccount], capturedAt: Date, sourceSchemaVersion: Int) {
        self.accounts = accounts
        self.capturedAt = capturedAt
        self.sourceSchemaVersion = sourceSchemaVersion
    }

    /// Accounts nach Verfügbarkeit sortiert, bester zuerst.
    public func rankedAccounts(now: Date = Date()) -> [MonitoredAccount] {
        AccountRanking.ranked(accounts, now: now)
    }
}
