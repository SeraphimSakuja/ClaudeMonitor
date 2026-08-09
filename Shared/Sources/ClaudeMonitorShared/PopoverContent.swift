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
    /// Diese Accounts werden gezeigt — **nach Account-Nummer** sortiert.
    case accounts([MonitoredAccount])

    /// Leitet den Inhalt aus dem Gesamtzustand ab.
    ///
    /// Reihenfolge der Prüfungen: Zahlen zuerst. Liegen Accounts vor, werden
    /// sie gezeigt — auch neben einem Fehlzustand, denn ein kurzzeitig
    /// unlesbarer Store macht die zuletzt gültigen Zahlen nicht wertlos.
    public static func make(for state: MonitorViewState, now: Date = Date()) -> PopoverContent {
        let accounts = state.accounts(now: now)
        if !accounts.isEmpty { return .accounts(sortedByNumber(accounts)) }
        if state.issue != nil { return .issueOnly }
        return state.isLoading ? .loading : .empty
    }

    /// Sortiert die Kärtchen **nach Account-Nummer**, nicht nach Ranking.
    ///
    /// **Warum nicht nach Ranking:** Das Detailfenster ist die Nachschlage-,
    /// nicht die Empfehlungsansicht. Springt ein Account darin nach oben, nur
    /// weil sich ein Prozentwert geändert hat, muss man ihn jedes Mal neu
    /// suchen. Die Empfehlung „wohin wechseln" trägt die Menüleiste über die
    /// Rolle ``MenuBarRoleSelection/Role/best``.
    ///
    /// **Warum die Nummer und nicht der Name:** Die Nummer ist die Kennung, mit
    /// der man in claude-swap wechselt, und sie ist **stabil**. Ein Alias lässt
    /// sich jederzeit umbenennen — danach stünde die Liste in einer anderen
    /// Reihenfolge, ohne dass sich an den Accounts etwas geändert hätte.
    ///
    /// Sortiert wird über ``AccountIdentifierOrder`` — natürlich-numerisch, also
    /// `#2` vor `#10`, und locale-frei. Dieselbe Ordnung wie überall sonst im
    /// Projekt; eine zweite daneben ist genau das, was der Quellwächter im
    /// Core-Paket für dieses Verzeichnis verhindert.
    static func sortedByNumber(_ accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        accounts.sorted { AccountIdentifierOrder.isOrderedBefore($0.id, $1.id) }
    }
}
