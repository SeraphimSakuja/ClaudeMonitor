import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Abbildung der Pflicht-Zustände auf die Statuszeile.
@Suite("Zustands-Abbildung der Accounts")
struct AccountStatusLineTests {

    @Test("Kein last_good ergibt den Zustand ohne Daten, nicht 0 %")
    func noDataIsItsOwnState() {
        let account = Fixture.account(windows: [], fetchedAt: nil, state: .noData)
        #expect(AccountStatusLine.make(for: account, now: Fixture.now) == .noData)
        #expect(MenuBarDisplay.make(for: account).text == nil)
    }

    @Test("Toter Token ⇒ Neuanmeldung nötig")
    func authDeadRequiresReLogin() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            state: .authDead(strikes: 2)
        )
        #expect(AccountStatusLine.make(for: account, now: Fixture.now) == .reLoginRequired(strikes: 2))
    }

    @Test("Laufender Backoff ⇒ Pause mit Zielzeitpunkt")
    func backoffIsShownAsPause() {
        let until = Fixture.now.addingTimeInterval(90)
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            state: .backoff(until: until)
        )
        #expect(AccountStatusLine.make(for: account, now: Fixture.now) == .paused(until: until))
    }

    @Test("Abgelaufener Backoff ist keine Pause mehr")
    func expiredBackoffFallsBackToFreshness() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            fetchedAt: Fixture.now.addingTimeInterval(-10),
            state: .backoff(until: Fixture.now.addingTimeInterval(-5))
        )
        #expect(AccountStatusLine.make(for: account, now: Fixture.now) == .upToDate)
    }

    @Test("Fehlversuch wird als solcher gemeldet")
    func failingIsReported() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            state: .failing(message: "timeout")
        )
        #expect(AccountStatusLine.make(for: account, now: Fixture.now) == .fetchFailed(message: "timeout"))
    }

    @Test("Alte Daten gelten als veraltet — mit Altersangabe")
    func staleDataCarriesItsAge() {
        let age = AccountStatusLine.staleThreshold + 60
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            fetchedAt: Fixture.now.addingTimeInterval(-age)
        )
        #expect(AccountStatusLine.make(for: account, now: Fixture.now) == .stale(age: age))
    }

    @Test("Frische Daten sind keine Warnung")
    func freshDataIsNotAWarning() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            fetchedAt: Fixture.now.addingTimeInterval(-30)
        )
        let line = AccountStatusLine.make(for: account, now: Fixture.now)
        #expect(line == .upToDate)
        #expect(line.isWarning == false)
    }

    @Test("Alle Ausnahmezustände sind Warnungen")
    func exceptionalStatesAreWarnings() {
        let lines: [AccountStatusLine] = [
            .noData,
            .reLoginRequired(strikes: 1),
            .paused(until: Fixture.now),
            .fetchFailed(message: "x"),
            .stale(age: 999)
        ]
        for line in lines { #expect(line.isWarning) }
    }

    @Test("Der gravierendste Zustand gewinnt")
    func severityOrderIsRespected() {
        // Toter Token schlägt „veraltet": Ein beruhigendes „nur alt" über einem
        // toten Token wäre irreführend.
        let dead = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            fetchedAt: Fixture.now.addingTimeInterval(-100_000),
            state: .authDead(strikes: 1)
        )
        #expect(AccountStatusLine.make(for: dead, now: Fixture.now) == .reLoginRequired(strikes: 1))
    }
}
