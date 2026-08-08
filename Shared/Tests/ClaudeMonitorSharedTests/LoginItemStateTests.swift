import Testing
import ServiceManagement
import ClaudeMonitorShared

/// Die Abbildung `SMAppService.Status` → ``LoginItemState``.
///
/// Der Test, der wirklich zählt, ist ``requiresApprovalIsNeitherOnNorToggleable``:
/// Bildete man `.requiresApproval` auf `.disabled` ab — die naheliegende
/// Abkürzung, weil die App ja nicht mitstartet —, bekäme der Nutzer einen
/// Schalter, der sich klicken lässt und nichts tut. Genau diese Abkürzung soll
/// hier scheitern.
@Suite("Anmeldeobjekt-Zustand")
struct LoginItemStateTests {

    @Test func enabledMapsToOn() {
        let state = LoginItemState(status: .enabled)
        #expect(state == .enabled)
        #expect(state.isOn)
        #expect(state.isToggleable)
        #expect(!state.needsSystemSettings)
    }

    @Test func notRegisteredIsOffButToggleable() {
        let state = LoginItemState(status: .notRegistered)
        #expect(state == .disabled)
        #expect(!state.isOn)
        #expect(state.isToggleable)
        #expect(!state.needsSystemSettings)
    }

    @Test func requiresApprovalIsNeitherOnNorToggleable() {
        let state = LoginItemState(status: .requiresApproval)
        #expect(state == .requiresApproval)
        // Die App startet nicht mit — also nicht „an".
        #expect(!state.isOn)
        // Aber auch nicht aus der App heraus änderbar: Hier entscheidet das
        // System. Ohne diese Zeile wäre der Schalter eine Attrappe.
        #expect(!state.isToggleable)
        #expect(state.needsSystemSettings)
    }

    @Test func notFoundIsUnavailableRatherThanOff() {
        let state = LoginItemState(status: .notFound)
        // Bewusst nicht `.disabled`: Ein bedienbarer Schalter würde etwas
        // versprechen, das das System nicht kennt.
        #expect(state == .unavailable)
        #expect(!state.isOn)
        #expect(!state.isToggleable)
        // Nicht die Systemeinstellungen sind hier der Weg, sondern /Programme.
        #expect(!state.needsSystemSettings)
        #expect(state.needsRelocation)
    }

    @Test func onlyTheTwoWorkingStatesAreToggleable() {
        // Ein Schalter darf genau dann bedienbar sein, wenn das Umlegen auch
        // wirkt — sonst ist er eine Attrappe.
        #expect(LoginItemState.enabled.isToggleable)
        #expect(LoginItemState.disabled.isToggleable)
        #expect(!LoginItemState.requiresApproval.isToggleable)
        #expect(!LoginItemState.unavailable.isToggleable)
        // Und die beiden Erklärtexte schließen einander aus.
        #expect(LoginItemState.requiresApproval.needsSystemSettings)
        #expect(!LoginItemState.requiresApproval.needsRelocation)
        #expect(!LoginItemState.unavailable.needsSystemSettings)
        #expect(LoginItemState.unavailable.needsRelocation)
    }

    @Test func unknownStatusFallsBackToUnavailable() {
        // Ein künftiger Systemzustand darf die Oberfläche nicht dazu bringen,
        // etwas anzubieten, das sie nicht einlösen kann.
        let state = LoginItemState(status: SMAppService.Status(rawValue: 99) ?? .notFound)
        #expect(state == .unavailable)
    }
}
