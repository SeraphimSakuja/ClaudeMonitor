import Foundation
import ClaudeMonitorCore

/// Die Restzeit bis zu einem Reset, wie sie in der **Menüleiste** steht.
///
/// **Warum grob und nicht sekundengenau:** Die Leiste ist ein einziges
/// gerendertes `NSImage` (`MenuBarImageRenderer`) — dort gibt es keinen
/// tickenden Text wie `Text(_:style: .timer)` im Detailfenster. Gezeichnet wird
/// beim Poll, also alle 30 s. Ein `mm:ss`-Countdown spränge sichtbar in
/// 30-Sekunden-Schritten und sähe schlicht kaputt aus; auf Minutenebene fällt
/// derselbe Versatz nicht auf.
///
/// **Warum ohne Wörter:** In der Leiste steht sonst nur Zahl und Zeichen — kein
/// „%", keine Beschriftung. Die Formate hier sind aus demselben Grund
/// sprachneutral: `2h14`, `47m`, `<1m`, `0m`. Sie brauchen keine Übersetzung
/// und kosten keine Breite. Das Detailfenster erklärt die Einheiten;
/// ``ResetDisplay`` bleibt dort der zuständige Typ.
public enum ResetCountdownFormat {

    /// Ab dieser Restzeit wird in Tagen gerechnet.
    public static let dayThreshold: TimeInterval = 24 * 3600
    /// Ab dieser Restzeit wird in Stunden gerechnet.
    public static let hourThreshold: TimeInterval = 3600
    /// Unterhalb dieser Restzeit steht nur noch „gleich".
    public static let minuteThreshold: TimeInterval = 60

    /// Was steht, wenn der Reset erreicht oder überschritten ist.
    ///
    /// `0m` und nicht „fällig": sprachneutral und im selben Zahlenbild wie der
    /// Rest der Leiste. Ein Reset in der Vergangenheit ist definitiv 0, nicht
    /// unbekannt — genau die Zusage von ``ResetTiming/due``.
    public static let dueText = "0m"

    /// Was steht, solange weniger als eine Minute bleibt.
    public static let imminentText = "<1m"

    /// Fertiger Text; `nil`, wenn über den Reset nichts bekannt ist.
    ///
    /// `nil` heißt: gar nichts zeichnen. Ein Platzhalter wie „–" wäre hier
    /// falsch — anders als bei den Prozentzahlen verschiebt eine fehlende
    /// Restzeit nichts, sie ist einfach nicht da.
    public static func text(for timing: ResetTiming) -> String? {
        switch timing {
        case .unknown:
            return nil
        case .due:
            return dueText
        case .remaining(let seconds):
            return text(forRemaining: seconds)
        }
    }

    /// Formt eine positive Restzeit.
    static func text(forRemaining seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return dueText }

        if seconds >= dayThreshold {
            let days = Int(seconds / dayThreshold)
            let hours = Int((seconds - Double(days) * dayThreshold) / hourThreshold)
            return "\(days)d\(hours)"
        }
        if seconds >= hourThreshold {
            let hours = Int(seconds / hourThreshold)
            let minutes = Int((seconds - Double(hours) * hourThreshold) / minuteThreshold)
            // Zweistellig: `2h04` und nicht `2h4` — sonst liest sich die Zahl
            // je nach Minute unterschiedlich lang und die Leiste zappelt.
            return String(format: "%dh%02d", hours, minutes)
        }
        if seconds >= minuteThreshold {
            return "\(Int(seconds / minuteThreshold))m"
        }
        return imminentText
    }
}
