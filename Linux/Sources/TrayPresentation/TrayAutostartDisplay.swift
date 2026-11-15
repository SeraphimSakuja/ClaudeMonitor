import Foundation
import Autostart
import ClaudeMonitorShared

/// Was der Menüeintrag „Start at login" zeigt (CM-30) — reiner Werttyp.
///
/// Die Zustandsregeln (F2–F6) stehen seit CM-37 in ``TrayUnitToggle``; hier
/// bleiben Hinweiszeile und Binary-Abweichung (F7, CM-34). Die öffentliche
/// API ist unverändert.
public struct TrayAutostartDisplay: Equatable, Sendable {

    public typealias Status = TrayUnitToggle.Status
    public typealias Attempt = TrayUnitToggle.Attempt

    private let toggle: TrayUnitToggle

    public var status: Status { toggle.status }
    /// Der letzte Versuch, der sein Ziel verfehlt hat — `nil`, solange keiner
    /// gescheitert ist.
    public var failedAttempt: Attempt? { toggle.failedAttempt }

    /// Ob die Unit auf das laufende Binary zeigt (CM-34) — stille
    /// Dateimessung, ohne `systemctl`.
    public let binary: AutostartBinaryMatch

    /// Pfad der fremden Unit, die systemd für den Namen lädt (CM-AUF-1) —
    /// `nil`, wenn die eigene geladen wird oder nichts gemessen wurde.
    public let shadowedBy: String?

    public init(
        status: Status,
        failedAttempt: Attempt? = nil,
        binary: AutostartBinaryMatch,
        shadowedBy: String? = nil
    ) {
        self.toggle = TrayUnitToggle(status: status, failedAttempt: failedAttempt)
        self.binary = binary
        self.shadowedBy = shadowedBy
    }

    /// Anfangszustand aus einer Messung.
    public init(reading: AutostartStatus.Reading, binary: AutostartBinaryMatch, shadowedBy: String?) {
        self.toggle = TrayUnitToggle(reading: reading)
        self.binary = binary
        self.shadowedBy = shadowedBy
    }

    private init(toggle: TrayUnitToggle, binary: AutostartBinaryMatch, shadowedBy: String?) {
        self.toggle = toggle
        self.binary = binary
        self.shadowedBy = shadowedBy
    }

    /// Nach einem Versuch (Regeln: ``TrayUnitToggle/afterAttempt(_:succeeded:reading:)``).
    public func afterAttempt(
        _ attempt: Attempt,
        succeeded: Bool,
        reading: AutostartStatus.Reading,
        binary: AutostartBinaryMatch,
        shadowedBy: String?
    ) -> TrayAutostartDisplay {
        TrayAutostartDisplay(
            toggle: toggle.afterAttempt(attempt, succeeded: succeeded, reading: reading),
            binary: binary,
            shadowedBy: shadowedBy
        )
    }

    /// Nach einem Neu-Erfragen ohne Versuch (Menü geöffnet).
    public func afterRequery(
        reading: AutostartStatus.Reading,
        binary: AutostartBinaryMatch,
        shadowedBy: String?
    ) -> TrayAutostartDisplay {
        TrayAutostartDisplay(
            toggle: toggle.afterRequery(reading: reading),
            binary: binary,
            shadowedBy: shadowedBy
        )
    }

    /// Stellung und Bedienbarkeit des Eintrags (F2/F3). Bei fremder Unit
    /// (CM-AUF-1) weder gesetzt noch bedienbar — ein „an" gälte der fremden
    /// Unit, nicht diesem Programm.
    public var checkmark: TrayMenuItem.Checkmark {
        if shadowedBy != nil { return TrayMenuItem.Checkmark(isOn: false, isToggleable: false) }
        return toggle.checkmark
    }

    /// Höchstens EINE Hinweiszeile; Vorrang Maske > nicht messbar > fremde
    /// Unit (CM-AUF-1) > Fehlversuch > Binary-Abweichung (F7, CM-34). Die letzte Stufe gilt nur
    /// bei `enabled`; das Häkchen bleibt dabei gesetzt.
    public var hint: String? {
        if status == .known(.requiresApproval) { return TrayTexts.startAtLoginMasked }
        if status == .unavailable { return TrayTexts.startAtLoginUnavailable }
        if let shadowedBy { return TrayTexts.startAtLoginShadowed(path: shadowedBy) }
        switch failedAttempt {
        case .install: return TrayTexts.startAtLoginInstallFailed
        case .uninstall: return TrayTexts.startAtLoginUninstallFailed
        case nil:
            guard status == .known(.enabled) else { return nil }
            switch binary {
            case .differs, .missing: return TrayTexts.startAtLoginOtherBinary
            case .matches, .notMeasured: return nil
            }
        }
    }
}
