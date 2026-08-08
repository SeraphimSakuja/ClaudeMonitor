import Foundation
import ServiceManagement

/// Der Zustand des Anmeldeobjekts, wie ihn die Oberfläche braucht.
///
/// **Warum eine eigene Abbildung und nicht direkt `SMAppService.Status`:**
/// Vier Systemzustände ergeben nur drei sinnvolle Darstellungen, und einer davon
/// ist eine Falle. `.requiresApproval` bedeutet, dass die App als Anmeldeobjekt
/// registriert ist, der Nutzer sie aber in den Systemeinstellungen deaktiviert
/// hat. Ein Schalter, der in diesem Zustand einfach „aus" zeigt, lässt sich
/// klicken, ohne dass irgendetwas passiert: `register()` wirft, das System
/// bleibt bei seiner Entscheidung. Der Nutzer sieht einen kaputten Schalter.
/// Deshalb ist das hier ein **eigener** Fall, den die Oberfläche sichtbar
/// machen muss — mit dem Weg in die Systemeinstellungen.
///
/// Die Abbildung liegt in `Shared/` und nicht im App-Target, weil sie eine
/// Regel ist und Regeln in diesem Projekt geprüft werden (`swift test`, ohne
/// Xcode-Testrunner). Sie registriert nichts und fragt nichts ab — sie bildet
/// nur ab.
public enum LoginItemState: Equatable, Sendable {

    /// Startet beim Anmelden.
    case enabled
    /// Startet nicht; lässt sich einschalten.
    case disabled
    /// Registriert, aber vom Nutzer in den Systemeinstellungen abgeschaltet.
    /// Nur dort wieder einschaltbar — nicht aus der App heraus.
    case requiresApproval
    /// Das System kennt kein Anmeldeobjekt zu diesem Programm. Tritt
    /// typischerweise auf, solange die App nicht in `/Programme` liegt.
    case unavailable

    /// Stellung des Schalters. `.requiresApproval` zählt ausdrücklich **nicht**
    /// als eingeschaltet: Die App startet in diesem Zustand nicht mit.
    public var isOn: Bool { self == .enabled }

    /// Ob der Schalter bedienbar ist — nur in den beiden Zuständen, in denen
    /// das Umlegen auch wirkt.
    ///
    /// Bei `.requiresApproval` entscheidet ausschließlich das System, bei
    /// `.unavailable` kennt es das Objekt nicht. In beiden Fällen wäre ein
    /// bedienbarer Schalter eine Attrappe.
    public var isToggleable: Bool { self == .enabled || self == .disabled }

    /// Ob die Oberfläche auf die Systemeinstellungen verweisen muss.
    public var needsSystemSettings: Bool { self == .requiresApproval }

    /// Ob die Oberfläche erklären muss, dass die App erst nach `/Programme`
    /// gehört. Der häufigste Erstkontakt: Das DMG wird geöffnet und die App aus
    /// `~/Downloads` gestartet — dort kennt das System kein Anmeldeobjekt zu
    /// ihr, und der Schalter bliebe ohne diesen Hinweis wortlos tot.
    public var needsRelocation: Bool { self == .unavailable }
}

extension LoginItemState {

    /// Bildet den Systemzustand ab.
    ///
    /// `.notFound` wird zu ``unavailable`` und nicht zu ``disabled``: Ein
    /// Schalter, den man umlegen kann, obwohl das System das Objekt gar nicht
    /// kennt, verspricht etwas, das er nicht halten kann.
    public init(status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .notRegistered:
            self = .disabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .unavailable
        @unknown default:
            // Unbekannt heißt „nicht anbieten" — die Abbildung irrt nur zur
            // sicheren Seite, wie die Entitlement-Wache auch.
            self = .unavailable
        }
    }
}
