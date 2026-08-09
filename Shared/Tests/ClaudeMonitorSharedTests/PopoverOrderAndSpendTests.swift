import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Reihenfolge der Kärtchen im Detailfenster, die Regel gegen doppelte
/// Altersangaben und die Beträge des Ausgabenfensters.
@Suite("Detailfenster: Nummernordnung, Kompaktheit und Beträge")
struct PopoverOrderAndSpendTests {

    private func state(_ accounts: [MonitoredAccount]) -> MonitorViewState {
        MonitorViewState(snapshot: Fixture.snapshot(accounts), isLoading: false)
    }

    private func account(id: String, name: String, percent: Double) -> MonitoredAccount {
        Fixture.account(
            id: id,
            name: name,
            windows: [Fixture.window(.fiveHour, percent: percent)]
        )
    }

    // MARK: - Reihenfolge

    @Test("Die Kärtchen stehen nach Account-Nummer, nicht nach Ranking")
    func cardsAreSortedByAccountNumber() {
        // „3" ist mit Abstand der beste Account. Stünde er deshalb oben, müsste
        // man ihn nach jeder Änderung neu suchen — das Detailfenster ist die
        // Nachschlage-, nicht die Empfehlungsansicht.
        let accounts = [
            account(id: "3", name: "zeta", percent: 2),
            account(id: "1", name: "alpha", percent: 80),
            account(id: "2", name: "mike", percent: 40)
        ]
        guard case .accounts(let sorted) = PopoverContent.make(for: state(accounts), now: Fixture.now) else {
            Issue.record("Keine Accounts geliefert")
            return
        }
        #expect(sorted.map(\.id) == ["1", "2", "3"])
    }

    @Test("Die Reihenfolge bleibt stehen, wenn sich die Auslastung dreht")
    func orderSurvivesChangingPercentages() {
        func ordered(_ percents: [Double]) -> [String] {
            let accounts = zip(["3", "1", "2"], percents).map { id, percent in
                account(id: id, name: "account-\(id)", percent: percent)
            }
            guard case .accounts(let sorted) = PopoverContent.make(for: state(accounts), now: Fixture.now) else {
                return []
            }
            return sorted.map(\.id)
        }

        // Dieselbe Ordnung, obwohl das Ranking sich komplett umdreht.
        #expect(ordered([2, 80, 40]) == ordered([80, 2, 40]))
        #expect(ordered([2, 80, 40]) == ["1", "2", "3"])
    }

    @Test("Die Reihenfolge hängt nicht am Namen — ein Alias darf sie nicht umwerfen")
    func renamingAnAliasDoesNotReorder() {
        // Genau der Grund für die Nummer: Aliase sind jederzeit änderbar.
        let before = [
            account(id: "1", name: "zeta", percent: 10),
            account(id: "2", name: "alpha", percent: 10)
        ]
        let after = [
            account(id: "1", name: "alpha", percent: 10),
            account(id: "2", name: "zeta", percent: 10)
        ]
        func ids(_ accounts: [MonitoredAccount]) -> [String] {
            guard case .accounts(let sorted) = PopoverContent.make(for: state(accounts), now: Fixture.now) else {
                return []
            }
            return sorted.map(\.id)
        }
        #expect(ids(before) == ids(after))
        #expect(ids(before) == ["1", "2"])
    }

    @Test("Nummern werden natürlich-numerisch geordnet, nicht nach Unicode")
    func numbersUseNaturalNumericOrder() {
        // Nach reiner Zeichenordnung stünde „10" vor „2".
        let accounts = [
            account(id: "10", name: "a", percent: 10),
            account(id: "2", name: "b", percent: 10)
        ]
        guard case .accounts(let sorted) = PopoverContent.make(for: state(accounts), now: Fixture.now) else {
            Issue.record("Keine Accounts geliefert")
            return
        }
        #expect(sorted.map(\.id) == ["2", "10"])
    }

    // MARK: - Altersangabe steht genau einmal

    @Test("Bei veralteten Daten nennt nur die Statuszeile das Alter")
    func staleAgeIsStatedOnce() {
        // Vorher stand zweimal dasselbe im selben Kärtchen: oben „Daten sind
        // veraltet: 46 Min.", unten „Vor 46 Min. aktualisiert".
        #expect(AccountCardDisplay.showsUpdatedFooter(statusLine: .stale(age: 2760)) == false)
        // In allen anderen Zuständen bleibt die Fußzeile die einzige Auskunft
        // über das Alter und muss stehen bleiben.
        #expect(AccountCardDisplay.showsUpdatedFooter(statusLine: .upToDate))
        #expect(AccountCardDisplay.showsUpdatedFooter(statusLine: .noData))
        #expect(AccountCardDisplay.showsUpdatedFooter(statusLine: .reLoginRequired(strikes: 1)))
        #expect(AccountCardDisplay.showsUpdatedFooter(statusLine: .paused(until: Fixture.now)))
        #expect(AccountCardDisplay.showsUpdatedFooter(statusLine: .fetchFailed(message: "kaputt")))
    }

    // MARK: - Beträge des Ausgabenfensters

    private let english = Locale(identifier: "en_US")

    @Test("Verbrauch und Budget werden mit Währung gesetzt")
    func spendShowsBothAmountsWithCurrency() {
        let spend = LimitWindow.SpendDetail(used: 12.34, limit: 50, currency: "USD")
        let amounts = SpendAmountDisplay.amounts(for: spend, locale: english)

        #expect(amounts?.used == "$12.34")
        #expect(amounts?.limit == "$50.00")
    }

    @Test("Ohne bekannte Währung bleibt es eine reine Zahl")
    func spendWithoutCurrencyStaysPlain() {
        // Eine geratene Währung wäre schlimmer als gar keine.
        let spend = LimitWindow.SpendDetail(used: 12.3, limit: 50, currency: nil)
        let amounts = SpendAmountDisplay.amounts(for: spend, locale: english)

        #expect(amounts?.used == "12.30")
        #expect(amounts?.limit == "50.00")
    }

    @Test("Ein Limit von null ist keine Angabe, sondern deren Fehlen")
    func zeroLimitIsTreatedAsMissing() {
        // „12,34 $ von 0,00 $" läse sich wie ein gesprengtes Budget.
        let spend = LimitWindow.SpendDetail(used: 12.34, limit: 0, currency: "USD")
        let amounts = SpendAmountDisplay.amounts(for: spend, locale: english)

        #expect(amounts?.used == "$12.34")
        #expect(amounts?.limit == nil)
    }

    @Test("Kaputte Werte ergeben gar keine Beträge")
    func brokenValuesYieldNothing() {
        #expect(SpendAmountDisplay.amounts(
            for: LimitWindow.SpendDetail(used: .nan, limit: 50, currency: "USD"),
            locale: english
        ) == nil)
        #expect(SpendAmountDisplay.amounts(
            for: LimitWindow.SpendDetail(used: -1, limit: 50, currency: "USD"),
            locale: english
        ) == nil)
        // Ein kaputtes Limit kostet nur das Limit, nicht den Verbrauch.
        let partial = SpendAmountDisplay.amounts(
            for: LimitWindow.SpendDetail(used: 5, limit: .infinity, currency: "USD"),
            locale: english
        )
        #expect(partial?.used == "$5.00")
        #expect(partial?.limit == nil)
    }
}
