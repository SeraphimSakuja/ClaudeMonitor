import Foundation

/// Ampelstufe für eine Auslastung in Prozent.
///
/// Die Schwellen sind benannte Konstanten und die Grenzen eindeutig definiert:
///
/// | Bereich | Stufe |
/// |---|---|
/// | `percent < 70` | ``green`` |
/// | `70 <= percent < 90` | ``yellow`` |
/// | `percent >= 90` | ``red`` |
///
/// Die Schwellenwerte selbst gehören also jeweils zur *höheren* Stufe:
/// exakt 70 % ist gelb, exakt 90 % ist rot.
/// Gleiche Bänder wie cswap (`claude_swap/tui/theme.py` `WARN_PCT`/`CRIT_PCT`), Entscheid CM-44.
public enum StatusLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Reichlich Kontingent frei.
    case green
    /// Spürbar verbraucht.
    case yellow
    /// Nahe am Limit oder ausgeschöpft.
    case red

    /// Ab diesem Prozentwert (einschließlich) gilt ``yellow``.
    public static let yellowThreshold: Double = 70
    /// Ab diesem Prozentwert (einschließlich) gilt ``red``.
    public static let redThreshold: Double = 90

    /// Stuft einen Prozentwert ein.
    ///
    /// Nicht-endliche Werte (NaN/∞ aus einer kaputten Quelle) werden
    /// konservativ als ``red`` gewertet — lieber zu vorsichtig als ein
    /// grüner Account, der in Wahrheit leer ist.
    public init(percent: Double) {
        guard percent.isFinite else {
            self = .red
            return
        }
        if percent >= Self.redThreshold {
            self = .red
        } else if percent >= Self.yellowThreshold {
            self = .yellow
        } else {
            self = .green
        }
    }
}
