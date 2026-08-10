import Testing
import ClaudeMonitorShared

/// Die Regel hinter dem Update-Knopf (CM-11).
///
/// Der Test, der wirklich zählt, ist
/// ``neverReadyIsADefectNotARunningCheck``: Genau diese Kombination —
/// `canCheckForUpdates == false` bei einem Updater, der nie bereit war — ist der
/// gemeldete Fehlerzustand. Bildete man sie auf ``UpdateButtonState/checking``
/// ab, behauptete die App eine Prüfung, die nie stattfindet, und der Knopf
/// bliebe für immer grau mit einer beruhigenden Lüge darunter.
@Suite("Update-Knopf-Zustand")
struct UpdateAvailabilityTests {

    @Test func readyWhenSparkleAllowsAcheck() {
        #expect(UpdateAvailability.state(canCheckForUpdates: true, hasEverBeenReady: true) == .ready)
    }

    @Test func readyEvenOnTheVeryFirstReadiness() {
        // `hasEverBeenReady` wird erst durch dieses `true` gesetzt; die Regel
        // darf nicht auf ein Flag warten, das sie selbst erst auslöst.
        #expect(UpdateAvailability.state(canCheckForUpdates: false, hasEverBeenReady: false) != .ready)
        #expect(UpdateAvailability.state(canCheckForUpdates: true, hasEverBeenReady: false) == .ready)
    }

    @Test func blockedAfterHavingBeenReadyMeansACheckIsRunning() {
        // Sparkle sperrt die Prüfung, solange eine läuft oder eine Installation
        // aussteht. Das ist kein Defekt und darf nicht als einer aussehen.
        #expect(UpdateAvailability.state(canCheckForUpdates: false, hasEverBeenReady: true) == .checking)
    }

    @Test func neverReadyIsADefectNotARunningCheck() {
        let state = UpdateAvailability.state(canCheckForUpdates: false, hasEverBeenReady: false)
        #expect(state == .unavailable)
        // Ausdrücklich: nicht `.checking`. Ein nie gestarteter Updater prüft
        // nichts, und ein Neustart ist der einzige Ausweg.
        #expect(state != .checking)
    }

    @Test func onlyReadyEnablesTheButton() {
        // Die Oberfläche schaltet den Knopf an genau einem Zustand frei; die
        // beiden anderen müssen sich unterscheiden lassen, weil sie
        // unterschiedliche Erklärungen tragen.
        #expect(UpdateButtonState.checking != UpdateButtonState.unavailable)
        #expect(UpdateAvailability.state(canCheckForUpdates: true, hasEverBeenReady: false) == .ready)
        #expect(UpdateAvailability.state(canCheckForUpdates: false, hasEverBeenReady: true) != .ready)
        #expect(UpdateAvailability.state(canCheckForUpdates: false, hasEverBeenReady: false) != .ready)
    }
}
