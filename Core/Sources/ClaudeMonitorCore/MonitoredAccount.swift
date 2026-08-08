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
    /// Anzeigename in fester Vorrangordnung: **Alias** aus `sequence.json`,
    /// sonst die **E-Mail** aus `usage.json`, sonst „Account <id>".
    ///
    /// Der Alias gewinnt, weil ihn der Nutzer selbst vergeben hat („privat",
    /// „arbeit") — er ist kürzer als eine E-Mail und damit das, was in eine
    /// Menüleiste und in eine schmale Karte passt. Ein leerer oder nur aus
    /// Leerzeichen bestehender Alias zählt als nicht vorhanden.
    public let displayName: String
    /// `true` für den Account, der in claude-swap gerade **aktiv** ist —
    /// gelesen aus `sequence.json` (``AccountSequenceReader``).
    ///
    /// Reine Auszeichnung: Sie ändert **nichts** am Ranking
    /// (``AccountRanking``) und nichts an der Kennungsordnung. Fehlt oder
    /// misslingt `sequence.json`, ist der Wert überall `false` — das ist ein
    /// gültiger Zustand und kein Fehler.
    public let isActive: Bool
    /// Alle Limitfenster in stabiler Reihenfolge (5h, 7d, spend, scoped, unbekannt).
    public let windows: [LimitWindow]
    /// Zeitpunkt, zu dem claude-swap die Daten geholt hat (Basis für das Datenalter).
    public let fetchedAt: Date?
    /// Zeitpunkt, zu dem claude-swap das nächste Mal abfragen will; `nil`, wenn
    /// die Quelle nichts dazu sagt. Liegt er weit in der Vergangenheit, pollt
    /// claude-swap gerade nicht — die UI kann die Daten als veraltet kennzeichnen.
    public let nextPollAt: Date?
    /// Zustand jenseits der Zahlen.
    public let state: AccountState

    public init(
        id: String,
        displayName: String,
        windows: [LimitWindow],
        fetchedAt: Date?,
        nextPollAt: Date? = nil,
        state: AccountState,
        isActive: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.nextPollAt = nextPollAt
        self.state = state
        self.isActive = isActive
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

    /// **Bindende Auslastung**: der höchste Prozentwert über **alle**
    /// Limitfenster; `nil`, wenn der Account keine Fenster hat.
    ///
    /// Die eine Stelle, an der „wie ausgelastet ist dieser Account?"
    /// beantwortet wird. Ranking (``AccountRanking``), Ampel
    /// (``overallStatus``) und die zusammengefasste Account-Zahl der Anzeige
    /// (`AccountBindingDisplay`, Kopfzeile der Account-Karte und Vorlesetext
    /// der Menüleiste) lesen ausschließlich hier — sonst könnte die Anzeige
    /// rot 95 % zeigen, während das Ranking denselben Account anhand von 10 %
    /// nach vorne sortiert.
    ///
    /// Die Menüleiste zeigt je Account **einen** Ampelpunkt und dahinter die
    /// beiden Zahlen 5 h und 7 d. Die **Zahlen** stammen aus dem jeweiligen
    /// ``LimitWindow`` selbst, nicht aus dieser Property; die **Farbe des
    /// Punktes** dagegen ist ``overallStatus`` und damit eine Ableitung von
    /// hier. Genau deshalb färbt ein versteckter Engpass (`spend`, `scoped`)
    /// den Punkt rot, obwohl beide sichtbaren Zahlen grün sind.
    ///
    /// Bewusst **alle** Fenster und nicht nur 5h/7d: Ein erschöpftes
    /// Modellkontingent (`scoped`) oder ein ausgeschöpftes Ausgabenbudget
    /// (`spend`) macht den Account genauso unbrauchbar wie ein volles
    /// Wochenlimit.
    ///
    /// **Nicht-endliche Werte schlagen konservativ durch**: Trägt *irgendein*
    /// Fenster einen nicht-endlichen Wert (`NaN`/`∞` aus einer kaputten
    /// Quelle), ist das Ergebnis `.infinity` — unabhängig von der Reihenfolge
    /// der Fenster. Ein blankes `max()` genügte dafür nicht: `[Double].max()`
    /// vergleicht paarweise, und `NaN` verliert jeden Vergleich. `[nan, 10,
    /// 20].max()` ergibt `nan`, `[10, 20, nan].max()` dagegen `20` — die
    /// Ampel hinge damit an der Position des kaputten Fensters. Mit dem
    /// Vorabtest steht sie immer auf der Haltung von
    /// ``StatusLevel/init(percent:)``: nicht-endlich ⇒ konservativ rot. Eine
    /// *Zahl* entsteht daraus nirgends — `AccountBindingDisplay` verwirft
    /// nicht-endliche Werte, `AccountRanking` bildet sie auf den
    /// schlechtesten endlichen Sortierwert ab.
    public var bindingPercent: Double? {
        let percents = windows.map { $0.percent }
        guard !percents.isEmpty else { return nil }
        guard percents.allSatisfy({ $0.isFinite }) else { return .infinity }
        return percents.max()
    }

    /// Schlechteste Ampelstufe über alle Fenster; `nil` ohne verwertbare Daten.
    public var overallStatus: StatusLevel? {
        guard hasUsableData else { return nil }
        return bindingPercent.map { StatusLevel(percent: $0) }
    }
}
