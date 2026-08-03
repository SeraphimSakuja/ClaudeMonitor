import Foundation
import ClaudeMonitorCore

/// Was das Kärtchen eines Accounts unter Name und Statuszeile zeigt.
///
/// Die Regel steht **hier** und nicht in der View, damit sie prüfbar ist: Ein
/// Account ohne verwertbare Daten darf keine Prozentzeilen und keine
/// Fortschrittsbalken rendern. Andernfalls stand im selben Kärtchen oben „–"
/// und „Neuanmeldung nötig", darunter aber die eingefrorenen Altwerte aus dem
/// Store — ein Widerspruch gegen ``MonitoredAccount/hasUsableData``, den der
/// Nutzer als „läuft doch" liest.
public enum AccountWindowsDisplay: Equatable, Sendable {

    /// Diese Fenster dürfen gerendert werden.
    case windows([LimitWindow])
    /// Keine verwertbaren Zahlen — Hinweistext statt Balken.
    case noUsableData

    /// Leitet ab, was gezeigt werden darf.
    public static func make(for account: MonitoredAccount) -> AccountWindowsDisplay {
        guard account.hasUsableData, !account.windows.isEmpty else { return .noUsableData }
        return .windows(account.windows)
    }
}
