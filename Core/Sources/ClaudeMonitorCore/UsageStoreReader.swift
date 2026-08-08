import Foundation

/// Ergebnis eines Lesevorgangs — jeder Fehlfall ist ein *definierter* Zustand,
/// den die UI anzeigen kann. Kein Absturz, keine stille Teilinterpretation.
public enum UsageStoreReadResult: Sendable, Equatable {
    /// Store gelesen und interpretiert.
    case success(AccountsSnapshot)
    /// Keine `usage.json` an den bekannten Orten — claude-swap ist vermutlich
    /// nicht installiert oder hat noch nie gelaufen.
    case storeNotFound(searchedPaths: [String])
    /// `schemaVersion` weicht ab (Leitplanke L4): lieber „Format geändert"
    /// anzeigen als möglicherweise falsche Zahlen.
    case unsupportedSchemaVersion(found: Int?, expected: Int)
    /// Datei vorhanden, aber nicht lesbar/kein gültiges JSON.
    case unreadable(reason: String)
}

/// Liest den Cache von claude-swap — **ausschließlich lesend**.
///
/// Leitplanke L1: Es wird nie geschrieben und **kein Lock erworben**.
/// claude-swap schreibt read-modify-write unter einem File-Lock; ein
/// Fremdzugriff könnte den Store beschädigen. Ein gelegentlich halb
/// geschriebener Stand äußert sich hier als ``UsageStoreReadResult/unreadable``
/// und heilt beim nächsten Durchlauf von selbst.
public struct UsageStoreReader: Sendable {

    /// Ab dieser Anzahl Fehlversuche gilt der hinterlegte Token als tot.
    ///
    /// Quelle: claude-swap 0.22.0, `usage_store.py:86` → `AUTH_DEAD_STRIKES = 1`.
    /// `_row_eligible` (`usage_store.py:505`) stellt das Abrufen bereits ab dem
    /// **ersten** Strike vollständig ein und quarantänisiert den Account als
    /// „re-login needed". Eine höhere Schwelle hier würde solche Accounts mit
    /// eingefrorenen (oft niedrigen) Prozentwerten dauerhaft als „bester
    /// Account" anzeigen.
    public static let defaultAuthDeadStrikeThreshold = 1

    /// Schwelle für ``AccountState/authDead(strikes:)``.
    public let authDeadStrikeThreshold: Int

    public init(authDeadStrikeThreshold: Int = UsageStoreReader.defaultAuthDeadStrikeThreshold) {
        self.authDeadStrikeThreshold = authDeadStrikeThreshold
    }

    // MARK: - Lesen

