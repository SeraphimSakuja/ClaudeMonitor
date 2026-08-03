import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Anzeige der Restzeiten. Es darf nie ein negativer Countdown entstehen.
@Suite("Reset-Anzeige")
struct ResetDisplayTests {

    @Test("Reset in der Zukunft läuft live gegen das Reset-Datum")
    func futureResetCountsDown() {
        let until = Fixture.now.addingTimeInterval(3_600)
        let window = Fixture.window(.fiveHour, percent: 20, resetsAt: until)
        #expect(ResetDisplay.make(for: window, now: Fixture.now) == .counting(until: until))
    }

    @Test("Reset in der Vergangenheit ist faellig, kein negativer Countdown")
    func pastResetIsDue() {
        let window = Fixture.window(
            .sevenDay,
            percent: 100,
            resetsAt: Fixture.now.addingTimeInterval(-1)
        )
        let display = ResetDisplay.make(for: window, now: Fixture.now)

        #expect(display == .due)
        if case .counting = display {
            Issue.record("Ein überfälliger Reset darf nie als Countdown erscheinen.")
        }
    }

    @Test("Exakt erreichter Reset gilt als fällig")
    func resetAtExactlyNowIsDue() {
        let window = Fixture.window(.fiveHour, percent: 100, resetsAt: Fixture.now)
        #expect(ResetDisplay.make(for: window, now: Fixture.now) == .due)
    }

    @Test("Ohne Reset-Zeitpunkt bleibt die Anzeige unbekannt")
    func missingResetIsUnknown() {
        let window = Fixture.window(.spend, percent: 20, resetsAt: nil)
        #expect(ResetDisplay.make(for: window, now: Fixture.now) == .unknown)
    }
}
