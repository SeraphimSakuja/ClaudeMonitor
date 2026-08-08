import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Regeln der Kompaktanzeige in der Menüleiste.
@Suite("Menüleisten-Kompaktanzeige")
struct MenuBarDisplayTests {

    // MARK: - Helfer

    /// Schlechteste Ampelstufe über alle Punkte eines Segments; `nil`, wenn
    /// kein Punkt eine Farbe trägt.
    private func worstStatus(in segment: MenuBarDisplay.AccountSegment) -> StatusLevel? {
        let ranks: [StatusLevel: Int] = [.green: 0, .yellow: 1, .red: 2]
        return segment.values.compactMap(\.status).max { (ranks[$0] ?? 0) < (ranks[$1] ?? 0) }
    }

    private func state(_ accounts: [MonitoredAccount]) -> MonitorViewState {
        MonitorViewState(snapshot: Fixture.snapshot(accounts), isLoading: false)
    }

    // MARK: - Die Zahl eines Accounts (früher MenuBarDisplay, jetzt AccountBindingDisplay)

    @Test("Bester Account liefert Text und Farbe")
    func bestAccountDrivesTextAndColor() {
        let best = Fixture.account(
            id: "1",
            windows: [
                Fixture.window(.fiveHour, percent: 12),
                Fixture.window(.sevenDay, percent: 42.4)
            ]
        )
        let binding = AccountBindingDisplay.make(for: best)

        #expect(binding.text == "42%")
        #expect(binding.status == .green)

        // Und in der Leiste stehen beide Fenster mit je eigener Zahl.
        let segment = MenuBarDisplay.segment(for: best)
        #expect(segment.values.map(\.text) == ["12%", "42%"])
    }

