import Foundation
import Autostart

/// Was der Menüeintrag „Automatic updates" zeigt (CM-37) — reiner Werttyp.
///
/// Gegenstück zu ``TrayAutostartDisplay`` für den **Timer**
/// `claude-monitor-tray-update.timer` (FE 2). Die Zustandsregeln stehen in
/// ``TrayUnitToggle``. Keine Binary-Abweichungsstufe und keine Zeile „letzter
/// Lauf gescheitert" (FE 5): beides bietet nur die CLI.
public struct TrayAutoUpdateDisplay: Equatable, Sendable {

    public typealias Attempt = TrayUnitToggle.Attempt

    public let toggle: TrayUnitToggle

    public init(toggle: TrayUnitToggle) {
        self.toggle = toggle
    }

    /// Anfangszustand aus einer Messung.
    public init(reading: AutostartStatus.Reading) {
        self.init(toggle: TrayUnitToggle(reading: reading))
    }

    public var status: TrayUnitToggle.Status { toggle.status }
    public var failedAttempt: TrayUnitToggle.Attempt? { toggle.failedAttempt }

    /// Nach einem Versuch.
    public func afterAttempt(
        _ attempt: TrayUnitToggle.Attempt,
        succeeded: Bool,
        reading: AutostartStatus.Reading
    ) -> TrayAutoUpdateDisplay {
        TrayAutoUpdateDisplay(toggle: toggle.afterAttempt(attempt, succeeded: succeeded, reading: reading))
    }

    /// Nach einem Neu-Erfragen ohne Versuch (Menü geöffnet).
    public func afterRequery(reading: AutostartStatus.Reading) -> TrayAutoUpdateDisplay {
        TrayAutoUpdateDisplay(toggle: toggle.afterRequery(reading: reading))
    }

    /// Stellung und Bedienbarkeit des Eintrags (FE 2).
    public var checkmark: TrayMenuItem.Checkmark { toggle.checkmark }

    /// Höchstens EINE Hinweiszeile; Vorrang Maske > nicht messbar >
    /// Fehlversuch (FE 5).
    public var hint: String? {
        if status == .known(.requiresApproval) { return TrayTexts.automaticUpdatesMasked }
        if status == .unavailable { return TrayTexts.automaticUpdatesUnavailable }
        switch failedAttempt {
        case .install: return TrayTexts.automaticUpdatesInstallFailed
        case .uninstall: return TrayTexts.automaticUpdatesUninstallFailed
        case nil: return nil
        }
    }
}
