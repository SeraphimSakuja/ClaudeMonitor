import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Das Zusammenspiel beider Quellen: Die Zahlen kommen aus `usage.json`, die
/// Markierung und die Kurznamen aus `sequence.json`.
///
/// Die tragende Zusage steht in den Fehlfällen: **Ein Problem mit
/// `sequence.json` darf die Prozentwerte nie blockieren.**
@Suite("Aktiver Account und Aliase im Lesedurchlauf")
struct ActiveAccountIntegrationTests {

    private let reader = UsageStoreReader()
    private let now = TestSupport.now

    private func sequence(active: String?, aliases: [String: String]) -> AccountSequenceInfo {
        AccountSequenceInfo(activeAccountID: active, aliases: aliases)
    }

    // MARK: - Markierung

    @Test("Genau der Account mit der aktiven Kennung ist markiert")
    func exactlyOneAccountIsActive() throws {
        let snapshot = try #require(
            reader.decode(
                try TestSupport.fixtureData("usage_real_format"),
                now: now,
                sequence: sequence(active: "2", aliases: [:])
            ).snapshot
        )

        #expect(snapshot.accounts.map(\.isActive) == [false, true])
        #expect(snapshot.accounts.filter(\.isActive).count == 1)
    }

    @Test("Eine Kennung, die es in usage.json nicht gibt, markiert niemanden")
    func unknownActiveIdentifierMarksNobody() throws {
        let snapshot = try #require(
            reader.decode(
                try TestSupport.fixtureData("usage_real_format"),
                now: now,
                sequence: sequence(active: "99", aliases: [:])
            ).snapshot
        )

        #expect(snapshot.accounts.contains(where: \.isActive) == false)
        // Und die Zahlen stehen unverändert da — kein Ratefall, kein Verlust.
        #expect(snapshot.accounts.map(\.fiveHourPercent) == [49.0, 12.5])
    }

    // MARK: - Anzeigename: Alias vor E-Mail vor „Account <id>"

    @Test("Alias gewinnt vor der E-Mail")
    func aliasWinsOverEmail() throws {
        let snapshot = try #require(
            reader.decode(
                try TestSupport.fixtureData("usage_real_format"),
                now: now,
                sequence: sequence(active: "1", aliases: ["1": "first"])
            ).snapshot
        )

        #expect(snapshot.accounts[0].displayName == "first")
        // Ohne Alias bleibt es bei der E-Mail.
        #expect(snapshot.accounts[1].displayName == "user2@example.com")
    }

    @Test("Ohne Alias und ohne E-Mail bleibt „Account <id>“")
    func fallsBackToAccountIdentifier() {
        #expect(UsageStoreReader.displayName(id: "3", email: nil, alias: nil) == "Account 3")
        #expect(UsageStoreReader.displayName(id: "3", email: "", alias: nil) == "Account 3")
        // Leerer Alias zählt als nicht vorhanden — dann greift die E-Mail.
        #expect(UsageStoreReader.displayName(id: "3", email: "a@example.com", alias: "") == "a@example.com")
        #expect(UsageStoreReader.displayName(id: "3", email: "a@example.com", alias: "x") == "x")
    }

    // MARK: - Regel 5: kein Einfluss auf Reihenfolge und Ranking

    @Test("Die Markierung ändert weder Ranking noch Kennungsordnung")
    func activeFlagChangesNoOrder() throws {
        let data = try TestSupport.fixtureData("usage_real_format")
        let plain = try #require(reader.decode(data, now: now).snapshot)
        // Account „2" ist der schlechtere (scoped 88 %) und zugleich der aktive.
        let marked = try #require(
            reader.decode(data, now: now, sequence: sequence(active: "2", aliases: [:])).snapshot
        )

        #expect(marked.accounts.map(\.id) == plain.accounts.map(\.id))
        #expect(
            AccountRanking.ranked(marked.accounts, now: now).map(\.id)
                == AccountRanking.ranked(plain.accounts, now: now).map(\.id)
        )
    }

    // MARK: - Regel 1: sequence.json blockiert die Zahlen nie

    @Test("Fehlende sequence.json ⇒ alle Zahlen da, nichts markiert, E-Mail als Name")
    func missingSequenceKeepsEverythingElse() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TestSupport.writeStoreLayout(
            in: root,
            usage: try TestSupport.fixtureData("usage_real_format"),
            sequence: nil
        )

        let result = reader.read(contentsOf: store, now: now)
        let snapshot = try #require(result.snapshot, "Lesen muss trotz fehlender sequence.json gelingen")

        #expect(snapshot.accounts.map(\.fiveHourPercent) == [49.0, 12.5])
        #expect(snapshot.accounts.map(\.sevenDayPercent) == [100.0, 30.0])
        #expect(snapshot.accounts.contains(where: \.isActive) == false)
        #expect(snapshot.accounts.map(\.displayName) == ["user1@example.com", "user2@example.com"])
    }

    @Test("Kaputte sequence.json ⇒ dasselbe wie fehlend, kein Absturz", arguments: [
        "nicht mal JSON {{{",
        "[]",
        "{\"activeAccountNumber\": \"zwei\", \"accounts\": 5}",
        "{\"accounts\": {\"1\": \"nur ein Text\"}}",
        "{\"activeAccountNumber\": 1, \"accou"
    ])
    func brokenSequenceKeepsEverythingElse(_ broken: String) throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TestSupport.writeStoreLayout(
            in: root,
            usage: try TestSupport.fixtureData("usage_real_format"),
            sequence: Data(broken.utf8)
        )

        let snapshot = try #require(reader.read(contentsOf: store, now: now).snapshot)

        #expect(snapshot.accounts.map(\.fiveHourPercent) == [49.0, 12.5])
        #expect(snapshot.accounts.contains(where: \.isActive) == false)
        #expect(snapshot.accounts.map(\.displayName) == ["user1@example.com", "user2@example.com"])
    }

    @Test("Beim Lesen über die Fundstelle wird die Geschwisterdatei mitgenommen")
    func readMergesSequenceFromDisk() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sequenceData = Data("""
        {"activeAccountNumber": 2, "accounts": {"2": {"alias": "second"}}}
        """.utf8)
        let store = try TestSupport.writeStoreLayout(
            in: root,
            usage: try TestSupport.fixtureData("usage_real_format"),
            sequence: sequenceData
        )

        let snapshot = try #require(reader.read(contentsOf: store, now: now).snapshot)

        #expect(snapshot.accounts.map(\.isActive) == [false, true])
        #expect(snapshot.accounts.map(\.displayName) == ["user1@example.com", "second"])
    }
}
