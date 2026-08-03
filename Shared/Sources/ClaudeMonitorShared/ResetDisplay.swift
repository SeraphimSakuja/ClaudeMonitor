import Foundation
import ClaudeMonitorCore

/// Wie der Reset eines Limitfensters angezeigt wird.
///
/// Es gibt bewusst **keinen** Fall mit negativer Dauer: Ein Reset in der
/// Vergangenheit ist ``due`` („Reset fällig"), kein rückwärts laufender
/// Countdown.
public enum ResetDisplay: Equatable, Sendable {
    /// Die Quelle liefert keinen Reset-Zeitpunkt.
    case unknown
    /// Reset ist erreicht oder überschritten.
    case due
    /// Läuft — die View zeigt die Restzeit live über `Text(_:style: .timer)`
    /// gegen dieses Datum, statt einen zum Anzeigezeitpunkt eingefrorenen
    /// String zu rendern.
    case counting(until: Date)

    /// Leitet die Anzeige aus einem Fenster ab.
    public static func make(for window: LimitWindow, now: Date = Date()) -> ResetDisplay {
        switch window.resetTiming(now: now) {
        case .unknown:
            return .unknown
        case .due:
            return .due
        case .remaining:
            // `resetsAt` ist hier garantiert gesetzt — ohne Datum gäbe es kein
            // `.remaining`. Der Fallback hält die Funktion trotzdem total.
            guard let resetsAt = window.resetsAt else { return .unknown }
            return .counting(until: resetsAt)
        }
    }
}
