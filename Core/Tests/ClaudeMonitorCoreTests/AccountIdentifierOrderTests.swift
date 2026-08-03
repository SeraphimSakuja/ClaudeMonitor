import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("AccountIdentifierOrder — eine Ordnung für alle Stellen")
struct AccountIdentifierOrderTests {

    @Test("Slot-Schlüssel werden numerisch sortiert, nicht lexikografisch")
    func numericOrder() {
        let ids = ["10", "2", "1", "11", "3"]
        let sorted = ids.sorted(by: AccountIdentifierOrder.isOrderedBefore)
        #expect(sorted == ["1", "2", "3", "10", "11"])
        // Gegenprobe: rein lexikografisch käme etwas anderes heraus.
        #expect(ids.sorted() == ["1", "10", "11", "2", "3"])
    }

    @Test("Reader und Ranking benutzen dieselbe Ordnung")
    func readerAndRankingAgree() throws {
        var accounts: [String: String] = [:]
        for index in 1...11 {
            accounts["\(index)"] = """
            { "email": "user\(index)@example.com",
              "lastGood": { "five_hour": { "pct": 40.0 } },
              "fetchedAt": 1754230000.0 }
            """
        }
        let json = "{ \"schemaVersion\": 2, \"accounts\": { "
            + accounts.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
            + " } }"
        let snapshot = try #require(
            UsageStoreReader().decode(Data(json.utf8), now: TestSupport.now).snapshot
        )
        let expected = (1...11).map(String.init)
        #expect(snapshot.accounts.map(\.id) == expected)
        #expect(snapshot.rankedAccounts(now: TestSupport.now).map(\.id) == expected)
    }

    @Test("Führende Nullen sind zahlenmäßig gleich, die Ordnung bleibt trotzdem total")
    func leadingZeros() {
        // Gleicher Zahlenwert — entschieden wird erst am Ende über die
        // Schreibweise, die kürzere zuerst. Wichtig ist nur: total und stabil.
        #expect(AccountIdentifierOrder.compare("1", "01") == .orderedAscending)
        #expect(AccountIdentifierOrder.compare("01", "1") == .orderedDescending)
        #expect(AccountIdentifierOrder.compare("1", "1") == .orderedSame)
    }

    @Test("Text und gemischte Kennungen werden deterministisch verglichen")
    func mixedIdentifiers() {
        let ids = ["slot2", "slot10", "slot1", "alpha", "2", "beta10", "beta9"]
        let sorted = ids.sorted(by: AccountIdentifierOrder.isOrderedBefore)
        #expect(sorted == ["2", "alpha", "beta9", "beta10", "slot1", "slot2", "slot10"])
        #expect(sorted == ids.reversed().sorted(by: AccountIdentifierOrder.isOrderedBefore))
    }

    @Test("Präfix sortiert vor der längeren Kennung")
    func prefixFirst() {
        #expect(AccountIdentifierOrder.isOrderedBefore("acc", "account"))
        #expect(AccountIdentifierOrder.isOrderedBefore("account", "acc") == false)
    }

    @Test("Die Ordnung ist locale-frei und damit reproduzierbar")
    func localeFree() {
        // localizedStandardCompare hängt an der System-Locale; unsere Ordnung darf
        // für dieselben Eingaben immer dasselbe liefern.
        let ids = ["ä", "a", "z", "10", "2"]
        let first = ids.sorted(by: AccountIdentifierOrder.isOrderedBefore)
        for _ in 0..<5 {
            #expect(ids.shuffled().sorted(by: AccountIdentifierOrder.isOrderedBefore) == first)
        }
        #expect(first.first == "2")   // Zahlen zuerst, unabhängig von der Locale
    }

    @Test("Die Ordnung ist irreflexiv, asymmetrisch und transitiv")
    func strictWeakOrdering() {
        let ids = ["1", "01", "2", "10", "a", "a1", "a01", "a10", "", "b", "1a"]
        for a in ids {
            #expect(AccountIdentifierOrder.isOrderedBefore(a, a) == false)
            for b in ids where AccountIdentifierOrder.isOrderedBefore(a, b) {
                #expect(AccountIdentifierOrder.isOrderedBefore(b, a) == false)
            }
        }
        for a in ids {
            for b in ids {
                for c in ids {
                    if AccountIdentifierOrder.isOrderedBefore(a, b),
                       AccountIdentifierOrder.isOrderedBefore(b, c) {
                        #expect(AccountIdentifierOrder.isOrderedBefore(a, c))
                    }
                }
            }
        }
    }
}
