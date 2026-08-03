import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Anzeigeregeln, die vorher ungetestet in den Views steckten.
@Suite("Anzeigeregeln der Views")
struct DisplayRulesTests {

    // MARK: - Fensterliste eines Accounts

    @Test("Toter Token rendert keine Fensterzeilen — auch nicht aus eingefrorenen Altwerten")
    func authDeadRendersNoWindows() {
        let account = Fixture.account(
            windows: [
                Fixture.window(.fiveHour, percent: 71),
                Fixture.window(.sevenDay, percent: 44)
            ],
            state: .authDead(strikes: 3)
        )
        // Die Werte stehen im Store — genau darum geht es: Sie dürfen trotzdem
        // nicht als Balken erscheinen, während der Kopf „–" zeigt.
        #expect(account.windows.count == 2)
        #expect(AccountWindowsDisplay.make(for: account) == .noUsableData)
    }

    @Test("Ohne Daten gibt es ebenfalls keine Fensterzeilen")
    func noDataRendersNoWindows() {
        let account = Fixture.account(windows: [], fetchedAt: nil, state: .noData)
        #expect(AccountWindowsDisplay.make(for: account) == .noUsableData)
    }

    @Test("Die Fensterliste folgt genau hasUsableData — kein zweites Kriterium")
    func windowListFollowsUsableData() {
        let states: [AccountState] = [
            .ok,
            .noData,
            .authDead(strikes: 1),
            .backoff(until: Fixture.now.addingTimeInterval(60)),
            .failing(message: "http 500")
        ]
        for state in states {
            let account = Fixture.account(
                windows: [Fixture.window(.fiveHour, percent: 12)],
                state: state
            )
            let expectsWindows = account.hasUsableData
            let display = AccountWindowsDisplay.make(for: account)
            #expect((display == .noUsableData) == !expectsWindows, "Zustand \(state)")
            if expectsWindows {
                #expect(display == .windows(account.windows), "Zustand \(state)")
            }
        }
    }

    @Test("Backoff und Fehlversuch zeigen ihre Zahlen weiter — sie sind einordenbar")
    func backoffKeepsShowingNumbers() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 12)],
            state: .failing(message: "http 500")
        )
        #expect(AccountWindowsDisplay.make(for: account) == .windows(account.windows))
    }

    // MARK: - Inhalt des Detailfensters

    @Test("Fehlzustand ohne Accounts zeigt nur den Hinweis — keinen leeren Scrollbereich")
    func issueWithoutAccountsShowsOnlyBanner() {
        let state = MonitorViewState(
            snapshot: nil,
            issue: .storeNotFound(searchedPaths: ["/tmp/nirgends"]),
            isLoading: false
        )
        #expect(PopoverContent.make(for: state, now: Fixture.now) == .issueOnly)
    }

    @Test("Fehlzustand mit Accounts zeigt die Accounts weiter")
    func issueWithAccountsKeepsNumbers() {
        let account = Fixture.account(windows: [Fixture.window(.fiveHour, percent: 20)])
        let state = MonitorViewState(
            snapshot: Fixture.snapshot([account]),
            issue: .unreadable(reason: "busy"),
            isLoading: false
        )
        #expect(PopoverContent.make(for: state, now: Fixture.now) == .accounts([account]))
    }

    @Test("Vor dem ersten Lesevorgang wird geladen, danach ist leer wirklich leer")
    func loadingThenEmpty() {
        #expect(PopoverContent.make(for: MonitorViewState(), now: Fixture.now) == .loading)

        let done = MonitorViewState(snapshot: Fixture.snapshot([]), issue: nil, isLoading: false)
        #expect(PopoverContent.make(for: done, now: Fixture.now) == .empty)
    }

    @Test("Ein Ladezustand mit Fehlzustand zeigt den Fehlzustand, nicht den Spinner")
    func issueBeatsLoading() {
        let state = MonitorViewState(
            snapshot: nil,
            issue: .unsupportedSchema(found: 9, expected: 1),
            isLoading: true
        )
        #expect(PopoverContent.make(for: state, now: Fixture.now) == .issueOnly)
    }

    @Test("Der Inhalt kommt in Ranking-Reihenfolge, nicht in Snapshot-Reihenfolge")
    func contentFollowsRanking() {
        let busy = Fixture.account(
            id: "1",
            windows: [Fixture.window(.fiveHour, percent: 95), Fixture.window(.sevenDay, percent: 95)]
        )
        let free = Fixture.account(
            id: "2",
            windows: [Fixture.window(.fiveHour, percent: 10), Fixture.window(.sevenDay, percent: 10)]
        )
        let state = MonitorViewState(snapshot: Fixture.snapshot([busy, free]), isLoading: false)

        #expect(PopoverContent.make(for: state, now: Fixture.now) == .accounts([free, busy]))
    }

    // MARK: - Hinweisbalken

    @Test("Nur der vorübergehend unlesbare Store ist kein schwerer Fall")
    func onlyUnreadableIsMild() {
        #expect(IssuePresentation.isSevere(.unreadable(reason: "busy")) == false)
        #expect(IssuePresentation.isSevere(.storeNotFound(searchedPaths: [])))
        #expect(IssuePresentation.isSevere(.unsupportedSchema(found: nil, expected: 1)))
    }

    @Test("Jeder Fehlzustand hat ein eigenes, nicht leeres Symbol")
    func everyIssueHasItsOwnSymbol() {
        let issues: [MonitorIssue] = [
            .storeNotFound(searchedPaths: []),
            .unsupportedSchema(found: nil, expected: 1),
            .unreadable(reason: "busy")
        ]
        let symbols = issues.map(IssuePresentation.symbolName(for:))
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == issues.count)
    }

    // MARK: - Datenalter

    @Test("Veraltete Daten liefern ein anzeigbares Alter")
    func staleAgeIsDisplayable() {
        let account = Fixture.account(
            windows: [Fixture.window(.fiveHour, percent: 10)],
            fetchedAt: Fixture.now.addingTimeInterval(-(AccountStatusLine.staleThreshold + 125))
        )
        guard case .stale(let age) = AccountStatusLine.make(for: account, now: Fixture.now) else {
            Issue.record("Erwartet wurde der Zustand „veraltet“.")
            return
        }
        #expect(DataAgeDisplay.duration(for: age) == .seconds(425))
    }

    @Test("Uhrensprünge und kaputte Werte ergeben nie eine negative Altersangabe")
    func ageIsNeverNegative() {
        #expect(DataAgeDisplay.duration(for: -30) == .seconds(0))
        #expect(DataAgeDisplay.duration(for: .nan) == nil)
        #expect(DataAgeDisplay.duration(for: .infinity) == nil)
        // Endlich, aber absurd groß: geklemmt statt Absturz beim Int-Wandeln.
        #expect(DataAgeDisplay.duration(for: 1e30) != nil)
        #expect(DataAgeDisplay.duration(for: 300.4) == .seconds(300))
        #expect(DataAgeDisplay.duration(for: 300.6) == .seconds(301))
    }
}
