import Foundation
import ClaudeMonitorCore

/// Die Statuszeile unter dem Accountnamen.
///
/// Bildet die Pflicht-Zustände der Spezifikation ab. Bewusst ein Aufzählungstyp
/// und **kein** fertiger String: Die Regel, welcher Zustand gewinnt, ist damit
/// prüfbar, ohne die Formulierungen festzunageln — die kommen aus dem String
/// Catalog und dürfen sich ändern.
public enum AccountStatusLine: Equatable, Sendable {

    /// Daten frisch und Abruf läuft.
    case upToDate
    /// `lastGood` fehlt — noch nie erfolgreich abgefragt. **Nicht** 0 %.
    case noData
    /// Token tot, der Account muss in claude-swap neu angemeldet werden.
    case reLoginRequired(strikes: Int)
    /// claude-swap pausiert Abfragen bis zu diesem Zeitpunkt.
    case paused(until: Date)
    /// Letzter Abrufversuch schlug fehl; alte Zahlen können noch stehen.
    case fetchFailed(message: String)
    /// Daten sind älter als die Toleranz — mit Altersangabe anzuzeigen.
    case stale(age: TimeInterval)

    /// Ab diesem Datenalter gilt ein Account als veraltet.
    ///
    /// claude-swap pollt selbst alle 30 s; das Zehnfache davon lässt Aussetzer
    /// durchgehen, ohne einen echten Stillstand zu verschweigen.
    public static let staleThreshold: TimeInterval = 300

    /// Leitet die Statuszeile ab.
    ///
    /// Reihenfolge der Dringlichkeit: toter Token → keine Daten → Pause →
    /// Fehlversuch → veraltet → in Ordnung. Der gravierendste Zustand gewinnt,
    /// damit nie ein beruhigendes „aktuell" über einem toten Token steht.
    public static func make(for account: MonitoredAccount, now: Date = Date()) -> AccountStatusLine {
        switch account.state {
        case .authDead(let strikes):
            return .reLoginRequired(strikes: strikes)
        case .noData:
            return .noData
        case .backoff(let until):
            // Ein abgelaufener Backoff ist keine Pause mehr — dann entscheidet
            // allein das Datenalter.
            if until > now { return .paused(until: until) }
            return staleOrUpToDate(account, now: now)
        case .failing(let message):
            return .fetchFailed(message: message)
        case .ok:
            return staleOrUpToDate(account, now: now)
        }
    }

    private static func staleOrUpToDate(_ account: MonitoredAccount, now: Date) -> AccountStatusLine {
        guard let age = account.dataAge(now: now) else { return .upToDate }
        return age > staleThreshold ? .stale(age: age) : .upToDate
    }

    /// `true`, wenn die Zeile eine Warnung ist und optisch hervorgehoben gehört.
    public var isWarning: Bool {
        switch self {
        case .upToDate: return false
        case .noData, .reLoginRequired, .paused, .fetchFailed, .stale: return true
        }
    }
}