    /// Sucht den Store an den bekannten Orten und liest ihn.
    public func read(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> UsageStoreReadResult {
        guard let url = UsageStoreLocator.locate(
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else {
            let searched = UsageStoreLocator
                .candidateURLs(environment: environment, homeDirectory: homeDirectory)
                .map(\.path)
            return .storeNotFound(searchedPaths: searched)
        }
        return read(contentsOf: url, fileManager: fileManager, now: now)
    }

    /// Liest einen konkreten Store-Pfad.
    ///
    /// - Parameter sequence: Aktiver Account und Aliase. `nil` ⇒ im selben
    ///   Durchlauf aus der Geschwisterdatei `sequence.json` gelesen. Diese
    ///   Quelle kann nicht scheitern (``AccountSequenceReader``); ein Problem
    ///   dort ergibt niemals ein anderes ``UsageStoreReadResult``.
    public func read(
        contentsOf url: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        sequence: AccountSequenceInfo? = nil
    ) -> UsageStoreReadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return .storeNotFound(searchedPaths: [url.path])
        }
        let sequence = sequence
            ?? AccountSequenceReader.read(forStoreAt: url, fileManager: fileManager)
        do {
            // Reines Lesen ohne Koordination und ohne Lock (L1).
            let data = try Data(contentsOf: url, options: [.uncached])
            return decode(data, now: now, sequence: sequence)
        } catch {
            // TOCTOU: Zwischen Existenzprüfung und Lesen kann claude-swap die
            // Datei ersetzt haben. „Verschwunden" ist kein Lesefehler, sondern
            // derselbe Zustand wie „nie da gewesen".
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                return .storeNotFound(searchedPaths: [url.path])
            }
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Interpretiert den Store-Inhalt. Getrennt vom Dateizugriff, damit
    /// Fixtures ohne Dateisystem geprüft werden können.
    public func decode(
        _ data: Data,
        now: Date = Date(),
        sequence: AccountSequenceInfo = .empty
    ) -> UsageStoreReadResult {
        let raw: RawUsageStore
        do {
            raw = try JSONDecoder().decode(RawUsageStore.self, from: data)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }

        // L4: harte Prüfung vor jeder Interpretation der Inhalte.
        guard raw.schemaVersion == ClaudeMonitorCore.supportedSchemaVersion else {
            return .unsupportedSchemaVersion(
                found: raw.schemaVersion,
                expected: ClaudeMonitorCore.supportedSchemaVersion
            )
        }

        let accounts = (raw.accounts ?? [:])
            .map { account(id: $0.key, raw: $0.value, now: now, sequence: sequence) }
            .sorted { AccountIdentifierOrder.isOrderedBefore($0.id, $1.id) }

        return .success(
            AccountsSnapshot(
                accounts: accounts,
                capturedAt: now,
                sourceSchemaVersion: ClaudeMonitorCore.supportedSchemaVersion
            )
        )
    }

    // MARK: - Abbildung auf das Datenmodell

    private func account(
        id: String,
        raw: RawAccount,
        now: Date,
        sequence: AccountSequenceInfo
    ) -> MonitoredAccount {
        let windows = Self.windows(from: raw.lastGood)
        let fetchedAt = raw.fetchedAt.map { Date(timeIntervalSince1970: $0) }
        let nextPollAt = raw.nextPollAt.map { Date(timeIntervalSince1970: $0) }
        let backoffUntil = raw.backoffUntil.map { Date(timeIntervalSince1970: $0) }

        // Reihenfolge der Zustände: Ein toter Token ist die gravierendste
        // Aussage, danach „noch keine Daten", dann laufender Backoff, dann ein
        // letzter Fehlversuch bei sonst brauchbaren Daten.
        let state: AccountState
        let strikes = raw.authDeadStrikes ?? 0
        if strikes >= authDeadStrikeThreshold {
            state = .authDead(strikes: strikes)
        } else if raw.lastGood == nil || windows.isEmpty {
            state = .noData
        } else if let backoffUntil, backoffUntil > now {
            state = .backoff(until: backoffUntil)
        } else if let message = raw.lastError, !message.isEmpty {
            state = .failing(message: message)
        } else {
            state = .ok
        }

        return MonitoredAccount(
            id: id,
            displayName: Self.displayName(id: id, email: raw.email, alias: sequence.alias(for: id)),
            windows: windows,
            fetchedAt: fetchedAt,
            nextPollAt: nextPollAt,
            state: state,
            isActive: sequence.isActive(id)
        )
    }

    /// Vorrang des Anzeigenamens: **Alias** vor **E-Mail** vor „Account <id>".
    ///
    /// Leere Zeichenketten zählen auf beiden Stufen als nicht vorhanden — ein
    /// Account mit `"email": ""` und ohne Alias soll „Account 3" heißen und
    /// nicht namenlos in der Liste stehen. Der Alias wird bereits beim Lesen
    /// von `sequence.json` beschnitten (``AccountSequenceReader``).
    static func displayName(id: String, email: String?, alias: String?) -> String {
        if let alias, !alias.isEmpty { return alias }
        if let email, !email.isEmpty { return email }
        return "Account \(id)"
    }

    /// Baut die Fensterliste aus `lastGood`.
    ///
    /// Unbekannte Schlüssel werden **nicht** verworfen, sondern als
    /// ``LimitWindow/Kind/other(rawKey:)`` übernommen — das Modell soll nicht
    /// brechen, wenn claude-swap künftig weitere Fenstertypen liefert.
    /// Die Reihenfolge ist stabil (5h, 7d, spend, scoped, unbekannt), weil ein
    /// JSON-Objekt keine verlässliche Ordnung hat.
    static func windows(from lastGood: [String: RawLastGoodEntry]?) -> [LimitWindow] {
        guard let lastGood else { return [] }

        var result: [(rank: Int, key: String, window: LimitWindow)] = []

        for (key, entry) in lastGood {
            switch key {
            case "scoped":
                for (index, raw) in entry.windows.enumerated() {
                    let name = raw.name ?? "scoped \(index + 1)"
                    // Der Index gehört in die Kennung: claude-swap kann zwei
                    // scoped-Fenster mit gleichem Namen liefern, und doppelte
                    // `id`-Werte machen SwiftUI-`ForEach` undefiniert.
                    if let window = window(
                        from: raw,
                        id: "scoped:\(index):\(name)",
                        kind: .scoped(name: name),
                        label: name
                    ) {
                        result.append((LimitWindow.Kind.scoped(name: name).sortRank, "\(key)#\(index)", window))
                    }
                }
            default:
                let kind: LimitWindow.Kind
                let label: String
                switch key {
                case "five_hour": kind = .fiveHour; label = "5h"
                case "seven_day": kind = .sevenDay; label = "7d"
                case "spend": kind = .spend; label = "Spend"
                default: kind = .other(rawKey: key); label = key
                }
                guard let raw = entry.windows.first else { continue }
                if let window = window(from: raw, id: key, kind: kind, label: label) {
                    result.append((kind.sortRank, key, window))
                }
            }
        }

        return result
            .sorted { ($0.rank, $0.key) < ($1.rank, $1.key) }
            .map(\.window)
    }

    /// Wandelt ein Rohfenster um; `nil`, wenn kein verwertbarer Prozentwert
    /// ableitbar ist (dann liegen für dieses Fenster schlicht keine Daten vor —
    /// das ist etwas anderes als 0 %).
    private static func window(
        from raw: RawWindow,
        id: String,
        kind: LimitWindow.Kind,
        label: String
    ) -> LimitWindow? {
        guard let percent = percent(from: raw) else { return nil }
        var spend: LimitWindow.SpendDetail?
        if case .spend = kind, let used = raw.used, let limit = raw.limit {
            spend = LimitWindow.SpendDetail(used: used, limit: limit, currency: raw.currency)
        }
        return LimitWindow(
            id: id,
            kind: kind,
            label: label,
            percent: percent,
            resetsAt: ISO8601Parsing.date(from: raw.resetsAt),
            spend: spend
        )
    }

    /// Der Prozentwert kommt ausschließlich aus `pct`.
    ///
    /// Ein negativer oder nicht-endlicher Wert ist ein korrupter Wert und wird
    /// wie ein fehlendes Fenster behandelt (`nil`) — auf 0 zu klemmen würde ihn
    /// zum *besten* aller Werte machen und den Account fälschlich empfehlen.
    ///
    /// Ein Rückfall auf `used`/`limit` gibt es bewusst nicht: claude-swap
    /// schreibt den `spend`-Block nur mit non-null `utilization`
    /// (`oauth.py:419-421`), der Zweig wäre toter Code.
    private static func percent(from raw: RawWindow) -> Double? {
        guard let pct = raw.pct, pct.isFinite, pct >= 0 else { return nil }
        return pct
    }
}
