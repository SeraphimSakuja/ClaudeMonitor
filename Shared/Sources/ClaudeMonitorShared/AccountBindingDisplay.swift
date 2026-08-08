import Foundation
import ClaudeMonitorCore

/// Die **eine Zahl** eines Accounts: seine bindende Auslastung samt Ampelstufe.
///
/// Zahl und Farbe stammen garantiert aus derselben Quelle —
/// ``MonitoredAccount/bindingPercent`` und ``MonitoredAccount/overallStatus``,
/// beides Ableitungen des am höchsten ausgelasteten Fensters. Genau diese
/// Größe bestimmt auch die Reihenfolge in ``AccountRanking``; deshalb kann nie
/// ein roter Punkt neben „12 %" stehen und nie ein rot angezeigter Account
/// über einem grünen.
///
/// Die harte Zusage: **kein verwertbarer Datenstand ⇒ keine Zahl und keine
/// Farbe — niemals „0 %".** Ein toter Token trägt oft noch eingefrorene
/// Altwerte im Store; die dürfen weder als Zahl noch als grüne Ampel erscheinen.
///
/// Einziger Verwender ist die **Kopfzeile der Account-Karte**. Die Menüleiste
/// benutzt diesen Typ ausdrücklich *nicht*: Sie zeigt je Account zwei Zahlen
/// (5 h und 7 d) und dazu **einen** Punkt, dessen Farbe sie mit
/// ``MonitoredAccount/overallStatus`` aus derselben Property zieht wie dieser
/// Typ — siehe ``MenuBarDisplay/AccountSegment/status``. Dass beide Wege zur
/// selben Farbe führen, ist damit keine Zusage über zwei Rechenwege, sondern
/// ein und dieselbe gelesene Größe.
public struct AccountBindingDisplay: Equatable, Sendable {

    /// Bindende Auslastung; `nil` ⇒ **kein** Wert, kein „0 %".
    public let percent: Double?
    /// Ampelfarbe; `nil` ⇒ neutrales Symbol.
    public let status: StatusLevel?

    public init(percent: Double?, status: StatusLevel?) {
        self.percent = percent
        self.status = status
    }

    /// Fertiger Text; `nil`, wenn keine Zahl anzuzeigen ist.
    public var text: String? {
        percent.flatMap(PercentFormatting.compact)
    }

    /// `true`, wenn eine Zahl angezeigt wird.
    public var hasValue: Bool { text != nil }

    /// Leere Anzeige — neutrales Symbol, keine erfundene Zahl.
    public static let unavailable = AccountBindingDisplay(percent: nil, status: nil)

    /// Bildet die Anzeige aus einem Account.
    public static func make(for account: MonitoredAccount?) -> AccountBindingDisplay {
        guard let account, account.hasUsableData else { return .unavailable }
        // Dieselbe Property wie `overallStatus` und `AccountRanking` — nicht
        // nachgebaut, sondern gelesen, damit Zahl, Farbe und Reihenfolge nicht
        // auseinanderlaufen können.
        let peak = account.bindingPercent
        let status = account.overallStatus
        guard let peak, peak.isFinite else {
            // Kaputter Wert: Die Ampel darf (konservativ rot) stehen bleiben,
            // eine Zahl gibt es dazu nicht.
            return AccountBindingDisplay(percent: nil, status: status)
        }
        return AccountBindingDisplay(percent: peak, status: status)
    }
}
