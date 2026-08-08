import Foundation

/// Wie viele Accounts die Menüleiste zeigt.
///
/// Die Wahl ist eine reine Anzeigeeinstellung und hängt bewusst **nicht** am
/// Poller: Sie darf sofort wirken, nicht erst beim nächsten 30-s-Durchlauf.
public enum MenuBarMode: String, CaseIterable, Sendable, Equatable {

    /// Nur der gerankte erste Account — Standard, weil die Leiste damit schmal
    /// bleibt.
    case bestAccount
    /// Alle Accounts nebeneinander, getrennt dargestellt.
    case allAccounts

    /// Aus einem gespeicherten Rohwert (`UserDefaults`) gelesen.
    ///
    /// Unbekannter Wert oder `nil` ⇒ ``bestAccount``. Eine fremde oder ältere
    /// Fassung darf die Leiste nicht leer lassen; der Standard ist der einzige
    /// Zustand, der ohne Vorwissen richtig ist.
    public init(storedValue: String?) {
        guard let storedValue, let mode = MenuBarMode(rawValue: storedValue) else {
            self = .bestAccount
            return
        }
        self = mode
    }
}
