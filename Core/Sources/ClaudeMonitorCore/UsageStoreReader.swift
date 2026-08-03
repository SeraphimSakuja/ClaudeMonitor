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
    public static let defaultAuthDeadStrikeThreshold = 3

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
        return read(contentsOf: url, now: now)
    }

    /// Liest einen konkreten Store-Pfad.
    public func read(contentsOf url: URL, now: Date = Date()) -> UsageStoreReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .storeNotFound(searchedPaths: [url.path])
        }
        do {
            // Reines Lesen ohne Koordination und ohne Lock (L1).
            let data = try Data(contentsOf: url, options: [.uncached])
            return decode(data, now: now)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// Interpretiert den Store-Inhalt. Getrennt vom Dateizugriff, damit
    /// Fixtures ohne Dateisystem geprüft werden können.
    public func decode(_ data: Data, now: Date = Date()) -> UsageStoreReadResult {
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
            .map { account(id: $0.key, raw: $0.value, now: now) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        return .success(
            AccountsSnapshot(
                accounts: accounts,
                capturedAt: now,
                sourceSchemaVersion: ClaudeMonitorCore.supportedSchemaVersion
            )
        )
    }

    // MARK: - Abbildung auf das Datenmodell

    private func account(id: String, raw: RawAccount, now: Date) -> MonitoredAccount {
        let windows = Self.windows(from: raw.lastGood)
        let fetchedAt = raw.fetchedAt.map { Date(timeIntervalSince1970: $0) }
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
            displayName: raw.email.flatMap { $0.isEmpty ? nil : $0 } ?? "Account \(id)",
            windows: windows,
            fetchedAt: fetchedAt,
            state: state
        )
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
                    if let window = window(
                        from: raw,
                        id: "scoped:\(name)",
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

    /// `pct` hat Vorrang; beim Ausgabenfenster kann der Wert notfalls aus
    /// `used`/`limit` gerechnet werden.
    private static func percent(from raw: RawWindow) -> Double? {
        if let pct = raw.pct, pct.isFinite {
            return max(0, pct)
        }
        if let used = raw.used, let limit = raw.limit, limit > 0, used.isFinite {
            return max(0, used / limit * 100)
        }
        return nil
    }
}
