import Foundation

/// Zustand eines Resets, live aus `resets_at` gerechnet.
///
/// Es gibt bewusst **keine negative Dauer**: Liegt der Reset in der
/// Vergangenheit, ist das der eigene Zustand ``due`` („Reset fällig"), den die
/// UI als solchen anzeigt, statt einen rückwärts laufenden Countdown zu zeigen.
public enum ResetTiming: Sendable, Equatable {
    /// Die Quelle hat keinen Reset-Zeitpunkt geliefert.
    case unknown
    /// Der Reset-Zeitpunkt ist erreicht oder überschritten.
    case due
    /// Verbleibende Zeit bis zum Reset, immer > 0.
    case remaining(TimeInterval)

    /// Leitet den Zustand aus einem optionalen Reset-Zeitpunkt ab.
    public init(resetsAt: Date?, now: Date = Date()) {
        guard let resetsAt else {
            self = .unknown
            return
        }
        let seconds = resetsAt.timeIntervalSince(now)
        // Nicht-endliche Werte (kaputte Quelle) wie „fällig" behandeln, statt
        // eine NaN-Dauer weiterzureichen.
        guard seconds.isFinite else {
            self = .due
            return
        }
        self = seconds > 0 ? .remaining(seconds) : .due
    }

    /// Verbleibende Sekunden, geklemmt auf `>= 0`.
    /// `nil` nur bei ``unknown`` — „fällig" ist definitiv 0, nicht unbekannt.
    public var remainingSeconds: TimeInterval? {
        switch self {
        case .unknown: return nil
        case .due: return 0
        case .remaining(let seconds): return seconds
        }
    }

    /// `true`, wenn der Reset überfällig ist.
    public var isDue: Bool { self == .due }
}
