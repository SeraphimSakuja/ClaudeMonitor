import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Reihenfolge der Kärtchen im Detailfenster und die Beträge des
/// Ausgabenfensters.
@Suite("Detailfenster: Namensordnung und Beträge")
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

    private func names(_ content: PopoverContent) -> [String] {
        guard case .accounts(let accounts) = content else { return [] }
        return accounts.map(\.displayName)
    }

    // MARK: - Reihenfolge

    @Test("Die Kärtchen stehen nach Namen, nicht nach Ranking")
    func cardsAreSortedByName() {
        // „zeta" ist mit Abstand der beste Account. Stünde er deshalb oben,
        // müsste man ihn nach jeder Änderung neu suchen — das Detailfenster ist
        // die Nachschlage-, nicht die Empfehlungsansicht.
        let accounts = [
            account(id: "1", name: "zeta", percent: 2),
            account(id: "2", name: "alpha", percent: 80),
            account(id: "3", name: "mike", percent: 40)
        ]
        let content = PopoverContent.make(for: state(accounts), now: Fixture.now)

        #expect(names(content) == ["alpha", "mike", "zeta"])
    }

    @Test("Die Reihenfolge bleibt stehen, wenn sich die Auslastung dreht")
    func orderSurvivesChangingPercentages() {
        func ordered(_ percents: [Double]) -> [String] {
            let accounts = zip(["zeta", "alpha", "mike"], percents).enumerated().map { index, pair in
                account(id: "\(index + 1)", name: pair.0, percent: pair.1)
            }
            return names(PopoverContent.make(for: state(accounts), now: Fixture.now))
        }

        // Dieselbe Ordnung, obwohl das Ranking sich komplett umdreht.
        #expect(ordered([2, 80, 40]) == ordered([80, 2, 40]))
        #expect(ordered([2, 80, 40]) == ["alpha", "mike", "zeta"])
    }

    @Test("Namen werden natürlich-numerisch geordnet, nicht nach Unicode")
    func namesUseNaturalNumericOrder() {
        // Nach reiner Zeichenordnung stünde „account-10" vor „account-2".
        let accounts = [
            account(id: "1", name: "account-10", percent: 10),
            account(id: "2", name: "account-2", percent: 10)
        ]
        #expect(names(PopoverContent.make(for: state(accounts), now: Fixture.now)) == ["account-2", "account-10"])
    }

    @Test("Gleiche Namen tauschen nicht bei jedem Durchlauf die Plätze")
    func equalNamesFallBackToAccountNumber() {
        let accounts = [
            account(id: "10", name: "gleich", percent: 5),
            account(id: "2", name: "gleich", percent: 90)
        ]
        guard case .accounts(let sorted) = PopoverContent.make(for: state(accounts), now: Fixture.now) else {
            Issue.record("Keine Accounts geliefert")
            return
        }
        #expect(sorted.map(\.id) == ["2", "10"])
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
