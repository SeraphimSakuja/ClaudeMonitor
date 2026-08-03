import Foundation
import ClaudeMonitorCore

/// Was in der Menüleiste steht: Farbe und Prozentwert des **besten** Accounts.
///
/// Bewusst nur ein Account statt einer Liste — die Anzeige muss auch bei fünf
/// und mehr Accounts schmal bleiben. Die vollständige Übersicht liefert das
/// Detailfenster.
///
/// Farbe und Zahl stammen garantiert aus **derselben** Quelle:
/// ``MonitoredAccount/bindingPercent``, dem am höchsten ausgelasteten Fenster
/// des Accounts. Genau diese Property bestimmt auch
/// ``MonitoredAccount/overallStatus`` **und** die Reihenfolge in
/// ``AccountRanking``. Damit kann nie ein roter Punkt neben „12 %" stehen und
/// nie ein rot angezeigter Account über einem grünen — Anzeige und Ranking
/// messen dasselbe, weil sie dieselbe Property lesen.
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
        // Dieselbe Property wie `overallStatus` und `AccountRanking` — nicht
        // nachgebaut, sondern gelesen, damit Zahl, Farbe und Reihenfolge nicht
        // auseinanderlaufen können.
        let peak = account.bindingPercent
        let status = account.overallStatus
        guard let peak, peak.isFinite else {
            // Kaputter Wert: Die Ampel darf (konservativ rot) stehen bleiben,
            // eine Zahl gibt es dazu nicht.
            return MenuBarDisplay(percent: nil, status: status)
        }
        return MenuBarDisplay(percent: peak, status: status)
    }
}
