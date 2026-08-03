import Foundation

/// Darstellungsregeln des Hinweisbalkens — Symbol und Schweregrad.
///
/// Liegt in `Shared/` statt in der View, weil beides Regeln sind und keine
/// Gestaltung: welcher Fehlzustand als schwer gilt und welches Symbol ihn
/// bezeichnet. In der View wären sie ungetestet geblieben.
public enum IssuePresentation {

    /// SF-Symbol des Fehlzustands. Alle drei Namen sind gültige SF Symbols und
    /// ab macOS 13 verfügbar.
    public static func symbolName(for issue: MonitorIssue) -> String {
        switch issue {
        case .storeNotFound: return "questionmark.folder"
        case .unsupportedSchema: return "exclamationmark.octagon"
        case .unreadable: return "arrow.clockwise"
        }
    }

    /// `true`, wenn der Zustand Handeln erfordert (rot), `false` bei einem
    /// vorübergehenden Zustand (orange).
    ///
    /// Ein momentan unlesbarer Store ist **kein** schwerer Fall: Er tritt
    /// genau dann auf, wenn claude-swap gerade schreibt, und heilt beim
    /// nächsten Durchlauf von selbst. Ihn rot zu zeichnen würde den Nutzer alle
    /// 30 s grundlos alarmieren.
    public static func isSevere(_ issue: MonitorIssue) -> Bool {
        switch issue {
        case .unreadable: return false
        case .storeNotFound, .unsupportedSchema: return true
        }
    }
}
