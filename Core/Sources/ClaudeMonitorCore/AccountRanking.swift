import Foundation

/// Sortiert Accounts nach Verfügbarkeit — der beste steht vorne.
///
/// Reihenfolge der Kriterien (jeweils nur bei Gleichstand das nächste):
///
/// 1. **Verfügbarkeitsrang.** Drei Klassen, in dieser Ordnung:
///    `0` nutzbar, `1` nutzbar aber **blockiert** (irgendein Fenster steht auf
///    100 % oder mehr — der Account ist bis zu seinem Reset unbrauchbar und darf
///    nie als Empfehlung oben stehen), `2` ohne verwertbare Daten (keine Daten
///    oder toter Token). Ein blockierter Account rangiert also hinter jedem
///    freien und vor den datenlosen: Er hat echte Zahlen, die die UI zeigen kann.
/// 2. **Niedrigste 5-Stunden-Auslastung** — das ist das Fenster, das die
///    unmittelbare Arbeitsfähigkeit begrenzt.
/// 3. **Niedrigste Wochen-Auslastung.**
/// 4. **Frühester Reset**, aufsteigend: die *kürzeste* Restzeit über alle
///    Fenster. `resets_at` ist der Zeitpunkt des Auffüllens — wer zuerst
///    zurückgesetzt wird, ist zuerst wieder verfügbar. Ein Account ohne jeden
///    bekannten Reset sortiert hier ans Ende.
/// 5. **Kennung** — stabiler, locale-freier Tiebreaker (``AccountIdentifierOrder``),
///    damit die Reihenfolge bei völligem Gleichstand deterministisch ist.
///
/// Alle Kriterien sind Total-Ordnungen über endliche Werte; das Prädikat
/// ``isOrderedBefore(_:_:)`` ist damit eine strikte schwache Ordnung, wie es
/// `sort` verlangt (NaN und Sentinel-Werte werden vorher abgefangen).
public enum AccountRanking {

    /// Sortierschlüssel eines Accounts.
    ///
    /// Bewusst **intern**: Die Felder tragen Sentinel-Werte
    /// (``worstSortValue``) für „nicht vorhanden". Wären sie öffentlich, könnte
    /// die UI-Schicht sie versehentlich als „1,797e308 %" rendern. Die UI liest
    /// Prozentwerte ausschließlich über ``MonitoredAccount`` (dort optional).
    struct Key: Sendable, Equatable {
        /// 0 = nutzbar, 1 = blockiert (Fenster >= 100 %), 2 = ohne Daten.
        let availabilityRank: Int
        /// Auslastung 5h; fehlendes Fenster zählt als maximal ausgelastet.
        let fiveHourPercent: Double
        /// Auslastung 7d; fehlendes Fenster zählt als maximal ausgelastet.
        let sevenDayPercent: Double
        /// Kürzeste Restzeit über alle Fenster; ohne bekannten Reset maximal.
        let earliestReset: TimeInterval
        /// Stabiler Tiebreaker.
        let identifier: String
    }

    /// Wert, mit dem fehlende oder unbrauchbare Zahlen einsortiert werden —
    /// egal ob Prozent- oder Zeitwert: so schlecht wie möglich, aber endlich
    /// (NaN würde die Sortierordnung verletzen).
    static let worstSortValue = Double.greatestFiniteMagnitude

    /// Ab diesem Prozentwert gilt ein Fenster als ausgeschöpft und der Account
    /// bis zu seinem Reset als blockiert.
    static let blockedThreshold: Double = 100

    /// Bildet den Sortierschlüssel eines Accounts.
    static func key(for account: MonitoredAccount, now: Date = Date()) -> Key {
        let usable = account.hasUsableData

        // Restzeiten aller Fenster mit bekanntem Reset, geklemmt auf >= 0.
        let remainings: [TimeInterval] = account.windows.compactMap { window in
            switch window.resetTiming(now: now) {
            case .unknown: return nil
            case .due: return 0
            case .remaining(let seconds): return seconds
            }
        }

        return Key(
            availabilityRank: availabilityRank(for: account, usable: usable),
            fiveHourPercent: sanitized(usable ? account.fiveHourPercent : nil),
            sevenDayPercent: sanitized(usable ? account.sevenDayPercent : nil),
            earliestReset: remainings.min() ?? worstSortValue,
            identifier: account.id
        )
    }

    /// Verfügbarkeitsklasse eines Accounts (0 nutzbar, 1 blockiert, 2 ohne Daten).
    static func availabilityRank(for account: MonitoredAccount, usable: Bool) -> Int {
        guard usable else { return 2 }
        let blocked = account.windows.contains { window in
            window.percent.isFinite ? window.percent >= blockedThreshold : true
        }
        return blocked ? 1 : 0
    }

    /// Sortiert Accounts, bester zuerst. Stabil und deterministisch.
    public static func ranked(_ accounts: [MonitoredAccount], now: Date = Date()) -> [MonitoredAccount] {
        accounts
            .map { (account: $0, key: key(for: $0, now: now)) }
            .sorted { isOrderedBefore($0.key, $1.key) }
            .map { $0.account }
    }

    /// Vergleich zweier Sortierschlüssel — die Kriterienkaskade an einer Stelle.
    static func isOrderedBefore(_ lhs: Key, _ rhs: Key) -> Bool {
        if lhs.availabilityRank != rhs.availabilityRank { return lhs.availabilityRank < rhs.availabilityRank }
        if lhs.fiveHourPercent != rhs.fiveHourPercent { return lhs.fiveHourPercent < rhs.fiveHourPercent }
        if lhs.sevenDayPercent != rhs.sevenDayPercent { return lhs.sevenDayPercent < rhs.sevenDayPercent }
        if lhs.earliestReset != rhs.earliestReset { return lhs.earliestReset < rhs.earliestReset }
        return AccountIdentifierOrder.isOrderedBefore(lhs.identifier, rhs.identifier)
    }

    /// Fehlende oder nicht-endliche Prozentwerte auf den schlechtestmöglichen
    /// endlichen Wert abbilden.
    private static func sanitized(_ percent: Double?) -> Double {
        guard let percent, percent.isFinite else { return worstSortValue }
        return percent
    }
}
