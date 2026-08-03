import Foundation

/// Ein einzelnes Limitfenster eines Accounts.
///
/// Bewusst **generisch**: claude-swap liefert heute `five_hour`, `seven_day`,
/// optional `spend` und eine Liste `scoped` (die per-Modell-Wochenlimits, z. B.
/// das separate Opus-Kontingent). Alle sind gleichwertige Einträge *einer Liste* —
/// nicht zwei feste Felder. Kommt künftig ein weiterer Fenstertyp dazu, landet er
/// als ``Kind/other(rawKey:)`` in derselben Liste, statt das Modell zu brechen.
///
/// Die Felder `countdown` und `clock` aus der Quelle werden bewusst **nicht**
/// übernommen: Sie sind zum Abrufzeitpunkt eingefrorene Strings und veralten
/// sofort. Restzeiten werden immer live aus ``resetsAt`` gerechnet.
public struct LimitWindow: Sendable, Codable, Equatable, Identifiable {

    /// Art des Fensters. Trägt den Rohschlüssel der Quelle mit, damit unbekannte
    /// Fenstertypen anzeigbar bleiben, statt verworfen zu werden.
    public enum Kind: Sendable, Codable, Equatable {
        /// Rollierendes 5-Stunden-Fenster (`five_hour`).
        case fiveHour
        /// Wochenfenster (`seven_day`).
        case sevenDay
        /// Ausgabenbudget (`spend`).
        case spend
        /// Per-Modell-Kontingent aus dem `scoped`-Array, benannt (z. B. „Fable").
        case scoped(name: String)
        /// Unbekannter, künftig hinzugekommener Fenstertyp.
        case other(rawKey: String)

        /// Rohschlüssel, unter dem das Fenster in der Quelle steht.
        public var rawKey: String {
            switch self {
            case .fiveHour: return "five_hour"
            case .sevenDay: return "seven_day"
            case .spend: return "spend"
            case .scoped: return "scoped"
            case .other(let key): return key
            }
        }

        /// Sortierrang für eine stabile, vom JSON-Dictionary unabhängige Reihenfolge.
        var sortRank: Int {
            switch self {
            case .fiveHour: return 0
            case .sevenDay: return 1
            case .spend: return 2
            case .scoped: return 3
            case .other: return 4
            }
        }
    }

    /// Zusatzangaben, die nur das Ausgabenfenster mitbringt.
    public struct SpendDetail: Sendable, Codable, Equatable {
        /// Bereits verbraucht.
        public let used: Double
        /// Budgetgrenze.
        public let limit: Double
        /// Währungscode, z. B. `USD`.
        public let currency: String?

        public init(used: Double, limit: Double, currency: String?) {
            self.used = used
            self.limit = limit
            self.currency = currency
        }
    }

    /// Stabile Kennung innerhalb eines Accounts (`five_hour`, `scoped:Fable`, …).
    public let id: String
    /// Art des Fensters.
    public let kind: Kind
    /// Anzeigename ohne Lokalisierung — die UI darf ihn ersetzen.
    public let label: String
    /// Auslastung in Prozent (0…100, kann von der Quelle auch >100 kommen).
    public let percent: Double
    /// Zeitpunkt des nächsten Resets; `nil`, wenn die Quelle keinen liefert.
    public let resetsAt: Date?
    /// Nur beim Ausgabenfenster gesetzt.
    public let spend: SpendDetail?

    public init(
        id: String,
        kind: Kind,
        label: String,
        percent: Double,
        resetsAt: Date?,
        spend: SpendDetail? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.spend = spend
    }

    /// Ampelstufe dieses Fensters.
    public var status: StatusLevel { StatusLevel(percent: percent) }

    /// Live berechneter Reset-Zustand. Niemals negativ — ein Reset in der
    /// Vergangenheit ergibt ``ResetTiming/due``.
    public func resetTiming(now: Date = Date()) -> ResetTiming {
        ResetTiming(resetsAt: resetsAt, now: now)
    }
}
