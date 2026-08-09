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
    /// Diese Accounts werden gezeigt — **nach Namen** sortiert.
    case accounts([MonitoredAccount])

    /// Leitet den Inhalt aus dem Gesamtzustand ab.
    ///
    /// Reihenfolge der Prüfungen: Zahlen zuerst. Liegen Accounts vor, werden
    /// sie gezeigt — auch neben einem Fehlzustand, denn ein kurzzeitig
    /// unlesbarer Store macht die zuletzt gültigen Zahlen nicht wertlos.
    public static func make(for state: MonitorViewState, now: Date = Date()) -> PopoverContent {
        let accounts = state.accounts(now: now)
        if !accounts.isEmpty { return .accounts(sortedByName(accounts)) }
        if state.issue != nil { return .issueOnly }
        return state.isLoading ? .loading : .empty
    }

    /// Sortiert die Kärtchen **nach Anzeigenamen**, nicht nach Ranking.
    ///
    /// **Warum nicht nach Ranking:** Das Detailfenster ist die Nachschlage-,
    /// nicht die Empfehlungsansicht. Springt ein Account darin nach oben, nur
    /// weil sich ein Prozentwert geändert hat, muss man ihn jedes Mal neu
    /// suchen. Die Empfehlung „wohin wechseln" trägt die Menüleiste über die
    /// Rolle ``MenuBarRoleSelection/Role/best``.
    ///
    /// Sortiert wird über ``AccountIdentifierOrder`` — natürlich-numerisch und
    /// **locale-frei**, dieselbe Ordnung wie überall sonst im Projekt. Ein
    /// `localizedStandardCompare` wäre bei Anzeigenamen zwar vertretbar, brächte
    /// aber eine zweite Ordnung ins Projekt; genau davor bewacht der
    /// Quellwächter im Core-Paket dieses Verzeichnis. Sichtbarer Unterschied
    /// nur bei Namen, die mit Sonderzeichen beginnen.
    ///
    /// Bei gleichem Namen entscheidet die Account-Nummer — sonst könnten zwei
    /// gleich benannte Accounts bei jedem Durchlauf die Plätze tauschen.
    static func sortedByName(_ accounts: [MonitoredAccount]) -> [MonitoredAccount] {
        accounts.sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName {
                return AccountIdentifierOrder.isOrderedBefore(lhs.displayName, rhs.displayName)
            }
            return AccountIdentifierOrder.isOrderedBefore(lhs.id, rhs.id)
        }
    }
}
