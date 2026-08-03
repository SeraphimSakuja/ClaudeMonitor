import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("Restzeit — niemals negativ")
struct ResetTimingTests {

    private let now = TestSupport.now

    @Test("Reset in der Zukunft liefert die verbleibende Dauer")
    func future() {
        let timing = ResetTiming(resetsAt: now.addingTimeInterval(3600), now: now)
        #expect(timing == .remaining(3600))
        #expect(timing.remainingSeconds == 3600)
        #expect(timing.isDue == false)
    }

    @Test("Reset in der Vergangenheit ist fällig, nicht negativ")
    func past() {
        let timing = ResetTiming(resetsAt: now.addingTimeInterval(-42), now: now)
        #expect(timing == .due)
        #expect(timing.isDue)
        // Der eigentliche Punkt: keine negative Dauer nach außen.
        #expect(timing.remainingSeconds == 0)
        if case .remaining(let seconds) = timing {
            Issue.record("Vergangener Reset darf keine Restdauer liefern: \(seconds)")
        }
    }

    @Test("Exakt jetzt gilt bereits als fällig")
    func exactlyNow() {
        #expect(ResetTiming(resetsAt: now, now: now) == .due)
    }

    @Test("Fehlendes resets_at ist unbekannt, nicht fällig und nicht 0")
    func missing() {
        let timing = ResetTiming(resetsAt: nil, now: now)
        #expect(timing == .unknown)
        #expect(timing.remainingSeconds == nil)
        #expect(timing.isDue == false)
    }

    @Test("LimitWindow rechnet die Restzeit live aus resets_at")
    func windowTiming() {
        let future = TestSupport.window(.fiveHour, percent: 10, resetsIn: 900)
        #expect(future.resetTiming(now: now) == .remaining(900))

        let overdue = TestSupport.window(.sevenDay, percent: 10, resetsIn: -900)
        #expect(overdue.resetTiming(now: now) == .due)

        let unknown = TestSupport.window(.spend, percent: 10)
        #expect(unknown.resetTiming(now: now) == .unknown)
    }
}
