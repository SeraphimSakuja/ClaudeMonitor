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

    // MARK: - Zeitzonen (SSOT: Pflichtfall „Zeitzonenwechsel")

    @Test("Derselbe Instant in verschiedenen Offsets ergibt denselben Zeitpunkt")
    func timeZoneOffsetsAgree() throws {
        let utc = try #require(ISO8601Parsing.date(from: "2026-08-03T16:50:00.191164+00:00"))
        let newYork = try #require(ISO8601Parsing.date(from: "2026-08-03T11:50:00.191164-05:00"))
        let vienna = try #require(ISO8601Parsing.date(from: "2026-08-03T18:50:00.191164+02:00"))
        #expect(newYork == utc)
        #expect(vienna == utc)
    }

    @Test("Restzeit hängt nicht von der Zeitzone des Geräts ab")
    func remainingIsIndependentOfDeviceTimeZone() throws {
        let reference = try #require(ISO8601Parsing.date(from: "2026-08-03T16:50:00.000+00:00"))
        let base = reference.addingTimeInterval(-3_600)

        let originalDefault = NSTimeZone.default
        defer { NSTimeZone.default = originalDefault }

        var results: [TimeInterval] = []
        for identifier in ["UTC", "America/New_York", "Europe/Vienna", "Pacific/Kiritimati"] {
            NSTimeZone.default = try #require(TimeZone(identifier: identifier))
            // Bewusst neu geparst: Auch das Parsen darf nicht an TimeZone.current hängen.
            let parsed = try #require(ISO8601Parsing.date(from: "2026-08-03T11:50:00.191164-05:00"))
            let window = LimitWindow(
                id: "five_hour", kind: .fiveHour, label: "5h",
                percent: 10, resetsAt: parsed
            )
            let timing = window.resetTiming(now: base)
            results.append(try #require(timing.remainingSeconds))
        }
        #expect(Set(results).count == 1)
        #expect(abs((results.first ?? 0) - 3_600.191) < 0.01)
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
