import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Regeln der Kompaktanzeige in der Menüleiste.
@Suite("Menüleisten-Kompaktanzeige")
struct MenuBarDisplayTests {

    // MARK: - Helfer

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

    @Test("Zahl und Detailstufe eines Wertes stammen aus demselben Fenster, nicht vom Account")
    func everyValueReadsItsOwnWindow() {
        // Der Account ist insgesamt rot (7 d bei 90) — der Punkt der Leiste ist
        // es also. Die *Detail*stufe des 5-h-Wertes muss trotzdem grün bleiben:
        // Aus ihr spricht der Vorlesetext, und dort stünde sonst „kritisch"
        // neben „10 %".
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 90)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(account.overallStatus == .red)
        #expect(segment.status == .red)
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
        #expect(segment.status == nil)
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
        // Regel 6: nirgends eine Farbe. Insbesondere färben die 95 % des
        // versteckten Fensters den Punkt **nicht** — sonst zeigte ein toter
        // Token eine Ampel zu eingefrorenen Altwerten.
        #expect(segment.status == nil)
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
        // Ohne diese Regel stünde beim Erststart `●–/– ●–/–` ohne jede Aussage.
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
        // beiden festgelegten.
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

    @Test("Die Zahlen stehen als „5h/7d“ zusammen — ein Wert ohne Zahl wird zu „–“")
    func numbersTextKeepsBothSlots() {
        let complete = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 74),
                Fixture.window(.sevenDay, percent: 28)
            ]
        )
        // Ohne Prozentzeichen — es käme in der Leiste bis zu achtmal vor.
        #expect(MenuBarDisplay.segment(for: complete).numbersText == "74/28")
        #expect(MenuBarDisplay.segment(for: complete).numbersText.contains("%") == false)
        // Der Vorlesetext benutzt weiterhin die Fassung **mit** Zeichen.
        #expect(MenuBarDisplay.segment(for: complete).values.map(\.text) == ["74%", "28%"])

        // Fehlt 7 d, bleibt der Platz stehen. Würde er weggelassen, hieße „74"
        // mal 5 h und mal 7 d — zwei Bedeutungen für dieselbe Stelle.
        let partial = Fixture.account(windows: [Fixture.window(.fiveHour, percent: 74)])
        #expect(MenuBarDisplay.segment(for: partial).numbersText == "74/–")

        // Unlesbarer Wert ebenso: Platz halten, keine Zahl erfinden.
        let broken = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: .infinity),
                Fixture.window(.sevenDay, percent: 28)
            ]
        )
        #expect(MenuBarDisplay.segment(for: broken).numbersText == "–/28")

        // Toter Token: beide Plätze leer, ausdrücklich kein „0 %".
        let dead = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 74)],
            state: .authDead(strikes: 1)
        )
        #expect(MenuBarDisplay.segment(for: dead).numbersText == "–/–")
        #expect(MenuBarDisplay.segment(for: dead).numbersText.contains("74") == false)
        #expect(MenuBarDisplay.segment(for: dead).numbersText.contains("0") == false)
    }

    @Test("Die Reihenfolge 5 h, 7 d hängt nicht an der Reihenfolge in der Quelle")
    func windowOrderIsFixedNotSourceOrder() {
        // Der Store liefert die Fenster hier in umgekehrter Reihenfolge. Würde
        // sie durchgereicht, stünde in der Leiste `40/30` statt `30/40` — zwei
        // plausible Zahlen mit vertauschter Bedeutung, das Schlimmste.
        let account = Fixture.account(
            windows: [
                Fixture.window(.sevenDay, percent: 40),
                Fixture.window(.fiveHour, percent: 30)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.values.count == 2)
        #expect(segment.values.map(\.kind) == MenuBarDisplay.visibleKinds)
        #expect(segment.values.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(segment.values.map(\.text) == ["30%", "40%"])
    }

    @Test("Fehlendes Fenster ergibt „–“ statt einer erfundenen Zahl")
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

    @Test("Nicht-endlicher Wert ergibt keine Zahl, aber eine konservative Stufe")
    func nonFiniteValueKeepsLevelWithoutNumber() {
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

    // MARK: - Der Punkt trägt die Account-Ampel

    @Test("Ein verstecktes Fenster färbt den Punkt rot, obwohl beide Zahlen grün sind")
    func hiddenWindowTurnsTheDotRedWhileBothNumbersAreGreen() {
        // **Die Zusage aus `b215246`, tautologiefrei.** Ein Test, der bloß
        // `segment.status == account.overallStatus` prüft, ist seit dem Umbau
        // eine Gleichung mit sich selbst und bewiese hier nichts: Er bliebe
        // grün, wenn `status` aus einem der sichtbaren Fenster käme, solange
        // nur `overallStatus` mitliefe. Deshalb stehen hier feste Zahlen.
        //
        // Früher leistete das ein Zusatzpunkt für versteckte Fenster; er ist
        // ersatzlos entfallen, weil der eine Punkt jetzt direkt die
        // Account-Ampel trägt. Die Zusage selbst darf nicht mitentfallen.
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: 95, id: "scoped:0:Fable"),
                Fixture.window(.scoped(name: "Opus"), percent: 40, id: "scoped:1:Opus")
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        // Beide **sichtbaren** Fenster sind unstrittig grün …
        #expect(segment.values.map(\.text) == ["10%", "10%"])
        #expect(segment.values.map(\.status) == [.green, .green])
        // … und der Punkt ist trotzdem rot.
        #expect(segment.status == .red)
        // Die Leiste wächst dadurch nicht: weiterhin genau zwei Zahlen.
        #expect(segment.values.count == 2)
        #expect(segment.values.contains { $0.kind == .scoped(name: "Fable") } == false)
    }

    @Test("Die Farbe des Punktes ist der Gesamtstatus des Accounts")
    func dotEqualsOverallStatus() {
        // Die Gleichung — sie hält Anzeige und Ranking auf demselben Maß, kann
        // den Fall oben aber nicht ersetzen.
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

            #expect(segment.status == account.overallStatus)
            #expect(segment.status != nil)
            // Und die Leiste bleibt schmal, egal wie viele Fenster es gibt.
            #expect(segment.values.count == 2)
        }
    }

    @Test("Ein nicht-endliches verstecktes Fenster färbt den Punkt rot, ohne eine Zahl zu erfinden")
    func hiddenNonFiniteWindowStillColorsTheDot() {
        // Die gefährliche Richtung: `∞` zieht `bindingPercent` (ein `max`) und
        // damit `overallStatus` auf rot. Zeigte die Leiste dazu zwei grüne
        // Zahlen und einen grünen Punkt, behauptete sie „alles gut". Der Punkt
        // muss rot sein — eine Zahl darf daraus trotzdem nicht entstehen.
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: .infinity, id: "scoped:0:Fable")
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(account.overallStatus == .red)
        #expect(segment.status == .red)
        #expect(segment.values.count == 2)
        #expect(segment.values.map(\.text) == ["10%", "10%"])
    }

    @Test("Ein unlesbares sichtbares Fenster kostet die Zahl, nicht die Ampel")
    func unreadableVisibleWindowKeepsTheDot() {
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
        #expect(segment.values[0].text == nil)
        #expect(segment.values[0].status == .red)
        #expect(segment.values[1].text == "10%")
        #expect(segment.status == .red)
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

    @Test("Auch viele versteckte Fenster ändern nichts an Breite und Kennungen")
    func hiddenWindowsNeverWidenTheSegment() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 10),
                Fixture.window(.sevenDay, percent: 10),
                Fixture.window(.scoped(name: "Fable"), percent: 95, id: "scoped:0:Fable"),
                Fixture.window(.scoped(name: "Opus"), percent: 40, id: "scoped:1:Opus"),
                Fixture.window(.spend, percent: 60)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        // Der frühere Zusatzpunkt wuchs die Leiste; jetzt bleibt sie fest.
        #expect(segment.values.map(\.kind) == [.fiveHour, .sevenDay])
        #expect(segment.status == .red)
        // Eindeutige Kennungen — die Werte sind `Identifiable`.
        #expect(Set(segment.values.map(\.id)).count == segment.values.count)
    }

    @Test("Binden die sichtbaren Fenster ohnehin, bleibt der Punkt bei ihrer Stufe")
    func visibleWindowsDriveTheDotWhenTheyBind() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 80),
                Fixture.window(.sevenDay, percent: 90),
                Fixture.window(.spend, percent: 90)
            ]
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.values.count == 2)
        #expect(segment.status == .red)
        #expect(segment.status == account.overallStatus)
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

    @Test("Die Fassung ohne Prozentzeichen rundet und klemmt identisch")
    func bareFormattingMatchesCompact() {
        // Zwei Formatierer sind zwei Rundungen; die Leiste dürfte nie eine
        // andere Zahl zeigen als das Fenster.
        for percent in [0, 49.4, 49.5, 100, -5, 5000] as [Double] {
            #expect(PercentFormatting.bare(percent).map { $0 + "%" } == PercentFormatting.compact(percent))
        }
        #expect(PercentFormatting.bare(49.5) == "50")
        #expect(PercentFormatting.bare(.nan) == nil)
        #expect(PercentFormatting.bare(.infinity) == nil)
    }

    @Test("Fortschrittsanteil bleibt zwischen 0 und 1")
    func fractionIsClamped() {
        #expect(PercentFormatting.fraction(50) == 0.5)
        #expect(PercentFormatting.fraction(180) == 1)
        #expect(PercentFormatting.fraction(-3) == 0)
        #expect(PercentFormatting.fraction(.nan) == nil)
    }
}
