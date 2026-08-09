import Foundation
import ClaudeMonitorCore

/// Die Beträge eines Ausgabenfensters — „12,34 $" und „50,00 $".
///
/// **Warum überhaupt Beträge:** Ein `spend`-Fenster als bloße „78 %" zu zeigen,
/// verschweigt die einzige Zahl, die man beim Geldausgeben wirklich will. Die
/// Prozentangabe sagt, wie voll es ist; der Betrag sagt, worum es geht.
///
/// Die Regel liegt in `Shared/` und nicht in der View, weil sie Fehlfälle hat,
/// die man prüfen können muss: fehlende Währung, ein Limit von null,
/// nicht-endliche Werte aus einer kaputten Quelle.
///
/// **Nur die Zahlen, nicht der Satz.** Wie „X von Y" heißt, steht im
/// Sprachkatalog der App — `Shared/` ist ein Paket ohne Ressourcen, ein
/// `NSLocalizedString` gäbe hier stumm den Schlüssel zurück.
public enum SpendAmountDisplay: Equatable, Sendable {

    /// Was zu einem Ausgabenfenster gesagt werden kann.
    public struct Amounts: Equatable, Sendable {
        /// Bereits verbraucht.
        public let used: String
        /// Gesamtbudget; `nil`, wenn keins bekannt ist.
        public let limit: String?

        public init(used: String, limit: String?) {
            self.used = used
            self.limit = limit
        }
    }

    /// Formatierte Beträge; `nil`, wenn sich nichts Sinnvolles sagen lässt.
    ///
    /// - Parameter locale: Injizierbar, damit die Prüfung nicht an der
    ///   Systemsprache des Testrechners hängt.
    public static func amounts(
        for spend: LimitWindow.SpendDetail,
        locale: Locale = .autoupdatingCurrent
    ) -> Amounts? {
        guard spend.used.isFinite, spend.used >= 0 else { return nil }

        let used = amount(spend.used, currency: spend.currency, locale: locale)
        // Ein Limit von null ist kein Limit, sondern eine fehlende Angabe:
        // „12,34 $ von 0,00 $" läse sich wie ein gesprengtes Budget.
        guard spend.limit.isFinite, spend.limit > 0 else {
            return Amounts(used: used, limit: nil)
        }
        return Amounts(used: used, limit: amount(spend.limit, currency: spend.currency, locale: locale))
    }

    /// Ein einzelner Betrag. Ohne bekannte Währung bleibt es eine reine Zahl —
    /// eine geratene Währung wäre schlimmer als gar keine.
    static func amount(_ value: Double, currency: String?, locale: Locale) -> String {
        guard let currency, !currency.isEmpty else {
            return value.formatted(.number.precision(.fractionLength(2)).locale(locale))
        }
        return value.formatted(.currency(code: currency).locale(locale))
    }
}
