import Foundation
import Autostart
import ClaudeMonitorShared

/// Die Zustandsregeln eines ankreuzbaren Unit-Eintrags (CM-30 F2–F6) — reiner
/// Werttyp, geteilt von „Start at login" (``TrayAutostartDisplay``) und
/// „Automatic updates" (``TrayAutoUpdateDisplay``, CM-37).
///
/// Eine Quelle für beide: zwei Kopien liefen auseinander. Die Messung
/// (`systemctl --user is-enabled`) macht das Programmziel; hier stehen nur die
/// Übergänge, damit sie ohne Prozessstart prüfbar sind (CM-20-Schichtung).
///
/// Vorbild ist `LoginItemController.swift:47-78` der macOS-Fassung: Angezeigt
/// wird immer der neu erfragte Zustand, nie der beabsichtigte.
public struct TrayUnitToggle: Equatable, Sendable {

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

    public init(status: Status, failedAttempt: Attempt? = nil) {
        self.status = status
        self.failedAttempt = failedAttempt
    }

    /// Anfangszustand aus einer Messung.
    public init(reading: AutostartStatus.Reading) {
        self.init(status: Self.status(of: reading))
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
        reading: AutostartStatus.Reading
    ) -> TrayUnitToggle {
        let measured = Self.status(of: reading)
        if measured == .known(.requiresApproval) {
            return TrayUnitToggle(status: measured)
        }
        let missed = !succeeded || measured != attempt.target
        return TrayUnitToggle(status: measured, failedAttempt: missed ? attempt : nil)
    }

    /// Nach einem Neu-Erfragen ohne Versuch (Menü geöffnet).
    ///
    /// Die Fehlerzeile bleibt, solange der Zustand derselbe ist wie direkt
    /// nach dem Fehlversuch — allein das Öffnen löscht sie nicht, sonst wäre
    /// sie nie zu sehen: Der Klick schließt das Menü (gnome-shell
    /// `popupMenu.js:746-750,785-787`), das nächste Öffnen fragt neu (F6).
    public func afterRequery(reading: AutostartStatus.Reading) -> TrayUnitToggle {
        let measured = Self.status(of: reading)
        return TrayUnitToggle(status: measured, failedAttempt: measured == status ? failedAttempt : nil)
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

    static func status(of reading: AutostartStatus.Reading) -> Status {
        switch reading {
        case .known(let state):
            return .known(state)
        case .unexpected, .unreadable, .managerUnavailable, .didNotRun:
            return .unavailable
        }
    }
}
