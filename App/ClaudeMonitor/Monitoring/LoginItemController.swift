import Foundation
import AppKit
import OSLog
import ServiceManagement
import ClaudeMonitorShared

/// Verwaltet das Anmeldeobjekt („beim Anmelden starten").
///
/// Registriert wird über ``SMAppService/mainApp`` — der moderne Weg seit
/// macOS 13. Kein `LaunchAgent`-Plist von Hand, kein
/// `SMLoginItemSetEnabled`: Beides ist überholt und hinterlässt Reste, die
/// niemand mehr findet. Das System merkt sich die Registrierung anhand der
/// Bundle-ID; ein Update, das die App-Binärdatei austauscht (später über
/// Sparkle), lässt sie deshalb unberührt.
///
/// **Der Zustand wird nach jedem Versuch neu vom System erfragt, nie
/// fortgeschrieben.** Ein `register()` kann scheitern, ohne zu werfen — etwa
/// wenn der Nutzer das Objekt in den Systemeinstellungen abgeschaltet hat.
/// Würde die Klasse ihren Schalter selbst auf „an" setzen, zeigte die
/// Oberfläche einen Zustand, den das System nicht teilt.
@MainActor
final class LoginItemController: ObservableObject {

    /// Zustand für die Oberfläche. Die Abbildung liegt geprüft in `Shared/`.
    @Published private(set) var state: LoginItemState
    /// Grund des letzten gescheiterten Versuchs, sonst `nil`.
    @Published private(set) var lastFailure: String?

    private let service: SMAppService
    private let logger = Logger(subsystem: AppGroup.loggingSubsystem, category: "LoginItem")

    init(service: SMAppService = .mainApp) {
        self.service = service
        self.state = LoginItemState(status: service.status)
    }

    /// Fragt den Systemzustand neu ab.
    ///
    /// Nötig, weil der Nutzer das Anmeldeobjekt jederzeit **außerhalb** der App
    /// umschalten kann. Wird beim Öffnen des Fensters aufgerufen — ein Poller
    /// wäre für eine Einstellung, die sich praktisch nie ändert, verschwendet.
    /// Der Fehlertext des letzten Versuchs wird dabei verworfen: Die View hält
    /// diesen Controller als `@StateObject` und überlebt bei
    /// `MenuBarExtra(.window)` das Schließen des Fensters. Ohne das Löschen
    /// stünde beim nächsten Öffnen ein alter Fehler unter einem inzwischen
    /// gesunden Schalter — er beschriebe einen Zustand, den es nicht mehr gibt.
    func refresh() {
        state = LoginItemState(status: service.status)
        lastFailure = nil
    }

    /// Schaltet das Anmeldeobjekt ein oder aus.
    ///
    /// Nach dem Versuch wird der Zustand **immer** neu erfragt, auch im
    /// Fehlerfall: Scheitert das Einschalten, weil der Nutzer die App in den
    /// Systemeinstellungen gesperrt hat, meldet das System danach
    /// `.requiresApproval` — und genau dieser Zustand gehört in die Anzeige,
    /// nicht die Fehlermeldung allein.
    func setEnabled(_ enabled: Bool) {
        // Lokal gehalten und **nach** `refresh()` zugewiesen: `refresh()` löscht
        // ``lastFailure``, ein vorher gesetzter Text wäre also wieder weg.
        var failure: String?
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("Anmeldeobjekt konnte nicht geändert werden: \(error.localizedDescription)")
            failure = error.localizedDescription
        }
        refresh()
        // Der Fehler ist nur dann eine Meldung wert, wenn der Zustand ihn nicht
        // schon erklärt: `.requiresApproval` zeigt die Oberfläche mitsamt dem
        // Weg in die Systemeinstellungen ohnehin an.
        lastFailure = state.needsSystemSettings ? nil : failure
    }

    /// Öffnet die Systemeinstellungen bei „Anmelden & Erweiterungen".
    ///
    /// Der einzige Weg aus `.requiresApproval` heraus — dort und nirgendwo
    /// sonst lässt sich die Sperre aufheben.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
