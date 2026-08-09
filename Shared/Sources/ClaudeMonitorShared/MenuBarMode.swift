import Foundation

/// Was die Menüleiste zeigt.
///
/// Die Wahl ist eine reine Anzeigeeinstellung und hängt bewusst **nicht** am
/// Poller: Sie darf sofort wirken, nicht erst beim nächsten 30-s-Durchlauf.
public enum MenuBarMode: String, CaseIterable, Sendable, Equatable {

    /// Nur der in claude-swap **aktive** Account — Standard, weil die Leiste
    /// damit schmal bleibt.
    ///
    /// Bis v0.x zeigte dieser Modus den *gerankten ersten* Account. Der aktive
    /// ist die nützlichere Auskunft: Man will wissen, wie es um den steht, mit
    /// dem man gerade arbeitet — nicht um einen, auf den man wechseln könnte.
    /// Ist kein Account als aktiv markiert (fehlende `sequence.json`), fällt die
    /// Anzeige auf den gerankten ersten zurück, statt leer zu bleiben.
    case activeAccount
    /// Bis zu drei Accounts nach Rolle: aktiv, bester, frühester Reset
    /// (``MenuBarRoleSelection``). Weniger, wenn ein Account mehrere Rollen
    /// hält.
    case overview

    /// Aus einem gespeicherten Rohwert (`UserDefaults`) gelesen.
    ///
    /// Unbekannter Wert oder `nil` ⇒ ``activeAccount``. Eine fremde oder ältere
    /// Fassung darf die Leiste nicht leer lassen; der Standard ist der einzige
    /// Zustand, der ohne Vorwissen richtig ist.
    ///
    /// ⚠️ **Die Rohwerte aus v0.x werden ausdrücklich abgebildet.** Ohne diese
    /// beiden Zeilen fiele ein gespeichertes `allAccounts` in den Standardzweig
    /// und der Nutzer stünde nach dem Update **still** wieder auf der schmalen
    /// Anzeige — eine Einstellung, die er bewusst gesetzt hat, verschwände
    /// wortlos. Die alten Werte tauchen in keinem `rawValue` mehr auf; nur
    /// dieser Schritt hält sie am Leben.
    public init(storedValue: String?) {
        guard let storedValue else {
            self = .activeAccount
            return
        }
        if let mode = MenuBarMode(rawValue: storedValue) {
            self = mode
            return
        }
        switch storedValue {
        case "bestAccount": self = .activeAccount
        case "allAccounts": self = .overview
        default: self = .activeAccount
        }
    }
}
