import Foundation
import ClaudeMonitorCore

/// Der Anzeigename eines Limitfensters — die **eine** Abbildung von
/// ``LimitWindow/Kind`` auf lesbaren Text.
///
/// Liegt in `Shared/` und nicht im App-Target, weil die Zeile im Detailfenster,
/// der Vorlesetext der Menüleiste und später die Widget-Extension exakt
/// denselben Namen brauchen; zwei Kopien laufen garantiert auseinander (die
/// gab es hier bereits einmal).
///
/// `scoped`- und unbekannte Fenster tragen Namen aus der Quelle. Die sind nicht
/// übersetzbar und werden deshalb unverändert durchgereicht — lieber ein roher
/// Schlüssel als ein verschlucktes Fenster.
///
/// Die Schlüssel liegen bewusst weiter im Katalog des App-Targets: `bundle: nil`
/// löst gegen `Bundle.main` auf, und das ist auch aus diesem Paket heraus die
/// App. Es gibt deshalb **keine** neuen Schlüssel für diesen Umzug.
public enum WindowKindNaming {

    /// Anzeigename des Fensters in der aktuellen Sprache.
    public static func name(for kind: LimitWindow.Kind) -> String {
        switch kind {
        case .fiveHour:
            return String(localized: "5 hours", comment: "Name des rollierenden 5-Stunden-Limitfensters")
        case .sevenDay:
            return String(localized: "7 days", comment: "Name des Wochenlimit-Fensters")
        case .spend:
            return String(localized: "Spend", comment: "Name des Ausgabenfensters")
        case .scoped(let name):
            return name
        case .other(let rawKey):
            return rawKey
        }
    }

    /// `true`, wenn der Name aus dem Katalog kommt — und nicht roh aus der
    /// Quelle. Trennt die beiden Fälle für Aufrufer, die den Unterschied
    /// darstellen müssen (SwiftUI: `Text(verbatim:)` vs. übersetzter Text).
    public static func isLocalized(_ kind: LimitWindow.Kind) -> Bool {
        switch kind {
        case .fiveHour, .sevenDay, .spend: return true
        case .scoped, .other: return false
        }
    }
}
