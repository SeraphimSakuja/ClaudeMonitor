import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("MonitoredAccount — abgeleitete Werte")
struct MonitoredAccountTests {

    private let now = TestSupport.now

    // MARK: - Datenalter

    @Test("Ohne Abrufzeitpunkt gibt es kein Datenalter — und keine 0")
    func dataAgeWithoutFetchedAt() {
        let account = TestSupport.accountWithoutData("a")
        #expect(account.fetchedAt == nil)
        #expect(account.dataAge(now: now) == nil)
    }

    @Test("Datenalter ist die Spanne seit dem Abruf")
    func dataAgeNormalCase() {
        let account = TestSupport.account("a", fiveHour: 10, sevenDay: 10)
        #expect(account.dataAge(now: now.addingTimeInterval(90)) == 90)
    }

    @Test("Abrufzeitpunkt in der Zukunft ergibt 0, niemals ein negatives Alter")
    func dataAgeNeverNegative() {
        let account = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [TestSupport.window(.fiveHour, percent: 10)],
            fetchedAt: now.addingTimeInterval(3_600),
            state: .ok
        )
        #expect(account.dataAge(now: now) == 0)
    }

    // MARK: - Ampel über alle Fenster

    @Test("overallStatus nimmt das schlechteste Fenster, nicht das beste")
    func overallStatusTakesWorstWindow() {
        let account = TestSupport.account("a", fiveHour: 10, sevenDay: 95)
        // Bestes Fenster wäre grün — maßgeblich ist das schlechteste.
        #expect(account.window(kind: .fiveHour)?.status == .green)
        #expect(account.window(kind: .sevenDay)?.status == .red)
        #expect(account.overallStatus == .red)
    }

    @Test("overallStatus auch dann rot, wenn nur ein Nebenfenster rot ist")
    func overallStatusFromScopedWindow() {
        let account = MonitoredAccount(
            id: "a",
            displayName: "a@example.com",
            windows: [
                TestSupport.window(.fiveHour, percent: 1),
                TestSupport.window(.sevenDay, percent: 2),
                TestSupport.window(.scoped(name: "Fable"), percent: 90)
            ],
            fetchedAt: now,
            state: .ok
        )
        #expect(account.overallStatus == .red)
    }

    @Test("overallStatus ist gelb, wenn kein Fenster rot ist")
    func overallStatusYellow() {
        let account = TestSupport.account("a", fiveHour: 10, sevenDay: 60)
        #expect(account.overallStatus == .yellow)
    }

    @Test("Ohne verwertbare Daten gibt es keine Ampel")
    func overallStatusWithoutData() {
        #expect(TestSupport.accountWithoutData("a").overallStatus == nil)
    }

    // MARK: - Nächster geplanter Abruf

    @Test("nextPollAt wird aus dem Store übernommen")
    func nextPollAtIsCarried() throws {
        let json = """
        {
          "schemaVersion": 2,
          "accounts": {
            "1": {
              "email": "user1@example.com",
              "lastGood": { "five_hour": { "pct": 5.0 } },
              "fetchedAt": 1754230000.0,
              "nextPollAt": 1754230600.0
            }
          }
        }
        """
        let snapshot = try #require(UsageStoreReader().decode(Data(json.utf8), now: now).snapshot)
        #expect(snapshot.accounts[0].nextPollAt == Date(timeIntervalSince1970: 1_754_230_600))
    }

    @Test("nextPollAt aus der echten Fixture wird getragen")
    func nextPollAtFromRealFixture() throws {
        let snapshot = try #require(
            UsageStoreReader().decode(try TestSupport.fixtureData("usage_real_format"), now: now).snapshot
        )
        #expect(snapshot.accounts[0].nextPollAt == Date(timeIntervalSince1970: 1_754_230_030))
    }

    @Test("Fehlendes nextPollAt bleibt nil")
    func nextPollAtMissing() throws {
        let json = """
        {
          "schemaVersion": 2,
          "accounts": { "1": { "lastGood": { "five_hour": { "pct": 5.0 } } } }
        }
        """
        let snapshot = try #require(UsageStoreReader().decode(Data(json.utf8), now: now).snapshot)
        #expect(snapshot.accounts[0].nextPollAt == nil)
    }
}
