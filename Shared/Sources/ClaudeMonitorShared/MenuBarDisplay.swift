import Foundation
import ClaudeMonitorCore

/// Was in der Menüleiste steht: Farbe und Prozentwert des **besten** Accounts.
///
/// Bewusst nur ein Account statt einer Liste — die Anzeige muss auch bei fünf
/// und mehr Accounts schmal bleiben. Die vollständige Übersicht liefert das
/// Detailfenster.
///
/// Farbe und Zahl stammen garantiert aus **derselben** Quelle: dem am höchsten
/// ausgelasteten Fenster des Accounts. Genau dieses Fenster bestimmt auch
/// ``MonitoredAccount/overallStatus``. Damit kann nie ein roter Punkt neben
/// „12 %" stehen. Im Normalfall (5h- und 7d-Fenster vorhanden) ist das exakt die
/// bindende Auslastung `max(5h, 7d)`; liegt zusätzlich ein `scoped`- oder
/// `spend`-Fenster höher, zeigt die Menüleiste dieses — es begrenzt den Account
/// dann tatsächlich.
public struct MenuBarDisplay: Equatable, Sendable {

    /// Anzuzeigende Auslastung; `nil` ⇒ **kein** Wert, kein „0 %".
    public let percent: Double?
    /// Ampelfarbe; `nil` ⇒ neutrales Symbol.
    public let status: StatusLevel?

    /// Fertiger Text; `nil`, wenn keine Zahl anzuzeigen ist.
    public var text: String? {
        percent.flatMap(PercentFormatting.compact)
    }

    /// `true`, wenn eine Zahl angezeigt wird.
    public var hasValue: Bool { text != nil }

    /// Leere Anzeige — neutrales Symbol, keine erfundene Zahl.
    public static let unavailable = MenuBarDisplay(percent: nil, status: nil)

    /// Bildet die Anzeige aus dem Gesamtzustand.
    public static func make(for state: MonitorViewState, now: Date = Date()) -> MenuBarDisplay {
        make(for: state.bestAccount(now: now))
    }

    /// Bildet die Anzeige aus einem Account.
    public static func make(for account: MonitoredAccount?) -> MenuBarDisplay {
        guard let account, account.hasUsableData else { return .unavailable }
        // Dieselbe Reduktion wie in `overallStatus` — nicht nachgebaut, sondern
        // derselbe Ausdruck, damit Zahl und Farbe nicht auseinanderlaufen können.
        let peak = account.windows.map(\.percent).max()
        let status = account.overallStatus
        guard let peak, peak.isFinite else {
            // Kaputter Wert: Die Ampel darf (konservativ rot) stehen bleiben,
            // eine Zahl gibt es dazu nicht.
            return MenuBarDisplay(percent: nil, status: status)
        }
        return MenuBarDisplay(percent: peak, status: status)
    }
}
