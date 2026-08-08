import Foundation

/// Was claude-swaps `sequence.json` über die Accounts sagt: welcher gerade
/// **aktiv** ist und wie sie **kurz** heißen.
///
/// Beides ist Beiwerk, kein Fundament: Fehlt die Datei oder ist sie anders
/// gebaut als erwartet, bleibt hier schlicht alles leer — die Prozentwerte aus
/// `usage.json` laufen unverändert weiter.
public struct AccountSequenceInfo: Sendable, Equatable {

    /// Kennung des aktiven Accounts (`String(activeAccountNumber)`); `nil`,
    /// wenn die Quelle dazu nichts Verwertbares sagt.
    ///
    /// Bewusst **nicht** gegen die Accounts aus `usage.json` geprüft: Zeigt die
    /// Zahl auf eine Kennung, die es dort nicht gibt, ist am Ende einfach kein
    /// Account markiert — es wird nichts geraten.
    public let activeAccountID: String?

    /// Kurznamen je Account-Kennung. Enthält nur nicht-leere Aliase; ein
    /// Account ohne Alias fehlt hier ganz.
    public let aliases: [String: String]

    /// Nichts bekannt — der Zustand bei fehlender oder unbrauchbarer Datei.
    public static let empty = AccountSequenceInfo(activeAccountID: nil, aliases: [:])

    public init(activeAccountID: String?, aliases: [String: String]) {
        self.activeAccountID = activeAccountID
        self.aliases = aliases
    }

    /// Kurzname dieses Accounts, falls einer hinterlegt ist.
    public func alias(for id: String) -> String? { aliases[id] }

    /// Ob dieser Account der aktive ist.
    public func isActive(_ id: String) -> Bool { activeAccountID == id }
}

/// Liest `sequence.json` von claude-swap — **ausschließlich lesend** (L1) und
/// ohne jede Möglichkeit zu scheitern.
///
/// `sequence.json` ist die Geschwisterdatei von `cache/usage.json` und liegt
/// eine Ebene **über** dem Cache-Verzeichnis. Der Pfad wird deshalb immer aus
/// der gefundenen `usage.json` abgeleitet (``UsageStoreLocator/sequenceURL(forStoreAt:)``)
/// und nie eigenständig gesucht — zwei Pfadmechanismen liefen auseinander.
///
/// **Diese Datei trägt keine `schemaVersion`** (anders als `usage.json` mit 2
/// und `settings.json` mit 1). Leitplanke L4 („Schema hart prüfen") ist hier
/// deshalb nicht anwendbar — eine bewusste, dokumentierte Abweichung. Getragen
/// wird sie davon, dass ein Missverständnis hier nie zu falschen **Zahlen**
/// führen kann: Es steht höchstens ein Pfeil an der falschen Stelle oder ein
/// Kurzname fehlt.
///
/// Jeder Fehlfall — Datei fehlt, unlesbar, kein JSON, unerwarteter Aufbau, halb
/// geschriebener Stand — ergibt ``AccountSequenceInfo/empty``. Es gibt bewusst
/// **kein** Fehlerergebnis: Ein `MonitorIssue` aus dieser Quelle würde einen
/// Fehlzustand über korrekte Zahlen legen.
public enum AccountSequenceReader {

    /// Liest die Datei, die zur angegebenen `usage.json` gehört.
    public static func read(
        forStoreAt storeURL: URL,
        fileManager: FileManager = .default
    ) -> AccountSequenceInfo {
        // Lässt sich der Pfad nicht sicher ableiten (die `usage.json` liegt
        // nicht in einem `cache`-Verzeichnis), wird nichts geraten: leer.
        guard let url = UsageStoreLocator.sequenceURL(forStoreAt: storeURL) else { return .empty }
        return read(contentsOf: url, fileManager: fileManager)
    }

    /// Liest einen konkreten Pfad.
    public static func read(
        contentsOf url: URL,
        fileManager: FileManager = .default
    ) -> AccountSequenceInfo {
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        // Reines Lesen ohne Koordination und ohne Lock (L1) — genau wie bei
        // `usage.json`. Ein halb geschriebener Stand ist ein normaler Fall und
        // heilt beim nächsten Durchlauf von selbst.
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return .empty }
        return decode(data)
    }

    /// Interpretiert den Dateiinhalt. Getrennt vom Dateizugriff, damit der
    /// Aufbau ohne Dateisystem prüfbar ist.
    ///
    /// Bewusst über `JSONSerialization` statt über `Codable`: Ein `Codable`-Typ
    /// wirft schon, wenn ein einzelnes Feld einen unerwarteten Typ hat, und
    /// verwürfe damit auch die Teile, die in Ordnung sind. Hier soll jedes Feld
    /// einzeln misslingen dürfen.
    public static func decode(_ data: Data) -> AccountSequenceInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .empty }

        let activeID = identifier(from: root["activeAccountNumber"])

        var aliases: [String: String] = [:]
        if let accounts = root["accounts"] as? [String: Any] {
            for (id, raw) in accounts {
                guard let entry = raw as? [String: Any],
                      let alias = entry["alias"] as? String else { continue }
                // Ein leerer oder nur aus Leerzeichen bestehender Alias ist
                // kein Name — er fiele in der Anzeige als Leerstelle auf,
                // statt auf die E-Mail zurückzufallen.
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { aliases[id] = trimmed }
            }
        }

        return AccountSequenceInfo(activeAccountID: activeID, aliases: aliases)
    }

    /// `activeAccountNumber` ist eine **Zahl**, die Schlüssel unter `accounts`
    /// sind **Strings** — die Kennung ist deren Dezimaldarstellung.
    ///
    /// Alles andere (fehlend, Text, Wahrheitswert, Bruchzahl, nicht-endlich,
    /// außerhalb von `Int`) gilt als „nicht gesagt"; dann ist kein Account
    /// markiert.
    private static func identifier(from raw: Any?) -> String? {
        guard let number = raw as? NSNumber else { return nil }
        // `true` käme als NSNumber 1 durch und markierte Account „1".
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // `Int(exactly:)` statt `number.intValue`: Letzteres liefert bei
        // `1e30` einen implementierungsdefinierten Wert — also eine
        // Fantasie-Kennung, die zufällig auf einen echten Account zeigen
        // könnte. Der Test deckt zugleich „nicht endlich" und „Bruchzahl" mit
        // ab, denn beides ergibt hier ebenfalls `nil`.
        guard let value = Int(exactly: number.doubleValue) else { return nil }
        return String(value)
    }
}
