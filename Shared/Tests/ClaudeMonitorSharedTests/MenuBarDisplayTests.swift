import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Regeln der Kompaktanzeige in der Menüleiste.
@Suite("Menüleisten-Kompaktanzeige")
struct MenuBarDisplayTests {

    @Test("Bester Account liefert Text und Farbe")
    func bestAccountDrivesTextAndColor() {
        let best = Fixture.account(
            id: "1",
            windows: [
                Fixture.window(.fiveHour, percent: 12),
                Fixture.window(.sevenDay, percent: 42.4)
            ]
        )
        let display = MenuBarDisplay.make(for: best)

        #expect(display.text == "42%")
        #expect(display.status == .green)
    }

    @Test("Angezeigt wird die bindende Auslastung, nicht der kleinere Wert")
    func bindingPercentWins() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 5),
                Fixture.window(.sevenDay, percent: 88)
            ]
        )
        let display = MenuBarDisplay.make(for: account)

        #expect(display.text == "88%")
        #expect(display.status == .red)
    }

    @Test("Text und Farbe stammen immer vom selben Fenster")
    func textAndColorNeverDisagree() {
        let percents: [Double] = [0, 49.4, 49.6, 50, 84.9, 85, 99, 100, 130]
        for percent in percents {
            // Das zweite Fenster liegt bei 0 — der geprüfte Wert ist damit
            // immer der Spitzenwert, und Text wie Farbe müssen ihm folgen.
            let account = Fixture.account(
                windows: [
                    Fixture.window(.fiveHour, percent: 0),
                    Fixture.window(.sevenDay, percent: percent)
                ]
            )
            let display = MenuBarDisplay.make(for: account)
            #expect(display.percent == percent)
            #expect(display.status == StatusLevel(percent: percent))
            #expect(display.status == account.overallStatus)
        }
    }

    @Test("Ohne Daten gibt es keinen Prozentwert — und keine 0 %")
    func noDataYieldsNoPercent() {
        let account = Fixture.account(windows: [], fetchedAt: nil, state: .noData)
        let display = MenuBarDisplay.make(for: account)

        #expect(display.percent == nil)
        #expect(display.text == nil)
        #expect(display.status == nil)
        #expect(display.hasValue == false)
        #expect(display.text != "0%")
    }

    @Test("Toter Token zeigt keine eingefrorenen Altwerte")
    func authDeadShowsNoNumbers() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 3)],
            state: .authDead(strikes: 1)
        )
        let display = MenuBarDisplay.make(for: account)

        // Gegen die Regel geprüft, nicht gegen die Konstante `.unavailable`:
        // Der Account trägt einen Altwert im Store — es darf trotzdem weder
        // eine Zahl noch eine Ampelfarbe herauskommen.
        #expect(account.windows.first?.percent == 3)
        #expect(display.percent == nil)
        #expect(display.text == nil)
        #expect(display.text != "3%")
        #expect(display.status == nil)
        #expect(display.hasValue == false)
    }

    @Test("Kein Account ⇒ neutrale Anzeige")
    func noAccountYieldsUnavailable() {
        for display in [
            MenuBarDisplay.make(for: nil),
            MenuBarDisplay.make(for: MonitorViewState(), now: Fixture.now)
        ] {
            // Wieder gegen die Regel: keine Zahl, kein Text, keine Farbe — und
            // ausdrücklich kein „0 %", das Verfügbarkeit vortäuschen würde.
            #expect(display.percent == nil)
            #expect(display.text == nil)
            #expect(display.text != "0%")
            #expect(display.status == nil)
            #expect(display.hasValue == false)
        }
    }

    @Test("Menüleisten-Prozent und Ranking-Maß sind für denselben Account identisch")
    func displayAndRankingMeasureTheSameThing() {
        // Der Fund: Anzeige maß über alle Fenster, das Ranking nur über 5h/7d.
        // Beide lesen jetzt `MonitoredAccount.bindingPercent`.
        let cases: [[LimitWindow]] = [
            [Fixture.window(.fiveHour, percent: 10), Fixture.window(.sevenDay, percent: 10),
             Fixture.window(.scoped(name: "Fable"), percent: 95)],
            [Fixture.window(.fiveHour, percent: 20), Fixture.window(.sevenDay, percent: 20)],
            [Fixture.window(.fiveHour, percent: 5), Fixture.window(.spend, percent: 99)],
            [Fixture.window(.sevenDay, percent: 63)]
        ]
        for windows in cases {
            let account = Fixture.account(windows: windows)
            #expect(MenuBarDisplay.make(for: account).percent == account.bindingPercent)
        }
    }

    @Test("Der oberste Account trägt nie eine schlechtere Ampel als einer darunter")
    func topAccountNeverWorseThanTheOnesBelow() {
        // Reproduziert den gemeldeten Fall: A ist bei 5h/7d entspannt, sein
        // Modellkontingent steht bei 95 %. Vorher rankte A vorne und die
        // Menüleiste zeigte rot 95 %, während der grüne B darunter stand.
        let a = Fixture.account(
            id: "1",
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: 95)
            ]
        )
        let b = Fixture.account(
            id: "2",
            windows: [
                Fixture.window(.fiveHour, percent: 20),
                Fixture.window(.sevenDay, percent: 20)
            ]
        )
        let state = MonitorViewState(snapshot: Fixture.snapshot([a, b]), isLoading: false)
        let ranked = state.accounts(now: Fixture.now)

        #expect(ranked.map(\.id) == ["2", "1"])
        #expect(MenuBarDisplay.make(for: state, now: Fixture.now).text == "20%")
        #expect(MenuBarDisplay.make(for: state, now: Fixture.now).status == .green)

        // Die eigentliche Zusage: monoton nicht besser werdend von oben nach unten.
        let percents = ranked.compactMap { MenuBarDisplay.make(for: $0).percent }
        #expect(percents == percents.sorted())
    }

    @Test("Formatvorschrift: kaufmännisch gerundet, ohne Nachkommastellen")
    func percentFormatting() {
        #expect(PercentFormatting.compact(0) == "0%")
        #expect(PercentFormatting.compact(49.4) == "49%")
        #expect(PercentFormatting.compact(49.5) == "50%")
        #expect(PercentFormatting.compact(100) == "100%")
        #expect(PercentFormatting.compact(.nan) == nil)
        #expect(PercentFormatting.compact(.infinity) == nil)
        #expect(PercentFormatting.compact(-5) == "0%")
    }

    @Test("Fortschrittsanteil bleibt zwischen 0 und 1")
    func fractionIsClamped() {
        #expect(PercentFormatting.fraction(50) == 0.5)
        #expect(PercentFormatting.fraction(180) == 1)
        #expect(PercentFormatting.fraction(-3) == 0)
        #expect(PercentFormatting.fraction(.nan) == nil)
    }

    @Test("Die Anzeige folgt dem gerankten ersten Account")
    func displayFollowsRanking() {
        let busy = Fixture.account(
            id: "1",
            windows: [Fixture.window(.fiveHour, percent: 95), Fixture.window(.sevenDay, percent: 95)]
        )
        let free = Fixture.account(
            id: "2",
            windows: [Fixture.window(.fiveHour, percent: 10), Fixture.window(.sevenDay, percent: 10)]
        )
        let state = MonitorViewState(snapshot: Fixture.snapshot([busy, free]), isLoading: false)

        #expect(state.bestAccount(now: Fixture.now)?.id == "2")
        #expect(MenuBarDisplay.make(for: state, now: Fixture.now).text == "10%")
    }
}
