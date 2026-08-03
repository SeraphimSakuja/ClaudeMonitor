import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("AccountRanking — bester Account zuerst")
struct AccountRankingTests {

    private let now = TestSupport.now

    @Test("Sortiert primär nach der bindenden Auslastung — dem schlechteren der beiden Limits")
    func sortsByBindingUtilization() {
        let accounts = [
            TestSupport.account("b", fiveHour: 80, sevenDay: 10),   // bindend: 80
            TestSupport.account("a", fiveHour: 20, sevenDay: 90),   // bindend: 90
            TestSupport.account("c", fiveHour: 50, sevenDay: 50)    // bindend: 50
        ]
        // Nach der alten 5h-Kaskade wäre „a" (20 %) vorne gewesen.
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["c", "b", "a"])
        #expect(AccountRanking.bindingPercent(for: accounts[1], usable: true) == 90)
    }

    @Test("Der bessere 5h-Wert nützt nichts, wenn das Wochenlimit schlechter ist")
    func weeklyLimitCanOutweighFiveHour() {
        let accounts = [
            TestSupport.account("a", fiveHour: 5, sevenDay: 95),    // bindend: 95
            TestSupport.account("b", fiveHour: 60, sevenDay: 60)    // bindend: 60
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Bei gleichem 5h-Wert entscheidet das Wochenlimit — es ist dann das bindende")
    func tiebreakSevenDay() {
        let accounts = [
            TestSupport.account("a", fiveHour: 40, sevenDay: 70),   // bindend: 70
            TestSupport.account("b", fiveHour: 40, sevenDay: 10)    // bindend: 40
        ]
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Realfall: 5h 49 % / 7d 100 % verliert gegen 5h 100 % / 7d 89 % mit frühem Reset")
    func realWorldCaseWeeklyExhausted() {
        // Beobachtet an echten Daten: #1 ist wegen des Wochenlimits ~70 Stunden
        // unbrauchbar, #2 füllt sein 5h-Fenster in drei Stunden wieder auf.
        // Ein Durchschnitt (74,5 gegen 94,5) hätte #1 empfohlen — max() macht
        // beide zu 100 und lässt den früheren Reset entscheiden.
        let first = TestSupport.account("1", fiveHour: 49, sevenDay: 100,
                                        fiveHourResetsIn: 2 * 3_600,
                                        sevenDayResetsIn: 70 * 3_600)
        let second = TestSupport.account("2", fiveHour: 100, sevenDay: 89,
                                         fiveHourResetsIn: 3 * 3_600,
                                         sevenDayResetsIn: 4 * 86_400)
        #expect(AccountRanking.bindingPercent(for: first, usable: true) == 100)
        #expect(AccountRanking.bindingPercent(for: second, usable: true) == 100)
        #expect(AccountRanking.ranked([first, second], now: now).map(\.id) == ["2", "1"])
    }

    @Test("Maßgeblich ist der Reset des Engpass-Fensters, nicht der früheste überhaupt")
    func bottleneckResetNotEarliestOverall() {
        // Das 5h-Fenster wird in 10 Minuten zurückgesetzt — das hilft nicht,
        // solange das Wochenlimit bei 100 % steht und erst in 70 Stunden fällt.
        let account = TestSupport.account("a", fiveHour: 49, sevenDay: 100,
                                          fiveHourResetsIn: 600,
                                          sevenDayResetsIn: 70 * 3_600)
        #expect(AccountRanking.bottleneckReset(for: account, now: now) == 70 * 3_600)

        let unknown = TestSupport.account("b", fiveHour: 49, sevenDay: 100,
                                          fiveHourResetsIn: 600)
        #expect(AccountRanking.bottleneckReset(for: unknown, now: now)
                == AccountRanking.worstSortValue)
    }

    @Test("Bei gleicher bindender Auslastung entscheidet der frühere Reset")
    func equalBindingDecidedByEarliestReset() {
        let accounts = [
            TestSupport.account("a", fiveHour: 30, sevenDay: 70,
                                fiveHourResetsIn: 7_200, sevenDayResetsIn: 86_400),
            TestSupport.account("b", fiveHour: 70, sevenDay: 30,
                                fiveHourResetsIn: 900, sevenDayResetsIn: 86_400)
        ]
        // Beide bindend bei 70 — unterschiedlich verteilt, aber gleich bewertet.
        #expect(AccountRanking.bindingPercent(for: accounts[0], usable: true) == 70)
        #expect(AccountRanking.bindingPercent(for: accounts[1], usable: true) == 70)
        #expect(AccountRanking.ranked(accounts, now: now).map(\.id) == ["b", "a"])
    }

    @Test("Der oberste Account trägt nie ein rotes Ampelsignal, wenn ein grüner verfügbar ist")
    func topAccountMatchesTrafficLight() {
        let accounts = [
            TestSupport.account("a", fiveHour: 10, sevenDay: 95, fiveHourResetsIn: 600),
            TestSupport.account("b", fiveHour: 40, sevenDay: 40, fiveHourResetsIn: 600)
        ]
        let best = AccountRanking.ranked(accounts, now: now).first
        #expect(best?.id == "b")
        #expect(best?.overallStatus == .green)
        #expect(accounts[0].overallStatus == .red)
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
                // 5h und 7d sind bestens — nur das Modellkontingent ist leer.
                // Sowohl der Verfügbarkeitsrang als auch die bindende
                // Auslastung sehen dieses Fenster.
                TestSupport.window(.fiveHour, percent: 1, resetsIn: 600),
                TestSupport.window(.sevenDay, percent: 2, resetsIn: 600),
                TestSupport.window(.scoped(name: "Fable"), percent: 100, resetsIn: 600)
            ],
            fetchedAt: now,
            state: .ok
        )
        let free = TestSupport.account("b", fiveHour: 95, sevenDay: 95, fiveHourResetsIn: 600)
        #expect(AccountRanking.ranked([blocked, free], now: now).map(\.id) == ["b", "a"])
    }

    @Test("Ein erschöpftes Nebenfenster rankt den Account hinter einen schwächeren — Anzeige und Ranking messen dasselbe")
    func scopedWindowDrivesBindingPercentAndRanking() {
        // Der gemeldete Fund: A hat 5h 10 % / 7d 10 %, aber sein
        // Modellkontingent steht bei 95 %. B liegt überall bei 20 %.
        // Solange die bindende Auslastung nur max(5h, 7d) war, rankte A vorne
        // (10 < 20) — während die Menüleiste für A rot „95 %" zeigte und der
        // grüne B darunter stand.
        let a = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [
                TestSupport.window(.fiveHour, percent: 10, resetsIn: 600),
                TestSupport.window(.sevenDay, percent: 10, resetsIn: 600),
                TestSupport.window(.scoped(name: "Fable"), percent: 95, resetsIn: 600)
            ],
            fetchedAt: now,
            state: .ok
        )
        let b = TestSupport.account("b", fiveHour: 20, sevenDay: 20, fiveHourResetsIn: 600)

        #expect(AccountRanking.bindingPercent(for: a, usable: true) == 95)
        #expect(AccountRanking.bindingPercent(for: b, usable: true) == 20)
        #expect(AccountRanking.ranked([a, b], now: now).map(\.id) == ["b", "a"])
        // Kein rotes Signal über einem grünen: Der oberste Account hat nie die
        // schlechtere Ampelstufe als einer darunter.
        let statuses = AccountRanking.ranked([a, b], now: now).compactMap(\.overallStatus)
        #expect(statuses == [.green, .red])
    }

    @Test("Auch das Ausgabenbudget bindet — nicht nur 5h und 7d")
    func spendWindowDrivesBindingPercent() {
        let account = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [
                TestSupport.window(.fiveHour, percent: 3, resetsIn: 600),
                TestSupport.window(.sevenDay, percent: 4, resetsIn: 600),
                TestSupport.window(.spend, percent: 88, resetsIn: 600)
            ],
            fetchedAt: now,
            state: .ok
        )
        #expect(AccountRanking.bindingPercent(for: account, usable: true) == 88)
        #expect(account.bindingPercent == 88)
    }

    @Test("Blockierte Accounts stehen vor den datenlosen und werden untereinander normal sortiert")
    func blockedRanksAheadOfNoData() {
        let accounts = [
            TestSupport.accountWithoutData("a-nodata", state: .noData),
            // Beide blockiert und bindend bei 100 — der frühere Reset entscheidet.
            TestSupport.account("b-blocked-late", fiveHour: 100, sevenDay: 100, fiveHourResetsIn: 3_600),
            TestSupport.account("c-blocked-early", fiveHour: 100, sevenDay: 10, fiveHourResetsIn: 600),
            TestSupport.account("d-free", fiveHour: 99, sevenDay: 99, fiveHourResetsIn: 600)
        ]
        #expect(
            AccountRanking.ranked(accounts, now: now).map(\.id)
                == ["d-free", "c-blocked-early", "b-blocked-late", "a-nodata"]
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
            for binding in [10.0, 40.0, 100.0, AccountRanking.worstSortValue] {
                for reset in [0.0, 600.0, 3_600.0, AccountRanking.worstSortValue] {
                    for id in ["a", "b", "10", "2"] {
                        keys.append(
                            AccountRanking.Key(
                                availabilityRank: rank,
                                bindingPercent: binding,
                                earliestReset: reset,
                                identifier: id
                            )
                        )
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

    @Test("Ohne jedes Fenster zählt ein Account als maximal ausgelastet")
    func accountWithoutAnyWindowRanksWorst() {
        let withoutWindows = TestSupport.accountWithoutData("a")
        let busy = TestSupport.account("b", fiveHour: 95, sevenDay: 95, fiveHourResetsIn: 600)
        #expect(AccountRanking.bindingPercent(for: withoutWindows, usable: withoutWindows.hasUsableData)
                == AccountRanking.worstSortValue)
        #expect(AccountRanking.ranked([withoutWindows, busy], now: now).map(\.id) == ["b", "a"])
    }

    @Test("Ein Account wird nach den Fenstern bewertet, die er meldet — nicht nach den fehlenden")
    func partialWindowSetIsJudgedByWhatIsReported() {
        // Bewusste Semantik seit der Umstellung auf „Maximum über alle
        // Fenster": Meldet die Quelle für einen Account kein 5h-Fenster, wird
        // er nach seinem 7d-Fenster bewertet. Andernfalls wichen Ranking und
        // Menüleisten-Anzeige wieder voneinander ab — die Anzeige zeigt für
        // diesen Account „1 %", das Ranking dürfte ihn dann nicht als
        // ausgeschöpft behandeln.
        let sevenDayOnly = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [TestSupport.window(.sevenDay, percent: 1, resetsIn: 600)],
            fetchedAt: now,
            state: .ok
        )
        let busy = TestSupport.account("b", fiveHour: 95, sevenDay: 95, fiveHourResetsIn: 600)
        #expect(AccountRanking.bindingPercent(for: sevenDayOnly, usable: true) == 1)
        #expect(sevenDayOnly.bindingPercent == 1)
        #expect(AccountRanking.ranked([busy, sevenDayOnly], now: now).map(\.id) == ["a", "b"])
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
