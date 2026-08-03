import Foundation
import ClaudeMonitorCore

/// Was der Hauptbereich des Detailfensters zeigt — genau **eine** der vier
/// Möglichkeiten.
///
/// Als Aufzählung in `Shared/` statt als `if`-Kette in der View: Die
/// Verzweigung ist damit prüfbar. In der View war sie es nicht, und genau dort
/// entstand der Fall „Fehlzustand **und** leere Liste" — der Hinweisbalken
/// stand über einem leeren, aber sichtbaren Scrollbereich.
public enum PopoverContent: Equatable, Sendable {

    /// Erster Lesevorgang läuft noch, es gibt nichts zu zeigen.
    case loading
    /// Fertig gelesen, keine Accounts, kein Fehlzustand — claude-swap verwaltet
    /// tatsächlich keine Accounts.
    case empty
    /// Keine Accounts, aber ein Fehlzustand. Der Hinweisbalken erklärt die Lage
    /// bereits; ein zusätzlicher (leerer) Bereich darunter wäre nur Lärm.
    case issueOnly
    /// Diese Accounts werden gezeigt — in Ranking-Reihenfolge.
    case accounts([MonitoredAccount])

    /// Leitet den Inhalt aus dem Gesamtzustand ab.
    ///
    /// Reihenfolge der Prüfungen: Zahlen zuerst. Liegen Accounts vor, werden
    /// sie gezeigt — auch neben einem Fehlzustand, denn ein kurzzeitig
    /// unlesbarer Store macht die zuletzt gültigen Zahlen nicht wertlos.
    public static func make(for state: MonitorViewState, now: Date = Date()) -> PopoverContent {
        let accounts = state.accounts(now: now)
        if !accounts.isEmpty { return .accounts(accounts) }
        if state.issue != nil { return .issueOnly }
        return state.isLoading ? .loading : .empty
    }
}
