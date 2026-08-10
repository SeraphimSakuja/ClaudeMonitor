import Testing
import ServiceManagement
import ClaudeMonitorShared

/// Die Abbildung `SMAppService.Status` → ``LoginItemState``.
///
/// Zwei Tests tragen hier die Last:
///
/// ``requiresApprovalIsNeitherOnNorToggleable`` — bildete man
/// `.requiresApproval` auf `.disabled` ab (die naheliegende Abkürzung, weil die
/// App ja nicht mitstartet), bekäme der Nutzer einen Schalter, der sich klicken
/// lässt und nichts tut.
///
/// ``notFoundIsOffButToggleable`` — die Gegenrichtung, und die teurere Lehre:
/// Bis v1.0 sperrte `.notFound` den Schalter mit der Begründung, die App müsse
/// erst nach `/Programme`. Die Begründung war **erfunden** und ist gemessen
/// widerlegt (10.08.2026); der Fehler traf jede Erstinstallation. Der alte Test
/// war grün, weil er dieselbe Annahme wiederholte — deshalb prüft dieser hier
/// die **Wirkung** (schaltbar), nicht bloß den Fallnamen.
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

    @Test func notFoundIsOffButToggleable() {
        let state = LoginItemState(status: .notFound)
        // „Noch nie registriert" — gemessen, nicht hergeleitet: `register()`
        // gelingt aus diesem Zustand heraus von jedem Pfad aus.
        #expect(state == .disabled)
        #expect(!state.isOn)
        // Der eigentliche Fix von CM-12: Der Schalter muss bedienbar sein.
        #expect(state.isToggleable)
        // Und es gibt nichts zu erklären — die Systemeinstellungen sind hier
        // nicht der Weg, der Schalter selbst ist es.
        #expect(!state.needsSystemSettings)
    }

    @Test func onlyApprovalBlocksTheSwitch() {
        // Ein Schalter darf genau dann gesperrt sein, wenn das Umlegen
        // nachweislich nicht wirkt. Das ist genau ein Zustand.
        #expect(LoginItemState.enabled.isToggleable)
        #expect(LoginItemState.disabled.isToggleable)
        #expect(!LoginItemState.requiresApproval.isToggleable)
        // Und der einzige gesperrte Zustand zeigt auch den Ausweg.
        #expect(LoginItemState.requiresApproval.needsSystemSettings)
        #expect(!LoginItemState.enabled.needsSystemSettings)
        #expect(!LoginItemState.disabled.needsSystemSettings)
    }

    @Test func noStateDemandsBeingMovedToApplications() {
        // Festgehalten, damit die widerlegte Folklore nicht zurückkommt:
        // Es gibt keinen Systemzustand, aus dem ein Ortswechsel folgt. Jeder
        // gesperrte Zustand hier muss über `needsSystemSettings` einen Ausweg
        // zeigen — ein anderer Erklärgrund existiert nicht mehr.
        // Über `allCases`, nicht über eine handgepflegte Liste: Eine Aufzählung
        // von Hand ließe einen künftigen vierten Fall still durchrutschen —
        // genau die Lücke, die dieser Wächter schließen soll.
        for state in LoginItemState.allCases where !state.isToggleable {
            #expect(state.needsSystemSettings)
        }
        // Und kein erreichbarer Systemstatus führt in einen gesperrten Zustand
        // ohne Ausweg.
        let statuses: [SMAppService.Status] = [.enabled, .notRegistered, .requiresApproval, .notFound]
        for status in statuses {
            let state = LoginItemState(status: status)
            #expect(state.isToggleable || state.needsSystemSettings)
        }
    }

    @Test func unknownStatusStaysToggleable() {
        // Ein künftiger Systemzustand darf dem Nutzer nicht die einzige
        // Handlung verbieten. Scheitert `register()`, zeigt die Oberfläche den
        // Fehlertext des Systems — eine geratene Erklärung war der Fehler.
        let state = LoginItemState(status: SMAppService.Status(rawValue: 99) ?? .notFound)
        #expect(state == .disabled)
        #expect(state.isToggleable)
        #expect(!state.needsSystemSettings)
    }
}
