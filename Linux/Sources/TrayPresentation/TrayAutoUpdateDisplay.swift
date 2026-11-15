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

    /// Pfad der fremden Unit, die systemd für den Timer-Namen lädt (CM-AUF-27) —
    /// `nil`, wenn die eigene geladen wird oder nichts gemessen wurde.
    public let shadowedBy: String?

    public init(toggle: TrayUnitToggle, shadowedBy: String? = nil) {
        self.toggle = toggle
        self.shadowedBy = shadowedBy
    }

    /// Anfangszustand aus einer Messung.
    public init(reading: AutostartStatus.Reading, shadowedBy: String? = nil) {
        self.init(toggle: TrayUnitToggle(reading: reading), shadowedBy: shadowedBy)
    }

    public var status: TrayUnitToggle.Status { toggle.status }
    public var failedAttempt: TrayUnitToggle.Attempt? { toggle.failedAttempt }

    /// Nach einem Versuch.
    public func afterAttempt(
        _ attempt: TrayUnitToggle.Attempt,
        succeeded: Bool,
        reading: AutostartStatus.Reading,
        shadowedBy: String? = nil
    ) -> TrayAutoUpdateDisplay {
        TrayAutoUpdateDisplay(
            toggle: toggle.afterAttempt(attempt, succeeded: succeeded, reading: reading),
            shadowedBy: shadowedBy
        )
    }

    /// Nach einem Neu-Erfragen ohne Versuch (Menü geöffnet).
    public func afterRequery(reading: AutostartStatus.Reading, shadowedBy: String? = nil) -> TrayAutoUpdateDisplay {
        TrayAutoUpdateDisplay(toggle: toggle.afterRequery(reading: reading), shadowedBy: shadowedBy)
    }

    /// Stellung und Bedienbarkeit des Eintrags (FE 2). Bei fremder Unit
    /// (CM-AUF-27) weder gesetzt noch bedienbar — ein „an" gälte der fremden
    /// Unit, nicht diesem Programm.
    public var checkmark: TrayMenuItem.Checkmark {
        if shadowedBy != nil { return TrayMenuItem.Checkmark(isOn: false, isToggleable: false) }
        return toggle.checkmark
    }

    /// Höchstens EINE Hinweiszeile; Vorrang Maske > nicht messbar > fremde
    /// Unit (CM-AUF-27) > Fehlversuch (FE 5).
    public var hint: String? {
        if status == .known(.requiresApproval) { return TrayTexts.automaticUpdatesMasked }
        if status == .unavailable { return TrayTexts.automaticUpdatesUnavailable }
        if let shadowedBy { return TrayTexts.automaticUpdatesShadowed(path: shadowedBy) }
        switch failedAttempt {
        case .install: return TrayTexts.automaticUpdatesInstallFailed
        case .uninstall: return TrayTexts.automaticUpdatesUninstallFailed
        case nil: return nil
        }
    }
}
