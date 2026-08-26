import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Obergrenzen gegen unbegrenzte Mengen aus der Fremdquelle.
///
/// Die Menüleiste ist ohnehin gedeckelt, das Detailfenster zeichnet dagegen
/// jedes Fenster jedes Accounts. Ohne Grenze bestimmt eine fremde Datei, wie
/// viel gezeichnet wird. Überzähliges wird **still** verworfen — die
/// verbleibenden Zahlen stimmen, ein Fehlzustand wäre die falsche Antwort.
@Suite("Grenzen für Fremddaten")
struct ForeignDataLimitsTests {

    @Test("Ein aufgeblähtes scoped-Array wird gedeckelt")
    func scopedWindowsAreCapped() throws {
        let count = UsageStoreReader.maximumWindowsPerAccount + 50
        let scoped = (0..<count)
            .map { #"{"name": "m\#($0)", "pct": 5.0}"# }
            .joined(separator: ",")
        let json = #"""
        {"schemaVersion": 2, "accounts": {"1": {"email": "user1@example.com",
         "lastGood": {"five_hour": {"pct": 10.0}, "scoped": [\#(scoped)]},
         "fetchedAt": 1754230000.0}}}
        """#

        let result = UsageStoreReader().decode(Data(json.utf8), now: TestSupport.now)

        guard case .success(let snapshot) = result else {
            Issue.record("Erwartet: .success, bekommen: \(result)")
            return
        }
        let account = try #require(snapshot.accounts.first)
        #expect(account.windows.count == UsageStoreReader.maximumWindowsPerAccount)
        // Die Deckelung darf nicht das 5-Stunden-Fenster wegschneiden: Es
        // sortiert vor den scoped-Fenstern und muss überleben.
        #expect(account.window(kind: .fiveHour)?.percent == 10)
    }

    @Test("CM-17: Eine aufgeblähte Account-Zahl aus usage.json wird gedeckelt")
    func accountCountFromUsageStoreIsCapped() throws {
        // Fail-open-Fall (`sequence: .empty` ⇒ `recognizes` filtert nichts,
        // siehe Doku dort): genau der Fall, in dem der CM-14-Filter die
        // Account-Zahl NICHT mindert und `usage.json` allein entscheidet.
        let count = UsageStoreReader.maximumAccounts + 20
        let entries = (1...count)
            .map { #""\#($0)": {"email": "user\#($0)@example.com", "lastGood": {"five_hour": {"pct": 5.0}}}"# }
            .joined(separator: ",")
        let json = #"{"schemaVersion": 2, "accounts": {\#(entries)}}"#

        let first = UsageStoreReader().decode(Data(json.utf8), now: TestSupport.now)
        let second = UsageStoreReader().decode(Data(json.utf8), now: TestSupport.now)

        guard case .success(let firstSnapshot) = first, case .success(let secondSnapshot) = second else {
            Issue.record("Erwartet: .success auf beiden Seiten, bekommen: \(first), \(second)")
            return
        }
        #expect(firstSnapshot.accounts.count == UsageStoreReader.maximumAccounts)
        // Kennungsordnung statt Wörterbuch-Reihenfolge: Zweimal dasselbe
        // Ergebnis, sonst wechselte die Anzeige bei jedem Lauf.
        #expect(firstSnapshot.accounts.map(\.id) == secondSnapshot.accounts.map(\.id))
    }

    @Test("Ein überlanger Alias wird beschnitten, nicht verworfen")
    func longAliasIsTruncated() {
        let long = String(repeating: "x", count: AccountSequenceReader.maximumAliasLength + 100)
        let json = #"{"activeAccountNumber": 1, "accounts": {"1": {"alias": "\#(long)"}}}"#

        let info = AccountSequenceReader.decode(Data(json.utf8))

        #expect(info.aliases["1"]?.count == AccountSequenceReader.maximumAliasLength)
    }

    @Test("Zu viele Accounts werden gedeckelt, und zwar immer dieselben")
    func accountsAreCapped() {
        let count = AccountSequenceReader.maximumAccounts + 20
        let entries = (1...count)
            .map { #""\#($0)": {"alias": "a\#($0)"}"# }
            .joined(separator: ",")
        let json = #"{"activeAccountNumber": 1, "accounts": {\#(entries)}}"#

        let first = AccountSequenceReader.decode(Data(json.utf8))
        let second = AccountSequenceReader.decode(Data(json.utf8))

        #expect(first.aliases.count == AccountSequenceReader.maximumAccounts)
        // Kennungsordnung statt Wörterbuch-Reihenfolge: Zweimal dasselbe
        // Ergebnis, sonst wechselte die Anzeige bei jedem Lauf.
        #expect(first.aliases == second.aliases)
        #expect(first.aliases["1"] == "a1")
    }

    @Test("Die Grenzen greifen erst jenseits realer Datenmengen")
    func realisticDataIsUntouched() {
        // claude-swap liefert real eine Handvoll Fenster und Accounts. Die
        // Grenzen dürfen im Normalfall nie sichtbar werden.
        let json = #"""
        {"activeAccountNumber": 2,
         "accounts": {"1": {"alias": "kurz"}, "2": {"alias": "auch-kurz"}, "3": {}}}
        """#

        let info = AccountSequenceReader.decode(Data(json.utf8))

        #expect(info.activeAccountID == "2")
        #expect(info.aliases == ["1": "kurz", "2": "auch-kurz"])
    }
}
