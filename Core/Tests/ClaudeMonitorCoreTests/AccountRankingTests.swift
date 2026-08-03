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

    @Test("Bei gleichen Prozentwerten gewinnt der frühere Reset — die längere Restzeit ist kein Vorteil")
    func tiebreakEarliestReset() {
        let accounts = [
            // „a" hat die längere Gesamt-Restzeit (86.400 s), füllt sich aber
            // später wieder auf. Genau das war das gestrichene Gegenkriterium.
            TestSupport.account("a", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 3_000, sevenDayResetsIn: 86_400),
            TestSupport.account("b", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 3_600)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Frühester Reset schlägt die längere Gesamtlaufzeit auch bei identischem Maximum")
    func earliestResetBeatsLongestRemaining() {
        let accounts = [
            TestSupport.account("a", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 3_000, sevenDayResetsIn: 86_400),
            TestSupport.account("b", fiveHour: 40, sevenDay: 40,
                                fiveHourResetsIn: 600, sevenDayResetsIn: 86_400)
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    // MARK: - Blockierte Accounts (F4)

    @Test("Account mit ausgeschöpftem Fenster rutscht hinter einen schlechteren, aber freien Account")
    func blockedAccountRanksBehindFreeOne() {
        // Der reale Fall: #1 hat die bessere 5h-Zahl, ist aber wegen 7d = 100 %
        // für 70 Stunden unbrauchbar. #2 ist bei 5h am Limit, füllt sich aber
        // in drei Stunden wieder auf.
        let blocked = TestSupport.account("1", fiveHour: 49, sevenDay: 100,
                                          fiveHourResetsIn: 3_600,
                                          sevenDayResetsIn: 70 * 3_600)
        let free = TestSupport.account("2", fiveHour: 99, sevenDay: 89,
                                       fiveHourResetsIn: 3 * 3_600,
                                       sevenDayResetsIn: 4 * 86_400)
        #expect(AccountRanking.ranked([blocked, free], now: now).map(\.id) == ["2", "1"])
    }

    @Test("Blockiert ist auch, wer nur in einem Nebenfenster auf 100 % steht")
    func blockedByScopedWindow() {
        let blocked = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [
                TestSupport.window(.fiveHour, percent: 1, resetsIn: 600),
                TestSupport.window(.scoped(name: "Fable"), percent: 100, resetsIn: 600)
            ],
            fetchedAt: now,
            state: .ok
        )
        let free = TestSupport.account("b", fiveHour: 95, sevenDay: 95, fiveHourResetsIn: 600)
        #expect(AccountRanking.ranked([blocked, free], now: now).map(\.id) == ["b", "a"])
    }

    @Test("Blockierte Accounts stehen vor den datenlosen und werden untereinander normal sortiert")
    func blockedRanksAheadOfNoData() {
        let accounts = [
            TestSupport.accountWithoutData("a-nodata", state: .noData),
            TestSupport.account("b-blocked-high", fiveHour: 100, sevenDay: 100, fiveHourResetsIn: 600),
            TestSupport.account("c-blocked-low", fiveHour: 100, sevenDay: 10, fiveHourResetsIn: 600),
            TestSupport.account("d-free", fiveHour: 99, sevenDay: 99, fiveHourResetsIn: 600)
        ]
        #expect(
            AccountRanking.ranked(accounts, now: now).map(\.id)
                == ["d-free", "c-blocked-low", "b-blocked-high", "a-nodata"]
        )
    }

    @Test("99,9 % ist noch nicht blockiert, 100 % ist es")
    func blockedThresholdBoundary() {
        let almost = TestSupport.account("a", fiveHour: 99.9, sevenDay: 10, fiveHourResetsIn: 600)
        let atLimit = TestSupport.account("b", fiveHour: 100, sevenDay: 10, fiveHourResetsIn: 600)
        #expect(AccountRanking.availabilityRank(for: almost, usable: true) == 0)
        #expect(AccountRanking.availabilityRank(for: atLimit, usable: true) == 1)
        #expect(AccountRanking.ranked([atLimit, almost], now: now).map(\.id) == ["a", "b"])
    }

    // MARK: - Sentinel und Ordnungseigenschaften

    @Test("Account ohne jeden bekannten Reset sortiert hinter einen mit Reset")
    func unknownResetSortsLast() {
        let withoutReset = TestSupport.account("a", fiveHour: 40, sevenDay: 40)
        let withReset = TestSupport.account("z", fiveHour: 40, sevenDay: 40,
                                            fiveHourResetsIn: 86_400 * 30)
        #expect(AccountRanking.key(for: withoutReset, now: now).earliestReset
                == AccountRanking.worstSortValue)
        #expect(AccountRanking.ranked([withoutReset, withReset], now: now).map(\.id) == ["z", "a"])
    }

    @Test("Das Sortierprädikat ist eine strikte schwache Ordnung")
    func strictWeakOrdering() {
        var keys: [AccountRanking.Key] = []
        for rank in [0, 1, 2] {
            for five in [10.0, 40.0, AccountRanking.worstSortValue] {
                for seven in [10.0, 40.0] {
                    for reset in [600.0, 3_600.0, AccountRanking.worstSortValue] {
                        for id in ["a", "b", "10", "2"] {
                            keys.append(
                                AccountRanking.Key(
                                    availabilityRank: rank,
                                    fiveHourPercent: five,
                                    sevenDayPercent: seven,
                                    earliestReset: reset,
                                    identifier: id
                                )
                            )
                        }
                    }
                }
            }
        }
        let before = AccountRanking.isOrderedBefore

        // Irreflexiv und asymmetrisch.
        for a in keys {
            #expect(before(a, a) == false)
            for b in keys where before(a, b) {
                #expect(before(b, a) == false)
            }
        }

        // Transitivität und transitive Gleichrangigkeit auf einer Stichprobe.
        let sample = stride(from: 0, to: keys.count, by: 7).map { keys[$0] }
        for a in sample {
            for b in sample {
                for c in sample {
                    if before(a, b), before(b, c) { #expect(before(a, c)) }
                    let abEquiv = !before(a, b) && !before(b, a)
                    let bcEquiv = !before(b, c) && !before(c, b)
                    if abEquiv, bcEquiv {
                        #expect(!before(a, c) && !before(c, a))
                    }
                }
            }
        }
    }

    @Test("Kennungen werden natürlich-numerisch sortiert, nicht lexikografisch")
    func naturalIdentifierOrder() {
        let accounts = (1...11).map {
            TestSupport.account("\($0)", fiveHour: 40, sevenDay: 40, fiveHourResetsIn: 600)
        }
        #expect(
            AccountRanking.ranked(accounts.shuffled(), now: now).map(\.id)
                == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]
        )
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
