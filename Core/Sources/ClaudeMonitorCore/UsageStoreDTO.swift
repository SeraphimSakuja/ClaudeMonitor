import Foundation

// MARK: - Rohformat von claude-swap
//
// ⚠️ Die Schlüssel sind gemischt: außen camelCase (`schemaVersion`, `lastGood`,
// `fetchedAt`), innen snake_case (`five_hour`, `resets_at`). Das ist im echten
// Store tatsächlich so — deshalb keine globale Key-Strategie, sondern
// explizite CodingKeys.
//
// Alle Decoder hier sind **nicht werfend**: Ein Feld mit unerwartetem Typ wird
// zu `nil`, ein Objekt an falscher Stelle zu einem leeren Eintrag (Leitplanke L3).
// Nur kaputtes JSON als Ganzes bricht ab — das ist ein eigener Ergebniszustand.

extension KeyedDecodingContainer {
    /// Decodiert tolerant: fehlt der Schlüssel, ist er `null` oder hat er den
    /// falschen Typ, kommt `nil` zurück statt eines Fehlers.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// Ein Limitfenster im Rohformat.
struct RawWindow: Decodable {
    var name: String?
    var pct: Double?
    var used: Double?
    var limit: Double?
    var currency: String?
    var resetsAt: String?
    // `countdown` und `clock` werden bewusst nicht gelesen: eingefrorene
    // Strings vom Abrufzeitpunkt, die sofort veralten.

    enum CodingKeys: String, CodingKey {
        case name
        case pct
        case used
        case limit
        case currency
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            // Kein Objekt (z. B. Zahl oder String an dieser Stelle) → leerer Eintrag,
            // der später mangels Prozentwert verworfen wird.
            return
        }
        name = container.lenient(String.self, .name)
        pct = container.lenient(Double.self, .pct)
        used = container.lenient(Double.self, .used)
        limit = container.lenient(Double.self, .limit)
        currency = container.lenient(String.self, .currency)
        resetsAt = container.lenient(String.self, .resetsAt)
    }
}

/// Ein Eintrag unter `lastGood`: entweder ein einzelnes Fenster oder — wie bei
/// `scoped` — eine Liste von Fenstern.
enum RawLastGoodEntry: Decodable {
    case single(RawWindow)
    case list([RawWindow])
    case unsupported

    init(from decoder: Decoder) throws {
        // Reihenfolge wichtig: RawWindow decodiert auch aus fast allem, ein
        // Array muss deshalb zuerst geprüft werden.
        if let list = try? [RawWindow](from: decoder) {
            self = .list(list)
        } else if let single = try? RawWindow(from: decoder) {
            self = .single(single)
        } else {
            self = .unsupported
        }
    }

    /// Fenster in Quellreihenfolge.
    var windows: [RawWindow] {
        switch self {
        case .single(let window): return [window]
        case .list(let windows): return windows
        case .unsupported: return []
        }
    }
}

/// Ein Account im Rohformat.
struct RawAccount: Decodable {
    var email: String?
    var lastGood: [String: RawLastGoodEntry]?
    var fetchedAt: Double?
    var lastAttemptAt: Double?
    var backoffUntil: Double?
    var consecutiveFailures: Int?
    var authDeadStrikes: Int?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case email
        case lastGood
        case fetchedAt
        case lastAttemptAt
        case backoffUntil
        case consecutiveFailures
        case authDeadStrikes
        case lastError
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        email = container.lenient(String.self, .email)
        lastGood = container.lenient([String: RawLastGoodEntry].self, .lastGood)
        fetchedAt = container.lenient(Double.self, .fetchedAt)
        lastAttemptAt = container.lenient(Double.self, .lastAttemptAt)
        backoffUntil = container.lenient(Double.self, .backoffUntil)
        consecutiveFailures = container.lenient(Int.self, .consecutiveFailures)
        authDeadStrikes = container.lenient(Int.self, .authDeadStrikes)
        lastError = container.lenient(String.self, .lastError)
    }
}

/// Die Store-Datei im Rohformat.
struct RawUsageStore: Decodable {
    var schemaVersion: Int?
    var accounts: [String: RawAccount]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.lenient(Int.self, .schemaVersion)
        accounts = container.lenient([String: RawAccount].self, .accounts)
    }
}
