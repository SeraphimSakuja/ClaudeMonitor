import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("AccountRanking — bester Account zuerst")
struct AccountRankingTests {

    private let now = TestSupport.now

    @Test("Sortiert primär nach niedrigster 5-Stunden-Auslastung")
    func sortsByFiveHour() {
        let accounts = [
            TestSupport.account("b", fiveHour: 80, sevenDay: 10),
            TestSupport.account("a", fiveHour: 20, sevenDay: 90),
            TestSupport.account("c", fiveHour: 50, sevenDay: 50)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["a", "c", "b"])
    }

    @Test("Bei gleicher 5h-Auslastung entscheidet die Wochen-Auslastung")
    func tiebreakSevenDay() {
        let accounts = [
            TestSupport.account("a", fiveHour: 40, sevenDay: 70),
            TestSupport.account("b", fiveHour: 40, sevenDay: 10)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Bei gleichen Prozentwerten gewinnt die längste verbleibende Nutzungsdauer")
    func tiebreakLongestRemaining() {
        let accounts = [
            TestSupport.account("a", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 3_600),
            TestSupport.account("b", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 86_400)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Bei gleicher längster Restzeit gewinnt der frühere Reset")
    func tiebreakEarliestReset() {
        let accounts = [
            TestSupport.account("a", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 3_000, sevenDayResetsIn: 86_400),
            TestSupport.account("b", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 86_400)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Völliger Gleichstand wird über die Kennung deterministisch aufgelöst")
    func tiebreakIdentifier() {
        let accounts = [
            TestSupport.account("z", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 86_400),
            TestSupport.account("m", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 86_400),
            TestSupport.account("a", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 86_400)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["a", "m", "z"])
        // Ergebnis darf nicht von der Eingabereihenfolge abhängen.
        #expect(AccountRanking.ranked(accounts.reversed(), now: now).map(\.id) == ["a", "m", "z"])
    }

    @Test("Accounts ohne verwertbare Daten stehen immer hinten — nie als bester Account")
    func accountsWithoutDataGoLast() {
        let accounts = [
            TestSupport.accountWithoutData("aaa-nodata", state: .noData),
            TestSupport.accountWithoutData("aab-dead", state: .authDead(strikes: 3)),
            TestSupport.account("zzz-usable", fiveHour: 99, sevenDay: 99)
        ]
        let ranked = AccountRanking.ranked(accounts, now: now)
        #expect(ranked.first?.id == "zzz-usable")
        #expect(Set(ranked.suffix(2).map(\.id)) == ["aaa-nodata", "aab-dead"])
    }

    @Test("Toter Token verdrängt nicht den besten Account, auch mit 0 % im Store")
    func deadTokenNeverBest() {
        let dead = MonitoredAccount(
            id: "a-dead",
            displayName: "dead@example.com",
            windows: [TestSupport.window(.fiveHour, percent: 0, resetsIn: 600)],
            fetchedAt: now,
            state: .authDead(strikes: 3)
        )
        let usable = TestSupport.account("b", fiveHour: 70, sevenDay: 70, fiveHourResetsIn: 600)
        #expect(AccountRanking.ranked([dead, usable], now: now).map(\.id) == ["b", "a-dead"])
    }

    @Test("Backoff und Fehlversuch schließen einen Account nicht aus")
    func backoffStaysRankable() {
        let accounts = [
            TestSupport.account("a", fiveHour: 90, sevenDay: 10, state: .ok),
            TestSupport.account("b", fiveHour: 10, sevenDay: 10,
                                state: .backoff(until: now.addingTimeInterval(60))),
            TestSupport.account("c", fiveHour: 20, sevenDay: 10,
                                state: .failing(message: "http 500"))
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "c", "a"])
    }

    @Test("Fehlendes 5h-Fenster zählt als maximal ausgelastet")
    func missingWindowRanksWorst() {
        let withoutFiveHour = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [TestSupport.window(.sevenDay, percent: 1, resetsIn: 600)],
            fetchedAt: now,
            state: .ok
        )
        let withFiveHour = TestSupport.account("b", fiveHour: 95, sevenDay: 95, fiveHourResetsIn: 600)
        #expect(AccountRanking.ranked([withoutFiveHour, withFiveHour], now: now).map(\.id) == ["b", "a"])
    }

    @Test("Ranking ist wiederholbar und unabhängig von der Eingabereihenfolge")
    func deterministic() {
        let accounts = [
            TestSupport.account("a", fiveHour: 10, sevenDay: 10, fiveHourResetsIn: 600),
            TestSupport.account("b", fiveHour: 10, sevenDay: 10, fiveHourResetsIn: 600),
            TestSupport.account("c", fiveHour: 10, sevenDay: 20, fiveHourResetsIn: 600),
            TestSupport.accountWithoutData("d")
        ]
        let expected = AccountRanking.ranked(accounts, now: now).map(\.id)
        for _ in 0..<20 {
            #expect(AccountRanking.ranked(accounts.shuffled(), now: now).map(\.id) == expected)
        }
        #expect(expected == ["a", "b", "c", "d"])
    }

    @Test("Snapshot reicht das Ranking durch")
    func snapshotRanking() {
        let snapshot = AccountsSnapshot(
            accounts: [
                TestSupport.account("b", fiveHour: 90, sevenDay: 10),
                TestSupport.account("a", fiveHour: 10, sevenDay: 10)
            ],
            capturedAt: now,
            sourceSchemaVersion: ClaudeMonitorCore.supportedSchemaVersion
        )
        #expect(snapshot.rankedAccounts(now: now).map(\.id) == ["a", "b"])
    }
}
