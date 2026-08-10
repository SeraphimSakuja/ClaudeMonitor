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
/// ⚠️ **`.notFound` heißt „noch nie registriert" — nicht „liegt am falschen
/// Ort".** Bis v1.0 gab es hier einen vierten Fall (`unavailable`), der genau
/// das behauptete und den Schalter sperrte. Die Behauptung ist **gemessen
/// widerlegt** (10.08.2026, Developer-ID-signiertes Sonden-Bundle):
///
/// | Lage | gemessener Status |
/// |---|---|
/// | nie registriert, **außerhalb** `/Programme` | `notFound` (3) |
/// | nach `register()` — **von außerhalb** `/Programme` | `enabled` (1) |
/// | nach `unregister()` | `notRegistered` (0) |
///
/// Der Ort im Dateisystem spielt keine Rolle; `register()` gelingt von jedem
/// Pfad. Die alte Annahme stammte aus `SMAppService.h:127-130` — einem Absatz
/// über **LaunchDaemons**, die vor dem Login bootstrappen müssen. Für `mainApp`
/// gilt er nicht. Wer den Fall wieder einführen will, muss ihn erst messen.
///
/// Die Abbildung liegt in `Shared/` und nicht im App-Target, weil sie eine
/// Regel ist und Regeln in diesem Projekt geprüft werden (`swift test`, ohne
/// Xcode-Testrunner). Sie registriert nichts und fragt nichts ab — sie bildet
/// nur ab.
///
/// `CaseIterable` ist nicht für die App da, sondern für den Wächtertest: Er
/// iteriert über ``allCases`` statt über eine handgepflegte Liste, damit ein
/// künftiger vierter Fall nicht still an ihm vorbeikommt.
public enum LoginItemState: Equatable, Sendable, CaseIterable {

    /// Startet beim Anmelden.
    case enabled
    /// Startet nicht; lässt sich einschalten. Umfasst „nie registriert"
    /// (`.notFound`) und „abgemeldet" (`.notRegistered`) — für den Nutzer
    /// derselbe Zustand, und in beiden wirkt `register()`.
    case disabled
    /// Registriert, aber vom Nutzer in den Systemeinstellungen abgeschaltet.
    /// Nur dort wieder einschaltbar — nicht aus der App heraus.
    case requiresApproval

    /// Stellung des Schalters. `.requiresApproval` zählt ausdrücklich **nicht**
    /// als eingeschaltet: Die App startet in diesem Zustand nicht mit.
    public var isOn: Bool { self == .enabled }

    /// Ob der Schalter bedienbar ist.
    ///
    /// Gesperrt ist einzig `.requiresApproval` — dort entscheidet
    /// ausschließlich das System, ein bedienbarer Schalter wäre eine Attrappe.
    /// In jedem anderen Zustand wirkt das Umlegen.
    public var isToggleable: Bool { self != .requiresApproval }

    /// Ob die Oberfläche auf die Systemeinstellungen verweisen muss.
    public var needsSystemSettings: Bool { self == .requiresApproval }
}

extension LoginItemState {

    /// Bildet den Systemzustand ab.
    ///
    /// `.notFound` wird zu ``disabled``: Das System kennt zu diesem Programm
    /// noch kein Anmeldeobjekt, und genau das legt `register()` an — gemessen
    /// auch außerhalb von `/Programme`.
    public init(status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .notRegistered:
            self = .disabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .disabled
        @unknown default:
            // Bewusst schaltbar statt gesperrt: Ein unbekannter Systemzustand
            // ist kein Grund, dem Nutzer die einzige Handlung zu verbieten.
            // Scheitert `register()`, zeigt die Oberfläche den Fehlertext des
            // Systems — das ist die ehrliche Auskunft. Eine geratene Erklärung
            // war der Fehler, den diese Datei bis v1.0 gemacht hat.
            self = .disabled
        }
    }
}
