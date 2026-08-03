import Foundation

/// Sortiert Accounts nach Verfügbarkeit — der beste steht vorne.
///
/// Reihenfolge der Kriterien (jeweils nur bei Gleichstand das nächste):
///
/// 1. **Verwertbare Daten zuerst.** Accounts ohne Daten oder mit totem Token
///    stehen immer am Ende und dürfen nie als „bester Account" erscheinen.
/// 2. **Niedrigste 5-Stunden-Auslastung** — das ist das Fenster, das die
///    unmittelbare Arbeitsfähigkeit begrenzt.
/// 3. **Niedrigste Wochen-Auslastung.**
/// 4. **Längste verbleibende Nutzungsdauer**, absteigend: die *längste* Restzeit
///    über alle Fenster. Bei gleicher Auslastung ist der Account besser, dessen
///    Fenster noch lange läuft — es steht mehr Zeit zur Verfügung, bis das
///    Kontingent überhaupt wieder relevant wird.
/// 5. **Frühester Reset**, aufsteigend: die *kürzeste* Restzeit über alle
///    Fenster. Wer zuerst zurückgesetzt wird, füllt sich zuerst wieder auf.
/// 6. **Kennung** — stabiler Tiebreaker, damit die Reihenfolge bei völligem
///    Gleichstand deterministisch ist.
public enum AccountRanking {

    /// Sortierschlüssel eines Accounts. Öffentlich, damit die Kriterien
    /// einzeln testbar sind, statt nur über das Sortierergebnis.
    public struct Key: Sendable, Equatable {
        /// Accounts ohne verwertbare Daten sortieren hinter allen anderen.
        public let hasUsableData: Bool
        /// Auslastung 5h; fehlendes Fenster zählt als maximal ausgelastet.
        public let fiveHourPercent: Double
        /// Auslastung 7d; fehlendes Fenster zählt als maximal ausgelastet.
        public let sevenDayPercent: Double
        /// Längste Restzeit über alle Fenster (0, wenn keine bekannt ist).
        public let longestRemaining: TimeInterval
        /// Kürzeste Restzeit über alle Fenster; ohne bekannten Reset maximal.
        public let earliestReset: TimeInterval
        /// Stabiler Tiebreaker.
        public let identifier: String
    }

    /// Wert, mit dem fehlende oder unbrauchbare Zahlen einsortiert werden:
    /// so schlecht wie möglich, aber endlich (NaN würde die Sortierordnung
    /// verletzen).
    static let worstPercent = Double.greatestFiniteMagnitude

    /// Bildet den Sortierschlüssel eines Accounts.
    public static func key(for account: MonitoredAccount, now: Date = Date()) -> Key {
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
            hasUsableData: usable,
            fiveHourPercent: sanitized(usable ? account.fiveHourPercent : nil),
            sevenDayPercent: sanitized(usable ? account.sevenDayPercent : nil),
            longestRemaining: remainings.max() ?? 0,
            earliestReset: remainings.min() ?? worstPercent,
            identifier: account.id
        )
    }

    /// Sortiert Accounts, bester zuerst. Stabil und deterministisch.
    public static func ranked(_ accounts: [MonitoredAccount], now: Date = Date()) -> [MonitoredAccount] {
        accounts
            .map { (account: $0, key: key(for: $0, now: now)) }
            .sorted { isOrderedBefore($0.key, $1.key) }
            .map { $0.account }
    }

    /// Vergleich zweier Sortierschlüssel — die Kriterienkaskade an einer Stelle.
    public static func isOrderedBefore(_ lhs: Key, _ rhs: Key) -> Bool {
        if lhs.hasUsableData != rhs.hasUsableData { return lhs.hasUsableData }
        if lhs.fiveHourPercent != rhs.fiveHourPercent { return lhs.fiveHourPercent < rhs.fiveHourPercent }
        if lhs.sevenDayPercent != rhs.sevenDayPercent { return lhs.sevenDayPercent < rhs.sevenDayPercent }
        if lhs.longestRemaining != rhs.longestRemaining { return lhs.longestRemaining > rhs.longestRemaining }
        if lhs.earliestReset != rhs.earliestReset { return lhs.earliestReset < rhs.earliestReset }
        return lhs.identifier < rhs.identifier
    }

    /// Fehlende oder nicht-endliche Prozentwerte auf den schlechtestmöglichen
    /// endlichen Wert abbilden.
    private static func sanitized(_ percent: Double?) -> Double {
        guard let percent, percent.isFinite else { return worstPercent }
        return percent
    }
}
