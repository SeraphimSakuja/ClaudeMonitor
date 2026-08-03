import Foundation
import ClaudeMonitorCore

/// Ein Fehlzustand, der statt (oder über) den Zahlen angezeigt wird.
public enum MonitorIssue: Equatable, Sendable {
    /// Keine `usage.json` gefunden — claude-swap ist vermutlich nicht
    /// installiert. Die UI zeigt einen Erstinbetriebnahme-Hinweis.
    case storeNotFound(searchedPaths: [String])
    /// `schemaVersion` weicht ab (Leitplanke L4).
    case unsupportedSchema(found: Int?, expected: Int)
    /// Datei da, aber nicht lesbar — meist ein halb geschriebener Stand, der
    /// beim nächsten Durchlauf von selbst heilt.
    case unreadable(reason: String)
}

/// Was die UI gerade weiß.
///
/// Bewusst getrennt von ``UsageStoreReadResult``: Ein einzelner Lesefehler darf
/// die zuletzt gültigen Zahlen nicht wegwerfen, ein Formatbruch dagegen muss es.
/// Diese Regel steckt in ``reduced(with:)`` und ist damit prüfbar, statt in der
/// View zu stecken.
public struct MonitorViewState: Equatable, Sendable {

    /// Letzter erfolgreich gelesener Stand; `nil`, solange nichts gelesen wurde
    /// oder die Zahlen bewusst verworfen wurden.
    public var snapshot: AccountsSnapshot?
    /// Aktuell anliegender Fehlzustand.
    public var issue: MonitorIssue?
    /// `true`, bis der erste Lesevorgang abgeschlossen ist.
    public var isLoading: Bool

    public init(snapshot: AccountsSnapshot? = nil, issue: MonitorIssue? = nil, isLoading: Bool = true) {
        self.snapshot = snapshot
        self.issue = issue
        self.isLoading = isLoading
    }

    /// Neuer Zustand nach einem Lesevorgang.
    ///
    /// - `success` → neue Zahlen, Fehlzustand aufgehoben.
    /// - `unreadable` → Fehlzustand **zusätzlich** zu den alten Zahlen: Der
    ///   Store ist genau dann kurz unlesbar, wenn claude-swap gerade schreibt;
    ///   die Anzeige alle 30 s leerzuräumen wäre Flackern ohne Informationswert.
    ///   Das Datenalter bleibt sichtbar, die Zahlen sind also einordenbar.
    /// - `storeNotFound` → Zahlen verwerfen: Ohne Quelle ist jede weiter
    ///   angezeigte Zahl eine Behauptung ins Blaue.
    /// - `unsupportedSchemaVersion` → Zahlen verwerfen (L4): lieber „Format
    ///   geändert" anzeigen als möglicherweise falsche Werte.
    public func reduced(with result: UsageStoreReadResult) -> MonitorViewState {
        switch result {
        case .success(let snapshot):
            return MonitorViewState(snapshot: snapshot, issue: nil, isLoading: false)
        case .unreadable(let reason):
            return MonitorViewState(
                snapshot: snapshot,
                issue: .unreadable(reason: reason),
                isLoading: false
            )
        case .storeNotFound(let paths):
            return MonitorViewState(
                snapshot: nil,
                issue: .storeNotFound(searchedPaths: paths),
                isLoading: false
            )
        case .unsupportedSchemaVersion(let found, let expected):
            return MonitorViewState(
                snapshot: nil,
                issue: .unsupportedSchema(found: found, expected: expected),
                isLoading: false
            )
        }
    }

    /// Accounts in Anzeigereihenfolge — der beste zuerst.
    ///
    /// Die Reihenfolge stammt ausschließlich aus ``AccountRanking`` (über
    /// ``AccountsSnapshot/rankedAccounts(now:)``); die UI sortiert nichts
    /// eigenes dazu. Im Snapshot selbst stehen die Accounts nur in stabiler
    /// Kennungsreihenfolge — das Ranking hängt an `now` (Restzeiten) und muss
    /// deshalb bei jeder Anzeige frisch gebildet werden.
    public func accounts(now: Date = Date()) -> [MonitoredAccount] {
        snapshot?.rankedAccounts(now: now) ?? []
    }

    /// Bester Account = erster der gerankten Liste.
    public func bestAccount(now: Date = Date()) -> MonitoredAccount? {
        accounts(now: now).first
    }
}