    @Test("Angezeigt wird die bindende Auslastung, nicht der kleinere Wert")
    func bindingPercentWins() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 5),
                Fixture.window(.sevenDay, percent: 88)
            ]
        )
        let binding = AccountBindingDisplay.make(for: account)

        #expect(binding.text == "88%")
        #expect(binding.status == .red)
        #expect(MenuBarDisplay.segment(for: account).binding?.text == "88%")
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
            let binding = AccountBindingDisplay.make(for: account)
            #expect(binding.percent == percent)
            #expect(binding.status == StatusLevel(percent: percent))
            #expect(binding.status == account.overallStatus)

            let segment = MenuBarDisplay.segment(for: account)
            #expect(segment.values[1].percent == percent)
            #expect(segment.values[1].status == StatusLevel(percent: percent))
        }
    }

    @Test("Zahl und Farbe eines Punktes stammen aus demselben Fenster, nicht vom Account")
    func everyPointReadsItsOwnWindow() {
        // Der Account ist insgesamt rot (7 d bei 90). Der 5-h-Punkt muss
        // trotzdem grün bleiben — sonst stünde ein roter Punkt neben „10 %".
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 90)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(account.overallStatus == .red)
        #expect(segment.values[0].text == "10%")
        #expect(segment.values[0].status == .green)
        #expect(segment.values[1].text == "90%")
        #expect(segment.values[1].status == .red)
    }

    // MARK: - Kein verwertbarer Datenstand

    @Test("Ohne Daten gibt es keinen Prozentwert — und keine 0 %")
    func noDataYieldsNoPercent() {
        let account = Fixture.account(windows: [], fetchedAt: nil, state: .noData)
        let binding = AccountBindingDisplay.make(for: account)

        #expect(binding.percent == nil)
        #expect(binding.text == nil)
        #expect(binding.status == nil)
        #expect(binding.hasValue == false)
        #expect(binding.text != "0%")

        // In der Leiste ebenso: weder Zahl noch Farbe, ausdrücklich kein „0 %".
        let segment = MenuBarDisplay.segment(for: account)
        #expect(segment.values.allSatisfy { $0.reading == .unavailable })
        #expect(segment.values.allSatisfy { $0.text == nil })
        #expect(segment.values.allSatisfy { $0.status == nil })
        #expect(segment.values.contains { $0.text == "0%" } == false)
    }

    @Test("Toter Token zeigt keine eingefrorenen Altwerte")
    func authDeadShowsNoNumbers() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 3),
                Fixture.window(.scoped(name: "Fable"), percent: 95)
            ],
            state: .authDead(strikes: 1)
        )

        // Gegen die Regel geprüft, nicht gegen die Konstante `.unavailable`:
        // Der Account trägt Altwerte im Store — es darf trotzdem weder eine
        // Zahl noch eine Ampelfarbe herauskommen.
        #expect(account.windows.first?.percent == 3)

        let binding = AccountBindingDisplay.make(for: account)
        #expect(binding.percent == nil)
        #expect(binding.text == nil)
        #expect(binding.text != "3%")
        #expect(binding.status == nil)
        #expect(binding.hasValue == false)

        let segment = MenuBarDisplay.segment(for: account)
        #expect(segment.values.allSatisfy { $0.text == nil })
        // Regel 7: nirgends eine Farbe — und kein Zusatzpunkt für die 95 %.
        #expect(segment.values.allSatisfy { $0.status == nil })
        #expect(segment.values.count == MenuBarDisplay.visibleKinds.count)
        #expect(segment.values.contains { $0.kind == .scoped(name: "Fable") } == false)
    }

    @Test("Kein Account ⇒ neutrale Anzeige")
    func noAccountYieldsUnavailable() {
        for mode in MenuBarMode.allCases {
            let display = MenuBarDisplay.make(for: MonitorViewState(), mode: mode, now: Fixture.now)
            // Wieder gegen die Regel: keine Zahl, kein Text, keine Farbe — und
            // ausdrücklich kein „0 %", das Verfügbarkeit vortäuschen würde.
            #expect(display.segments.isEmpty)
            #expect(display == .unavailable)
            #expect(display.hasMoreAccounts == false)
        }
        // Gegen die Regel geprüft, nicht gegen die Konstante: Ein Vergleich mit
        // `.unavailable` allein bliebe auch dann grün, wenn die Konstante auf
        // `percent: 0, status: .green` mutiert würde.
        let binding = AccountBindingDisplay.make(for: nil)
        #expect(binding.percent == nil)
        #expect(binding.text == nil)
        #expect(binding.text != "0%")
        #expect(binding.status == nil)
        #expect(binding.hasValue == false)
        #expect(binding == .unavailable)
    }

    @Test("Nur datenlose Accounts ⇒ leere Leiste statt stummer Punkte")
    func allWithoutDataCollapsesToNothing() {
        // Ohne diese Regel stünde beim Erststart `● ● │ ● ●` ohne jede Aussage.
        let accounts = [
            Fixture.account(id: "1", windows: [], fetchedAt: nil, state: .noData),
            Fixture.account(id: "2", windows: [Fixture.window(.fiveHour, percent: 7)], state: .authDead(strikes: 1))
        ]
        for mode in MenuBarMode.allCases {
            #expect(MenuBarDisplay.make(for: state(accounts), mode: mode, now: Fixture.now).segments.isEmpty)
        }
    }

    // MARK: - Modus und Reihenfolge

    @Test("Der Modus bestimmt, wie viele Accounts in der Leiste stehen")
    func modeControlsSegmentCount() {
        let accounts = (1...3).map { index in
            Fixture.account(
                id: "\(index)",
                windows: [
                    Fixture.window(.fiveHour, percent: Double(index) * 10),
                    Fixture.window(.sevenDay, percent: Double(index) * 5)
                ]
            )
        }
        let state = state(accounts)

        #expect(MenuBarDisplay.make(for: state, mode: .bestAccount, now: Fixture.now).segments.count == 1)
        #expect(MenuBarDisplay.make(for: state, mode: .allAccounts, now: Fixture.now).segments.count == 3)
    }

    @Test("Die Anzeige folgt im Modus „nur bester“ dem gerankten ersten Account")
    func displayFollowsRanking() {
        let busy = Fixture.account(
            id: "1",
            windows: [Fixture.window(.fiveHour, percent: 95), Fixture.window(.sevenDay, percent: 95)]
        )
        let free = Fixture.account(
            id: "2",
            windows: [Fixture.window(.fiveHour, percent: 10), Fixture.window(.sevenDay, percent: 10)]
        )
        let state = state([busy, free])
        let display = MenuBarDisplay.make(for: state, mode: .bestAccount, now: Fixture.now)

        #expect(state.bestAccount(now: Fixture.now)?.id == "2")
        #expect(display.segments.map(\.id) == ["2"])
        #expect(display.segments.first?.values.map(\.text) == ["10%", "10%"])
    }

    @Test("Im Modus „alle“ gilt die Kennungsordnung — und die springt nicht mit den Prozentwerten")
    func allAccountsUseIdentifierOrder() {
        func accounts(percentsById: [String: Double]) -> [MonitoredAccount] {
            percentsById.keys.sorted().map { id in
                Fixture.account(
                    id: id,
                    windows: [
                        Fixture.window(.fiveHour, percent: percentsById[id] ?? 0),
                        Fixture.window(.sevenDay, percent: percentsById[id] ?? 0)
                    ]
                )
            }
        }
        // Natürlich-numerisch: "2" vor "10", unabhängig von der Auslastung.
        let low = state(accounts(percentsById: ["10": 5, "2": 60, "1": 90]))
        let high = state(accounts(percentsById: ["10": 90, "2": 5, "1": 60]))

        let first = MenuBarDisplay.make(for: low, mode: .allAccounts, now: Fixture.now)
        let second = MenuBarDisplay.make(for: high, mode: .allAccounts, now: Fixture.now)

        #expect(first.segments.map(\.id) == ["1", "2", "10"])
        // Die eigentliche Zusage: dieselbe Reihenfolge, obwohl das Ranking
        // sich komplett gedreht hat.
        #expect(second.segments.map(\.id) == first.segments.map(\.id))
        #expect(low.accounts(now: Fixture.now).map(\.id) != high.accounts(now: Fixture.now).map(\.id))
    }

    @Test("Höchstens vier Accounts in der Leiste, der Rest wird angezeigt")
    func atMostFourSegmentsPlusOverflow() {
        let accounts = (1...6).map { index in
            Fixture.account(id: "\(index)", windows: [Fixture.window(.fiveHour, percent: 10)])
        }
        let display = MenuBarDisplay.make(for: state(accounts), mode: .allAccounts, now: Fixture.now)

        #expect(display.segments.count == MenuBarDisplay.maximumSegments)
        #expect(display.segments.map(\.id) == ["1", "2", "3", "4"])
        #expect(display.hasMoreAccounts)

        let four = Array(accounts.prefix(4))
        #expect(MenuBarDisplay.make(for: state(four), mode: .allAccounts, now: Fixture.now).hasMoreAccounts == false)
    }

    @Test("Sind die ersten vier stumm, verschwindet der fünfte mit Daten nicht")
    func silentLeadersDoNotSwallowAccountsWithData() {
        // Die Kollaps-Regel lief früher **nach** der Obergrenze: Die ersten
        // vier in Kennungsordnung waren datenlos, also war die geprüfte
        // Auswahl stumm — und die Leiste kollabierte komplett, samt
        // `hasMoreAccounts == false`. Die Accounts mit echten Zahlen
        // verschwanden restlos, ohne auch nur ein „…".
        let silent = (1...4).map { index in
            Fixture.account(id: "\(index)", windows: [], fetchedAt: nil, state: .noData)
        }
        let loud = (5...6).map { index in
            Fixture.account(
                id: "\(index)",
                windows: [
                    Fixture.window(.fiveHour, percent: 40),
                    Fixture.window(.sevenDay, percent: 40)
                ]
            )
        }
        let display = MenuBarDisplay.make(for: state(silent + loud), mode: .allAccounts, now: Fixture.now)

        #expect(display.segments.isEmpty == false)
        #expect(display.segments.map(\.id) == ["1", "2", "3", "4"])
        // Der Hinweis auf die restlichen Accounts ist hier die ganze Information.
        #expect(display.hasMoreAccounts)
    }

    @Test("Im Modus „nur bester“ gibt es bewusst kein „…“")
    func bestAccountNeverAnnouncesMore() {
        // Festgehaltene Entscheidung, kein Nebeneffekt: Der Modus zeigt genau
        // einen Account. Ein „…" behauptete eine Kürzung, wo eine Auswahl
        // getroffen wurde.
        let accounts = (1...6).map { index in
            Fixture.account(
                id: "\(index)",
                windows: [
                    Fixture.window(.fiveHour, percent: Double(index) * 10),
                    Fixture.window(.sevenDay, percent: Double(index) * 3)
                ]
            )
        }
        let display = MenuBarDisplay.make(for: state(accounts), mode: .bestAccount, now: Fixture.now)

        #expect(display.segments.count == 1)
        #expect(display.hasMoreAccounts == false)
        // Und im anderen Modus zeigt derselbe Zustand sehr wohl das „…".
        #expect(MenuBarDisplay.make(for: state(accounts), mode: .allAccounts, now: Fixture.now).hasMoreAccounts)
    }

    // MARK: - Die zwei Fenster je Segment

    @Test("Je Segment genau 5 h und 7 d, in dieser Reihenfolge")
    func exactlyTwoWindowsInFixedOrder() {
        // Der Account hat vier Fenster; in der Leiste stehen trotzdem nur die
        // beiden festgelegten (der `spend`-Zusatzpunkt bindet hier nicht).
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 30),
                Fixture.window(.sevenDay, percent: 40),
                Fixture.window(.spend, percent: 20),
                Fixture.window(.scoped(name: "Fable"), percent: 10, id: "scoped:0:Fable")
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.values.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(segment.values.map(\.text) == ["30%", "40%"])
    }

    @Test("Fehlendes Fenster ergibt „–“ mit neutralem Punkt")
    func missingWindowIsShownAsDash() {
        let account = Fixture.account(windows: [Fixture.window(.fiveHour, percent: 13)])
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.values.count == 2)
        #expect(segment.values[1].kind == .sevenDay)
        #expect(segment.values[1].reading == .missing)
        #expect(segment.values[1].text == "–")
        #expect(segment.values[1].status == nil)
        // Kein stilles Weglassen und ausdrücklich kein „0 %".
        #expect(segment.values[1].text != "0%")
    }

    @Test("Nicht-endlicher Wert ergibt keine Zahl, aber eine konservative Farbe")
    func nonFiniteValueKeepsColorWithoutNumber() {
        for percent in [Double.nan, .infinity] {
            let account = Fixture.account(
                windows: [
                    Fixture.window(.fiveHour, percent: percent),
                    Fixture.window(.sevenDay, percent: 10)
                ]
            )
            let segment = MenuBarDisplay.segment(for: account)

            #expect(segment.values[0].reading == .unreadable)
            #expect(segment.values[0].text == nil)
            #expect(segment.values[0].status == .red)
            #expect(segment.values[1].text == "10%")
        }
    }

    // MARK: - Ersatz-Invariante und Zusatzpunkt

    @Test("Die schlechteste Stufe eines Segments ist der Gesamtstatus des Accounts")
    func worstPointEqualsOverallStatus() {
        // Ersetzt die frühere Zusage „Menüleisten-Zahl == bindingPercent", die
        // mit zwei Zahlen pro Account nicht mehr formulierbar ist. Der Fall
        // aus `b215246` darf nicht zurückkommen: Anzeige und Ranking messen
        // dasselbe.
        let cases: [[LimitWindow]] = [
            [Fixture.window(.fiveHour, percent: 10), Fixture.window(.sevenDay, percent: 10),
             Fixture.window(.scoped(name: "Fable"), percent: 95, id: "scoped:0:Fable")],
            [Fixture.window(.fiveHour, percent: 20), Fixture.window(.sevenDay, percent: 20)],
            [Fixture.window(.fiveHour, percent: 5), Fixture.window(.spend, percent: 99)],
            [Fixture.window(.sevenDay, percent: 63)],
            [Fixture.window(.fiveHour, percent: 88), Fixture.window(.sevenDay, percent: 51),
             Fixture.window(.spend, percent: 4)]
        ]
        for windows in cases {
            let account = Fixture.account(windows: windows)
            let segment = MenuBarDisplay.segment(for: account)

            #expect(worstStatus(in: segment) == account.overallStatus)
            // Und der bindende Punkt trägt genau die bindende Auslastung.
            #expect(segment.binding?.percent == account.bindingPercent)
        }
    }

    @Test("Ein nicht-endliches verstecktes Fenster bricht die Invariante nicht")
    func hiddenNonFiniteWindowKeepsInvariant() {
        // Die gefährliche Richtung: `∞` zieht `bindingPercent` und damit
        // `overallStatus` auf rot. Ohne Zusatzpunkt zeigte die Leiste zwei
        // grüne Punkte und behauptete „alles gut", während der Account als rot
        // gilt. Der Zusatzpunkt trägt deshalb Farbe, aber keine Zahl.
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: .infinity, id: "scoped:0:Fable")
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(account.overallStatus == .red)
        #expect(segment.values.count == 3)
        #expect(segment.values[2].reading == .unreadable)
        #expect(segment.values[2].text == nil)
        #expect(segment.values[2].status == .red)
        #expect(worstStatus(in: segment) == account.overallStatus)
    }

    @Test("Trägt schon ein sichtbarer Punkt die Warnung, kommt kein zweiter dazu")
    func noSecondUnreadablePoint() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: .nan),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.spend, percent: .infinity)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.values.count == 2)
        #expect(segment.values[0].reading == .unreadable)
        #expect(segment.values[0].status == .red)
    }

    // MARK: - Anzeigenamen der Fenster

    @Test("Die Fensternamen kommen aus einer einzigen Abbildung")
    func windowKindNamingIsSingleSource() {
        // Roh durchgereichte Namen sind ohne Katalog prüfbar — genau sie
        // dürfen nicht verschluckt werden.
        #expect(WindowKindNaming.name(for: .scoped(name: "Fable")) == "Fable")
        #expect(WindowKindNaming.name(for: .other(rawKey: "weird_window")) == "weird_window")
        #expect(WindowKindNaming.isLocalized(.scoped(name: "Fable")) == false)
        #expect(WindowKindNaming.isLocalized(.other(rawKey: "weird_window")) == false)

        // Die drei bekannten Arten tragen Katalogschlüssel und bleiben
        // unterscheidbar — auch ohne geladenen Katalog (dann der Schlüssel).
        for kind in [LimitWindow.Kind.fiveHour, .sevenDay, .spend] {
            #expect(WindowKindNaming.isLocalized(kind))
            #expect(WindowKindNaming.name(for: kind).isEmpty == false)
        }
        let known = [LimitWindow.Kind.fiveHour, .sevenDay, .spend].map(WindowKindNaming.name(for:))
        #expect(Set(known).count == known.count)
    }

    @Test("Ein stärker bindendes verstecktes Fenster bekommt einen eigenen Punkt mit Zahl")
    func hiddenBinderGetsItsOwnPoint() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: 95, id: "scoped:0:Fable"),
                Fixture.window(.scoped(name: "Opus"), percent: 40, id: "scoped:1:Opus")
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        // Höchstens **einer** — sonst wüchse die Leiste mit jedem Kontingent.
        #expect(segment.values.count == 3)
        #expect(segment.values[2].kind == .scoped(name: "Fable"))
        #expect(segment.values[2].text == "95%")
        #expect(segment.values[2].status == .red)
        // Eindeutige Kennungen, sonst wird `ForEach` undefiniert.
        #expect(Set(segment.values.map(\.id)).count == segment.values.count)
    }

    @Test("Kein Zusatzpunkt, wenn die sichtbaren Fenster ohnehin binden")
    func noExtraPointWhenVisibleWindowsBind() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 80),
                Fixture.window(.sevenDay, percent: 90),
                Fixture.window(.spend, percent: 90)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.values.count == 2)
        #expect(worstStatus(in: segment) == account.overallStatus)
    }

    // MARK: - Ranking-Ebene

    @Test("Der oberste Account trägt nie eine schlechtere Ampel als einer darunter")
    func topAccountNeverWorseThanTheOnesBelow() {
        // Reproduziert den gemeldeten Fall: A ist bei 5h/7d entspannt, sein
        // Modellkontingent steht bei 95 %. Vorher rankte A vorne und die
        // Menüleiste zeigte rot 95 %, während der grüne B darunter stand.
        //
        // Die Zusage sitzt auf der **Ranking**-Ebene: Die Leiste reiht im
        // Modus „alle" nach Kennung, dort gilt keine Monotonie. Und über die
        // beiden Einzelfenster wäre sie sachlich falsch — 5 h ist über die
        // Ranking-Reihenfolge nicht monoton, weil 7 d binden kann.
        let a = Fixture.account(
            id: "1",
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: 95, id: "scoped:0:Fable")
            ]
        )
        let b = Fixture.account(
            id: "2",
            windows: [
                Fixture.window(.fiveHour, percent: 20),
                Fixture.window(.sevenDay, percent: 20)
            ]
        )
        let state = state([a, b])
        let ranked = state.accounts(now: Fixture.now)

        #expect(ranked.map(\.id) == ["2", "1"])
        #expect(MenuBarDisplay.make(for: state, mode: .bestAccount, now: Fixture.now).segments.map(\.id) == ["2"])

        // Monoton nicht besser werdend von oben nach unten.
        let percents = ranked.compactMap { AccountBindingDisplay.make(for: $0).percent }
        #expect(percents == percents.sorted())
        #expect(percents == [20, 95])
    }

    // MARK: - Persistenz des Modus

    @Test("Unbekannter oder fehlender gespeicherter Wert fällt auf „nur bester“ zurück")
    func storedModeFallsBackToBestAccount() {
        #expect(MenuBarMode(storedValue: nil) == .bestAccount)
        #expect(MenuBarMode(storedValue: "") == .bestAccount)
        #expect(MenuBarMode(storedValue: "Müll") == .bestAccount)
        #expect(MenuBarMode(storedValue: "BestAccount") == .bestAccount)
        // Und die gültigen Werte kommen unverändert zurück.
        for mode in MenuBarMode.allCases {
            #expect(MenuBarMode(storedValue: mode.rawValue) == mode)
        }
    }

    // MARK: - Formatvorschriften (unverändert)

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
}
