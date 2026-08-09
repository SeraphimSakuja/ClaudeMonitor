import Foundation
import ClaudeMonitorCore

/// Regeln des Account-Kärtchens, die nichts mit den Zahlen selbst zu tun haben.
public enum AccountCardDisplay {

    /// Ob unter dem Kärtchen noch „zuletzt aktualisiert vor …" stehen soll.
    ///
    /// **Nein, wenn die Statuszeile das Alter bereits nennt.** Bei veralteten
    /// Daten stand bisher zweimal dasselbe im selben Kärtchen — oben
    /// „Daten sind veraltet: 46 Min." und unten „Vor 46 Min. aktualisiert". Das
    /// kostete eine Zeile je Account und sagte beim zweiten Mal nichts Neues.
    ///
    /// Die Pflicht-Angabe aus der Spezifikation („veraltete Daten → Wert **mit
    /// Altersangabe**") bleibt dabei erhalten: Sie wandert nicht weg, sie steht
    /// nur noch an **einer** Stelle — der auffälligeren.
    public static func showsUpdatedFooter(statusLine: AccountStatusLine) -> Bool {
        if case .stale = statusLine { return false }
        return true
    }
}
