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
///
///    Seit Kriterium 2 über **alle** Fenster misst, ist dieser Rang für die
///    Prozentwerte weitgehend redundant — ein irgendwo ausgeschöpfter Account
///    hat automatisch die schlechteste bindende Auslastung. Er bleibt trotzdem,
///    weil er den Datenlos-/Toter-Token-Fall abdeckt, den Kriterium 2 **nicht**
///    sieht, und weil er die Schwelle „ab 100 % blockiert" ausdrücklich macht.
/// 2. **Niedrigste bindende Auslastung** = ``MonitoredAccount/bindingPercent``,
///    also das Maximum über **alle** Limitfenster (5h, 7d, `spend`, `scoped`),
///    aufsteigend. Bewusst **kein Durchschnitt**: Maßgeblich ist das Fenster,
///    das den Account tatsächlich begrenzt. 5h 49 % / 7d 100 % ergäbe gemittelt
///    74,5 und stünde vor 5h 100 % / 7d 89 % (94,5) — obwohl der erste Account
///    tagelang unbrauchbar ist. Mit `max` sind beide bei 100 und der frühere
///    Reset entscheidet.
///
///    Bewusst **alle** Fenster statt nur 5h/7d: Ein leergelaufenes
///    Modellkontingent (`scoped`) oder Ausgabenbudget (`spend`) macht den
///    Account real unbrauchbar. Und es ist **dieselbe** Größe, aus der die
///    Anzeige ihre zusammengefasste Zahl und ihre Ampelfarbe zieht
///    (``MonitoredAccount/overallStatus``, gelesen über
///    `AccountBindingDisplay` in der Account-Karte und über
///    `MenuBarDisplay.AccountSegment.status` für den Punkt in der Menüleiste).
///    Nur dadurch gilt die Zusage: Der oberste
///    Account trägt nie ein rotes Signal, während ein grüner darunter steht.
///    Maß und Anzeige messen dasselbe, weil sie dieselbe Property lesen.
///
///    Für die **Reihenfolge in der Menüleiste** ist dieses Ranking bewusst
///    *nicht* zuständig: Dort reiht `MenuBarDisplay` im Modus „alle Accounts"
///    nach ``AccountIdentifierOrder``, damit die Position eines Accounts nicht
///    springt, sobald sich ein Prozentwert ändert. Das Ranking bestimmt das
///    Detailfenster und die Auswahl im Modus „nur bester Account".
/// 3. **Frühester Reset des Engpass-Fensters**, aufsteigend. `resets_at` ist der
///    Zeitpunkt des Auffüllens — wer zuerst zurückgesetzt wird, ist zuerst wieder
///    verfügbar. Gemessen wird die Restzeit **des Fensters, das den Account
///    ausbremst** (des am höchsten ausgelasteten), nicht die kürzeste über alle
///    Fenster: Der Realfall 5h 49 % / 7d 100 % hat einen 5h-Reset in zwei
///    Stunden, der dem Nutzer nichts nützt, solange das Wochenlimit noch 70
///    Stunden dicht ist. Ein Account ohne bekannten Reset am Engpass sortiert
///    hier ans Ende.
/// 4. **Kennung** — stabiler, locale-freier Tiebreaker (``AccountIdentifierOrder``),
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
        /// Bindende Auslastung: das Maximum über alle Limitfenster. Fehlen
        /// Fenster ganz, zählt der Account als maximal ausgelastet und die
        /// Bewertung wird schlechtestmöglich.
        let bindingPercent: Double
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

        return Key(
            availabilityRank: availabilityRank(for: account, usable: usable),
            bindingPercent: bindingPercent(for: account, usable: usable),
            earliestReset: bottleneckReset(for: account, now: now),
            identifier: account.id
        )
    }

    /// Bindende Auslastung eines Accounts: das am höchsten ausgelastete
    /// Fenster — **genau** die Größe, die die Anzeige als Account-Zahl
    /// zusammenfasst (`AccountBindingDisplay`).
    ///
    /// Nicht nachgebaut, sondern ``MonitoredAccount/bindingPercent`` gelesen:
    /// Eine zweite Implementierung derselben Regel wäre genau der Weg, auf dem
    /// Ranking und Anzeige wieder auseinanderlaufen.
    static func bindingPercent(for account: MonitoredAccount, usable: Bool) -> Double {
        guard usable else { return worstSortValue }
        return sanitized(account.bindingPercent)
    }

    /// Restzeit bis zum Reset des Engpass-Fensters, also des am höchsten
    /// ausgelasteten. Sind mehrere Fenster gleich hoch ausgelastet, zählt das
    /// mit dem frühesten Reset. ``worstSortValue``, wenn dort kein Reset
    /// bekannt ist — dann ist über die Rückkehr des Kontingents nichts gesagt.
    static func bottleneckReset(for account: MonitoredAccount, now: Date) -> TimeInterval {
        let finitePercents = account.windows.map(\.percent).filter { $0.isFinite }
        guard let peak = finitePercents.max() else { return worstSortValue }
        let remainings = account.windows
            .filter { $0.percent.isFinite && $0.percent >= peak }
            .compactMap { $0.resetTiming(now: now).remainingSeconds }
        return remainings.min() ?? worstSortValue
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
        if lhs.bindingPercent != rhs.bindingPercent { return lhs.bindingPercent < rhs.bindingPercent }
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
