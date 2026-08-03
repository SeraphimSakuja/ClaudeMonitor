import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Wie Lesefehler den angezeigten Zustand verändern dürfen — und wie nicht.
@Suite("Zustandsfortschreibung des Monitors")
struct MonitorViewStateTests {

    private var snapshot: AccountsSnapshot {
        Fixture.snapshot([
            Fixture.account(windows: [Fixture.window(.fiveHour, percent: 20)])
        ])
    }

    @Test("Erfolgreicher Lesevorgang hebt einen alten Fehlzustand auf")
    func successClearsIssue() {
        let previous = MonitorViewState(snapshot: nil, issue: .unreadable(reason: "x"), isLoading: false)
        let next = previous.reduced(with: .success(snapshot))

        #expect(next.snapshot == snapshot)
        #expect(next.issue == nil)
        #expect(next.isLoading == false)
    }

    @Test("Vorübergehend unlesbarer Store behält die letzten Zahlen")
    func unreadableKeepsLastNumbers() {
        let previous = MonitorViewState(snapshot: snapshot, issue: nil, isLoading: false)
        let next = previous.reduced(with: .unreadable(reason: "half written"))

        #expect(next.snapshot == snapshot)
        #expect(next.issue == .unreadable(reason: "half written"))
    }

    @Test("Fehlende Quelle verwirft die Zahlen")
    func storeNotFoundDropsNumbers() {
        let previous = MonitorViewState(snapshot: snapshot, issue: nil, isLoading: false)
        let next = previous.reduced(with: .storeNotFound(searchedPaths: ["/a", "/b"]))

        #expect(next.snapshot == nil)
        #expect(next.issue == .storeNotFound(searchedPaths: ["/a", "/b"]))
        #expect(MenuBarDisplay.make(for: next, now: Fixture.now) == .unavailable)
    }

    @Test("Abweichende schemaVersion verwirft die Zahlen (L4)")
    func schemaMismatchHidesNumbers() {
        let previous = MonitorViewState(snapshot: snapshot, issue: nil, isLoading: false)
        let next = previous.reduced(with: .unsupportedSchemaVersion(found: 3, expected: 2))

        #expect(next.snapshot == nil)
        #expect(next.accounts(now: Fixture.now).isEmpty)
        #expect(next.issue == .unsupportedSchema(found: 3, expected: 2))
        #expect(MenuBarDisplay.make(for: next, now: Fixture.now).text == nil)
    }

    @Test("Nach dem ersten Lesevorgang wird nicht mehr geladen")
    func loadingEndsAfterFirstResult() {
        let results: [UsageStoreReadResult] = [
            .success(snapshot),
            .unreadable(reason: "x"),
            .storeNotFound(searchedPaths: []),
            .unsupportedSchemaVersion(found: nil, expected: 2)
        ]
        for result in results {
            #expect(MonitorViewState().reduced(with: result).isLoading == false)
        }
    }
}
