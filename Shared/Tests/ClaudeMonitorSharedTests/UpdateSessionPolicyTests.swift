import Testing
import ClaudeMonitorShared

/// Der Ereignis→Wirkung-Automat, der verhindert, dass ClaudeMonitor während
/// einer Sparkle-Update-Session in `.regular` (mit Dock-Symbol) hängen
/// bleibt.
///
/// Die Tests, die wirklich zählen, sind ``sessionFinishedWithoutStartIsStillAccessory``
/// und ``twoFullSessionsInSequenceLeaveNoLeak``: Sparkles Rückrufe sind nicht
/// garantiert paarweise, und genau dort entsteht das geklebte Dock-Symbol,
/// das nur ein Neustart wieder löst.
@Suite("Update-Session-Policy")
struct UpdateSessionPolicyTests {

    @Test func userInitiatedCheckStartedActivatesRegular() {
        var policy = UpdateSessionPolicy()
        let effect = policy.handle(.userInitiatedCheckStarted)
        #expect(effect.activation == .regular)
    }

    @Test func scheduledUpdateShowsBadge() {
        var policy = UpdateSessionPolicy()
        let effect = policy.handle(.willShowUpdate(userInitiated: false))
        #expect(effect.activation == .regular)
        #expect(effect.dockBadge == .visible)
    }

    @Test func userInitiatedUpdateKeepsBadgeHidden() {
        var policy = UpdateSessionPolicy()
        let effect = policy.handle(.willShowUpdate(userInitiated: true))
        #expect(effect.activation == .regular)
        #expect(effect.dockBadge == .hidden)
    }

    @Test func modalAlertActivatesRegular() {
        // Deckt sowohl „alles aktuell" als auch den Fehlerdialog ab —
        // beides meldet Sparkle über denselben Callback.
        var policy = UpdateSessionPolicy()
        let effect = policy.handle(.willShowModalAlert)
        #expect(effect.activation == .regular)
    }

    @Test func userAttentionReceivedHidesBadgeButKeepsSessionActive() {
        var policy = UpdateSessionPolicy()
        _ = policy.handle(.willShowUpdate(userInitiated: false))
        let effect = policy.handle(.userAttentionReceived)
        #expect(effect.dockBadge == .hidden)
        // Die Session läuft noch — die Aktivierung darf nicht vorzeitig
        // zurückfallen.
        #expect(effect.activation == .regular)
    }

    @Test func sessionFinishedReturnsToAccessoryAndHidesBadge() {
        var policy = UpdateSessionPolicy()
        _ = policy.handle(.willShowUpdate(userInitiated: false))
        let effect = policy.handle(.sessionFinished)
        #expect(effect.activation == .accessory)
        #expect(effect.dockBadge == .hidden)
    }

    @Test func sessionFinishedTwiceInARowIsIdempotent() {
        var policy = UpdateSessionPolicy()
        _ = policy.handle(.userInitiatedCheckStarted)
        let first = policy.handle(.sessionFinished)
        let second = policy.handle(.sessionFinished)
        #expect(first == second)
        #expect(second.activation == .accessory)
        #expect(second.dockBadge == .hidden)
    }

    @Test func sessionFinishedWithoutStartIsStillAccessory() {
        // Sparkles Rückrufe sind nicht garantiert paarweise. Ein
        // Fehlerpfad, der `sessionFinished` ohne vorangegangenen Start
        // meldet, darf die App nicht in `.regular` zurücklassen.
        var policy = UpdateSessionPolicy()
        let effect = policy.handle(.sessionFinished)
        #expect(effect.activation == .accessory)
        #expect(effect.dockBadge == .hidden)
    }

    @Test func appWillTerminateMidSessionReturnsToAccessory() {
        var policy = UpdateSessionPolicy()
        _ = policy.handle(.userInitiatedCheckStarted)
        _ = policy.handle(.willShowUpdate(userInitiated: false))
        let effect = policy.handle(.appWillTerminate)
        #expect(effect.activation == .accessory)
        #expect(effect.dockBadge == .hidden)
    }

    @Test func twoFullSessionsInSequenceLeaveNoLeak() {
        // Kein Zustandsleck zwischen zwei aufeinanderfolgenden Sessions —
        // sonst würde die zweite Session vom Rest der ersten „profitieren"
        // oder darunter leiden.
        var policy = UpdateSessionPolicy()

        _ = policy.handle(.userInitiatedCheckStarted)
        _ = policy.handle(.willShowUpdate(userInitiated: true))
        let firstEnd = policy.handle(.sessionFinished)
        #expect(firstEnd.activation == .accessory)
        #expect(firstEnd.dockBadge == .hidden)

        _ = policy.handle(.userInitiatedCheckStarted)
        _ = policy.handle(.willShowUpdate(userInitiated: false))
        let secondEnd = policy.handle(.sessionFinished)
        #expect(secondEnd.activation == .accessory)
        #expect(secondEnd.dockBadge == .hidden)
    }

    @Test func userAttentionReceivedWithoutActiveSessionStaysAccessory() {
        var policy = UpdateSessionPolicy()
        let effect = policy.handle(.userAttentionReceived)
        #expect(effect.activation == .accessory)
        #expect(effect.dockBadge == .hidden)
    }
}
