import Foundation

/// Zustand eines Accounts jenseits der reinen Prozentwerte.
///
/// Deckt die Pflicht-Zustände der UI ab: „noch keine Daten" ist ausdrücklich
/// **nicht** 0 %, ein toter Token ist ein eigener Fehlerzustand.
public enum AccountState: Sendable, Codable, Equatable {
    /// Daten vorhanden und plausibel.
    case ok
    /// `lastGood` fehlt oder ist `null` — claude-swap hat für diesen Account
    /// noch nie erfolgreich abgefragt. **Nicht** als 0 % anzeigen.
    case noData
    /// `authDeadStrikes` hat die Schwelle erreicht: Der hinterlegte Token ist tot,
    /// der Account muss in claude-swap neu angemeldet werden.
    case authDead(strikes: Int)
    /// claude-swap pausiert Abfragen bis zu diesem Zeitpunkt.
    case backoff(until: Date)
    /// Letzter Abrufversuch schlug mit dieser Meldung fehl (Daten können
    /// trotzdem aus `lastGood` vorliegen, dann aber veraltet).
    case failing(message: String)
}

/// Ein von claude-swap verwalteter Account mit allen seinen Limitfenstern.
public struct MonitoredAccount: Sendable, Codable, Equatable, Identifiable {

    /// Kennung aus dem Store (der Slot-Schlüssel, z. B. `"1"`).
    /// Dient zugleich als stabiler Tiebreaker beim Ranking.
    public let id: String
    /// Anzeigename — E-Mail, falls vorhanden, sonst „Account <id>".
    public let displayName: String
    /// Alle Limitfenster in stabiler Reihenfolge (5h, 7d, spend, scoped, unbekannt).
    public let windows: [LimitWindow]
    /// Zeitpunkt, zu dem claude-swap die Daten geholt hat (Basis für das Datenalter).
    public let fetchedAt: Date?
    /// Zustand jenseits der Zahlen.
    public let state: AccountState

    public init(
        id: String,
        displayName: String,
        windows: [LimitWindow],
        fetchedAt: Date?,
        state: AccountState
    ) {
        self.id = id
        self.displayName = displayName
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.state = state
    }

    /// Erstes Fenster der gesuchten Art.
    public func window(kind: LimitWindow.Kind) -> LimitWindow? {
        windows.first { $0.kind == kind }
    }

    /// Auslastung des rollierenden 5-Stunden-Fensters.
    public var fiveHourPercent: Double? { window(kind: .fiveHour)?.percent }

    /// Auslastung des Wochenfensters.
    public var sevenDayPercent: Double? { window(kind: .sevenDay)?.percent }

    /// Ob überhaupt verwertbare Zahlen vorliegen.
    ///
    /// Ein toter Token gilt auch dann als unverwertbar, wenn noch alte Werte
    /// im Store stehen — der Account ist nicht nutzbar.
    public var hasUsableData: Bool {
        switch state {
        case .noData, .authDead:
            return false
        case .ok, .backoff, .failing:
            return !windows.isEmpty
        }
    }

    /// Alter der Daten in Sekunden; `nil`, wenn kein Abrufzeitpunkt bekannt ist.
    /// Nie negativ (Uhrensprünge werden auf 0 geklemmt).
    public func dataAge(now: Date = Date()) -> TimeInterval? {
        guard let fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        return age.isFinite ? max(0, age) : nil
    }

    /// Schlechteste Ampelstufe über alle Fenster; `nil` ohne verwertbare Daten.
    public var overallStatus: StatusLevel? {
        guard hasUsableData else { return nil }
        let worst = windows.map { $0.percent }.max()
        return worst.map { StatusLevel(percent: $0) }
    }
}
