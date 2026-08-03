import Foundation

/// Ampelstufe für eine Auslastung in Prozent.
///
/// Die Schwellen sind benannte Konstanten und die Grenzen eindeutig definiert:
///
/// | Bereich | Stufe |
/// |---|---|
/// | `percent < 50` | ``green`` |
/// | `50 <= percent < 85` | ``yellow`` |
/// | `percent >= 85` | ``red`` |
///
/// Die Schwellenwerte selbst gehören also jeweils zur *höheren* Stufe:
/// exakt 50 % ist gelb, exakt 85 % ist rot.
public enum StatusLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Reichlich Kontingent frei.
    case green
    /// Spürbar verbraucht.
    case yellow
    /// Nahe am Limit oder ausgeschöpft.
    case red

    /// Ab diesem Prozentwert (einschließlich) gilt ``yellow``.
    public static let yellowThreshold: Double = 50
    /// Ab diesem Prozentwert (einschließlich) gilt ``red``.
    public static let redThreshold: Double = 85

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
