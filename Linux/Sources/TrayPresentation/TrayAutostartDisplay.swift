import Foundation
import Autostart
import ClaudeMonitorShared

/// Was der Menüeintrag „Start at login" zeigt (CM-30) — reiner Werttyp.
///
/// Die Messung (`systemctl --user is-enabled`) macht das Programmziel; hier
/// stehen nur die Übergänge, damit sie ohne Prozessstart prüfbar sind
/// (CM-20-Schichtung).
///
/// Vorbild ist `LoginItemController.swift:47-78` der macOS-Fassung: Angezeigt
/// wird immer der neu erfragte Zustand, nie der beabsichtigte.
public struct TrayAutostartDisplay: Equatable, Sendable {

    /// Der zuletzt gemessene Zustand.
    public enum Status: Equatable, Sendable {
        case known(LoginItemState)
        /// Nicht messbar (kein Nutzermanager, `systemctl` nicht startbar,
        /// unbekanntes oder unerwartetes Wort). Ausdrücklich **nicht**
        /// „nicht eingerichtet" — das wäre eine Aussage über eine Messung,
        /// die nicht stattfand (F3).
        case unavailable
    }

    /// Richtung eines Versuchs.
    public enum Attempt: Equatable, Sendable {
        case install
        case uninstall

        /// Der Zustand, den der Versuch herstellen soll.
        var target: Status {
            switch self {
            case .install: return .known(.enabled)
            case .uninstall: return .known(.disabled)
            }
        }
    }

    public let status: Status
    /// Der letzte Versuch, der sein Ziel verfehlt hat — `nil`, solange keiner
    /// gescheitert ist.
    public let failedAttempt: Attempt?

    /// Ob die Unit auf das laufende Binary zeigt (CM-34) — stille
    /// Dateimessung, ohne `systemctl`.
    public let binary: AutostartBinaryMatch

    public init(status: Status, failedAttempt: Attempt? = nil, binary: AutostartBinaryMatch) {
        self.status = status
        self.failedAttempt = failedAttempt
        self.binary = binary
    }

    /// Anfangszustand aus einer Messung.
    public init(reading: AutostartStatus.Reading, binary: AutostartBinaryMatch) {
        self.init(status: Self.status(of: reading), binary: binary)
    }

    /// Nach einem Versuch.
    ///
    /// Gescheitert ist der Versuch, wenn der Installer nicht `.ok` meldet
    /// **oder** der neu erfragte Zustand nicht das Ziel ist (2b-Auflage 7:
    /// `uninstall()` meldet `.ok`, ohne neu zu erfragen — eine Aktivierung
    /// außerhalb der geprüften `.wants`-Pfade bliebe sonst unbemerkt).
    /// Ausnahme `.requiresApproval`: Dann erklärt die Masken-Zeile den
    /// Ausgang, eine Fehlerzeile daneben wäre doppelt (F6,
    /// `LoginItemController.swift:77`).
    public func afterAttempt(
        _ attempt: Attempt,
        succeeded: Bool,
        reading: AutostartStatus.Reading,
        binary: AutostartBinaryMatch
    ) -> TrayAutostartDisplay {
        let measured = Self.status(of: reading)
        if measured == .known(.requiresApproval) {
            return TrayAutostartDisplay(status: measured, binary: binary)
        }
        let missed = !succeeded || measured != attempt.target
        return TrayAutostartDisplay(status: measured, failedAttempt: missed ? attempt : nil, binary: binary)
    }

    /// Nach einem Neu-Erfragen ohne Versuch (Menü geöffnet).
    ///
    /// Die Fehlerzeile bleibt, solange der Zustand derselbe ist wie direkt
    /// nach dem Fehlversuch — allein das Öffnen löscht sie nicht, sonst wäre
    /// sie nie zu sehen: Der Klick schließt das Menü (gnome-shell
    /// `popupMenu.js:746-750,785-787`), das nächste Öffnen fragt neu (F6).
    public func afterRequery(reading: AutostartStatus.Reading, binary: AutostartBinaryMatch) -> TrayAutostartDisplay {
        let measured = Self.status(of: reading)
        return TrayAutostartDisplay(
            status: measured,
            failedAttempt: measured == status ? failedAttempt : nil,
            binary: binary
        )
    }

    /// Stellung und Bedienbarkeit des Eintrags (F2/F3).
    public var checkmark: TrayMenuItem.Checkmark {
        switch status {
        case .known(let state):
            return TrayMenuItem.Checkmark(isOn: state.isOn, isToggleable: state.isToggleable)
        case .unavailable:
            return TrayMenuItem.Checkmark(isOn: false, isToggleable: false)
        }
    }

    /// Höchstens EINE Hinweiszeile; Vorrang Maske > nicht messbar >
    /// Fehlversuch > Binary-Abweichung (F7, CM-34). Die letzte Stufe gilt nur
    /// bei `enabled`; das Häkchen bleibt dabei gesetzt.
    public var hint: String? {
        if status == .known(.requiresApproval) { return TrayTexts.startAtLoginMasked }
        if status == .unavailable { return TrayTexts.startAtLoginUnavailable }
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

    private static func status(of reading: AutostartStatus.Reading) -> Status {
        switch reading {
        case .known(let state):
            return .known(state)
        case .unexpected, .unreadable, .managerUnavailable, .didNotRun:
            return .unavailable
        }
    }
}
