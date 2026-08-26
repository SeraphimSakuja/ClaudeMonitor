import Foundation

/// Wer unter einer Slot-Kennung in `sequence.json` steht.
///
/// `organizationUuid` ist **optional**, weil ältere claude-swap-Stände das Feld
/// noch nicht je Eintrag führen (`_migrate_org_fields` füllt es lazy nach, und
/// zwar nur bei einem cswap-Kommando — nie durch ClaudeMonitor). `nil` heißt
/// deshalb „dazu sagt die Quelle nichts" und schaltet den Vergleich auf die
/// E-Mail zurück. Ausdrücklich davon unterschieden ist `""`: Das ist eine echte
/// Aussage (persönlicher Account) und wird streng verglichen.
public struct AccountIdentity: Sendable, Equatable {
    public let email: String
    public let organizationUuid: String?

    public init(email: String, organizationUuid: String?) {
        self.email = email
        self.organizationUuid = organizationUuid
    }
}

/// Was claude-swaps `sequence.json` über die Accounts sagt: **welche es
/// überhaupt gibt**, welcher gerade **aktiv** ist und wie sie **kurz** heißen.
///
/// Die Mengenaussage ist die tragende: `sequence.json` ist die Verwaltung,
/// `cache/usage.json` nur der Zahlen-Zwischenspeicher. Eine Zeile, die dort
/// stehen bleibt, nachdem claude-swap den Account entfernt hat, ist ein Geist
/// mit eingefrorenen Werten — und rangiert mit ihnen als „bester Account".
///
/// Markierung und Kurzname bleiben dagegen Beiwerk: Fehlt die Datei oder ist
/// sie anders gebaut als erwartet, bleibt hier schlicht alles leer — die
/// Prozentwerte aus `usage.json` laufen unverändert weiter, und gefiltert wird
/// dann **nicht** (siehe ``knownAccounts``).
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

    /// Welche Accounts claude-swap kennt, je Kennung deren Identität.
    ///
    /// ⚠️ `nil` und `[:]` sind **nicht** dasselbe:
    /// - `nil` heißt „die Quelle hat nichts gesagt" (Datei fehlt, ist kaputt,
    ///   oder auch nur **ein** Eintrag war unlesbar) ⇒ es wird **nicht**
    ///   gefiltert. Ein Problem mit `sequence.json` darf nie Zahlen verstecken.
    /// - `[:]` heißt „claude-swap verwaltet gerade keinen Account" — genau das
    ///   schreibt `_init_sequence_file` beim Erstlauf und `remove_account`
    ///   nach dem letzten Account ⇒ es bleibt **nichts** übrig.
    public let knownAccounts: [String: AccountIdentity]?

    /// Nichts bekannt — der Zustand bei fehlender oder unbrauchbarer Datei.
    ///
    /// ⚠️ `knownAccounts` ist hier bewusst `nil` und **nicht** `[:]`: Mit einer
    /// leeren Menge würde jeder Fehlfall dieser Nebenquelle sämtliche Accounts
    /// ausblenden — aus einem fehlenden Kurznamen würde eine leere App.
    public static let empty = AccountSequenceInfo(activeAccountID: nil, aliases: [:])

    /// - Parameter knownAccounts: Standard `nil` (fail-open: nicht filtern).
    ///   Einziger Konstrukteur in Produktion ist ``AccountSequenceReader/decode(_:)``.
    public init(
        activeAccountID: String?,
        aliases: [String: String],
        knownAccounts: [String: AccountIdentity]? = nil
    ) {
        self.activeAccountID = activeAccountID
        self.aliases = aliases
        self.knownAccounts = knownAccounts
    }

    /// Kurzname dieses Accounts, falls einer hinterlegt ist.
    public func alias(for id: String) -> String? { aliases[id] }

    /// Ob dieser Account der aktive ist.
    public func isActive(_ id: String) -> Bool { activeAccountID == id }

    /// Ob claude-swap diesen Account (noch) kennt — die Regel, nach der eine
    /// Zeile aus `cache/usage.json` überhaupt angezeigt wird.
    ///
    /// Verglichen wird die **Identität**, nicht die Kennung: Nach dem Entfernen
    /// aller Accounts vergibt claude-swap die Slot-Nummern wieder von vorn
    /// (`_get_next_account_number`). Unter Slot 1 stünde dann ein neuer Account,
    /// in `usage.json` noch die Zahlen des alten — die Kennung allein wäre also
    /// eine Zusage, die claude-swap gar nicht macht.
    ///
    /// - Parameters:
    ///   - id: Kennung der Zeile aus `usage.json`.
    ///   - email: `email` dieser Zeile; `nil` (Feld fehlt) ist eine andere
    ///     E-Mail als jede vorhandene und passt deshalb auf nichts.
    ///   - organizationUuid: `organizationUuid` dieser Zeile. Fehlt das Feld,
    ///     gilt `""` — dieselbe Normalisierung, die claude-swap selbst benutzt
    ///     (`UsageStore._matches`), damit eine alte `usage.json` ohne dieses
    ///     Feld nicht schlagartig als „fremder Account" gilt.
    /// - Returns: `true`, solange ``knownAccounts`` `nil` ist — dann hat die
    ///   Quelle nichts gesagt und es wird nicht gefiltert.
    public func recognizes(id: String, email: String?, organizationUuid: String?) -> Bool {
        guard let knownAccounts else { return true }
        guard let identity = knownAccounts[id] else { return false }
        guard identity.email == email else { return false }
        // Kein `organizationUuid` im sequence.json-Eintrag ⇒ nur die E-Mail
        // vergleichen. claude-swap füllt das Feld erst bei Gelegenheit nach
        // (`_migrate_org_fields`, ausgelöst nur von cswap-Kommandos); ein
        // strenger Vergleich blendete einem Nutzer mit altem Stand einen
        // **existierenden** Account dauerhaft aus.
        guard let knownOrganization = identity.organizationUuid else { return true }
        return knownOrganization == (organizationUuid ?? "")
    }
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

    /// Obergrenze für die Anzahl der Accounts, aus denen Aliase übernommen
    /// werden. claude-swap verwaltet eine Handvoll; die Grenze schützt allein
    /// davor, dass eine aufgeblähte Fremddatei unbegrenzt Einträge erzeugt.
    static let maximumAccounts = 64

    /// Obergrenze für die Länge eines Alias. Er wird in der Menüleiste und im
    /// Detailfenster gezeigt — ein Alias mit 100 000 Zeichen ist kein Name,
    /// sondern eine Zeichenlast.
    static let maximumAliasLength = 64

    /// Obergrenze für die Identitätsmenge selbst (unabhängig vom
    /// Alias-Deckel ``maximumAccounts``). claude-swap verwaltet eine
    /// Handvoll Accounts; deutlich über jeder realistischen Zahl, aber
    /// deutlich unter dem, was die 8-MB-Dateigrenze (``SourceFileGuard``)
    /// überhaupt an Einträgen tragen könnte. Oberhalb gilt die ganze Menge
    /// als „nichts gesagt" (`nil`, nicht filtern) — **kein** Truncate: Eine
    /// Teilmenge würde echte Accounts jenseits der Schwelle verstecken,
    /// genau der Fehler, den die Mengenregel sonst vermeidet.
    static let maximumKnownAccounts = 4096

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
        // TOCTOU-sicher (CM-16), dieselbe Wache wie bei `usage.json`: prüft
        // denselben Datei-Deskriptor, den es liest — ein getrennter `inspect()`
        // gefolgt von `Data(contentsOf:)` ließe ein Rennfenster offen, in dem
        // eine untergeschobene FIFO das Öffnen endlos blockiert und damit auch
        // die Anzeige der Zahlen still stünde (siehe ``SourceFileGuard``).
        // Ein halb geschriebener Stand ist ein normaler Fall und heilt beim
        // nächsten Durchlauf von selbst — jeder Fehlschlag wird darum
        // gleichermaßen zu `.empty`, ohne Unterscheidung nach Grund.
        guard case .success(let data) = SourceFileGuard.readIfSafe(url) else { return .empty }
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

        // Einmal casten, beide Ableitungen (Identitäten + Aliase) daraus
        // speisen — spart den zweiten separaten Cast/Traversal derselben Menge.
        let accountsObject = root["accounts"] as? [String: Any]
        let known = identities(from: accountsObject)

        var aliases: [String: String] = [:]
        if let accounts = accountsObject {
            // Kennungsordnung statt Wörterbuch-Reihenfolge: Greift die
            // Obergrenze, soll immer dieselbe Teilmenge übrig bleiben und nicht
            // bei jedem Lauf eine andere.
            let ordered = accounts.sorted { AccountIdentifierOrder.isOrderedBefore($0.key, $1.key) }
            for (id, raw) in ordered.prefix(maximumAccounts) {
                guard let entry = raw as? [String: Any],
                      let alias = entry["alias"] as? String else { continue }
                // Ein leerer oder nur aus Leerzeichen bestehender Alias ist
                // kein Name — er fiele in der Anzeige als Leerstelle auf,
                // statt auf die E-Mail zurückzufallen.
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { aliases[id] = String(trimmed.prefix(maximumAliasLength)) }
            }
        }

        return AccountSequenceInfo(activeAccountID: activeID, aliases: aliases, knownAccounts: known)
    }

    /// Die Identitätsmenge aus dem `accounts`-Objekt — oder `nil`, wenn sie
    /// nicht **vollständig** lesbar war.
    ///
    /// Vollständig heißt wörtlich: Ein einziger Eintrag, der kein Wörterbuch ist
    /// oder keine `email` trägt, verwirft die ganze Menge. Eine Teilmenge wäre
    /// hier die gefährlichste aller Antworten — jeder nicht gelesene Eintrag
    /// läse sich anschließend als „diesen Account gibt es nicht mehr".
    ///
    /// Die Menge wird **nicht** gedeckelt: Sie wird nur nachgeschlagen, nicht
    /// gezeichnet (anders als die Aliase, siehe ``maximumAccounts``). Ein Deckel
    /// höbe den Schutz oberhalb der Schwelle wieder auf; gegen aufgeblähte
    /// Fremddateien steht bereits ``SourceFileGuard``.
    private static func identities(from raw: Any?) -> [String: AccountIdentity]? {
        guard let accounts = raw as? [String: Any] else { return nil }
        // Oberhalb dieser Grenze ist die Datei keine Verwaltung mehr, sondern
        // Ballast — „nichts gesagt" (nicht filtern) statt einer Teilmenge, die
        // echte Accounts verstecken würde (siehe ``maximumKnownAccounts``).
        guard accounts.count <= maximumKnownAccounts else { return nil }

        var identities: [String: AccountIdentity] = [:]
        for (id, entry) in accounts {
            guard let entry = entry as? [String: Any],
                  let email = entry["email"] as? String else { return nil }
            identities[id] = AccountIdentity(
                email: email,
                // Fehlender Schlüssel ⇒ `nil` („nichts gesagt", nur E-Mail
                // vergleichen), `""` ⇒ echte Aussage (persönlicher Account) und
                // damit streng verglichen. Ein falsch getippter Wert (Zahl,
                // Objekt) zählt wie „nichts gesagt", nicht wie `""`.
                organizationUuid: entry["organizationUuid"] as? String
            )
        }
        // `"accounts": {}` bleibt hier eine leere **Menge**, kein `nil`:
        // claude-swap schreibt genau das beim Erstlauf und nach dem Entfernen
        // des letzten Accounts — dann gibt es wirklich keinen Account mehr.
        return identities
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
