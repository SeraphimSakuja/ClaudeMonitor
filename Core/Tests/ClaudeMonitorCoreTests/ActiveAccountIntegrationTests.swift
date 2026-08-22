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
        // Beide Slots mit voller Identität: Sonst prüfte dieser Test seit der
        // Mengenregel etwas anderes als vorher — Account „1" wäre gefiltert.
        let sequenceData = Data("""
        {"activeAccountNumber": 2,
         "accounts": {
           "1": {"email": "user1@example.com",
                 "organizationUuid": "00000000-0000-4000-8000-000000000001"},
           "2": {"email": "user2@example.com",
                 "organizationUuid": "00000000-0000-4000-8000-000000000002",
                 "alias": "second"}
         }}
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

    // MARK: - Regel: sequence.json bestimmt, WELCHE Accounts es gibt

    /// Die Identitäten der beiden Accounts aus `usage_real_format`.
    private static let identity1 = AccountIdentity(
        email: "user1@example.com",
        organizationUuid: "00000000-0000-4000-8000-000000000001"
    )
    private static let identity2 = AccountIdentity(
        email: "user2@example.com",
        organizationUuid: "00000000-0000-4000-8000-000000000002"
    )

    private func knowing(
        _ known: [String: AccountIdentity]?,
        active: String? = nil,
        aliases: [String: String] = [:]
    ) -> AccountSequenceInfo {
        AccountSequenceInfo(activeAccountID: active, aliases: aliases, knownAccounts: known)
    }

    private func visibleIdentifiers(_ sequence: AccountSequenceInfo) throws -> [String] {
        try #require(
            reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now, sequence: sequence)
                .snapshot
        ).accounts.map(\.id)
    }

    @Test("Ein Slot, den claude-swap nicht mehr führt, verschwindet")
    func unknownSlotDisappears() throws {
        // Der beobachtete Fall: `cswap` entfernt den Account, seine Zeile bleibt
        // im Zahlen-Zwischenspeicher stehen und rangiert mit eingefrorenen
        // Werten als „bester Account".
        #expect(try visibleIdentifiers(knowing(["2": Self.identity2])) == ["2"])
    }

    @Test("Slot vorhanden, aber andere E-Mail ⇒ nicht derselbe Account")
    func differentEmailIsADifferentAccount() throws {
        // Nach dem Entfernen aller Accounts vergibt claude-swap die Slot-Nummern
        // wieder von vorn: Unter „1" steht dann jemand anderes.
        let recycled = AccountIdentity(
            email: "someone-else@example.com",
            organizationUuid: Self.identity1.organizationUuid
        )
        #expect(try visibleIdentifiers(knowing(["1": recycled, "2": Self.identity2])) == ["2"])
    }

    @Test("Slot vorhanden, aber andere organizationUuid ⇒ nicht derselbe Account")
    func differentOrganizationIsADifferentAccount() throws {
        // Dieselbe E-Mail in einer anderen Organisation ist ein anderer Account
        // mit eigenen Limits — die Zahlen der alten gehören nicht dorthin.
        let moved = AccountIdentity(
            email: Self.identity1.email,
            organizationUuid: "00000000-0000-4000-8000-000000009999"
        )
        #expect(try visibleIdentifiers(knowing(["1": moved, "2": Self.identity2])) == ["2"])
    }

    @Test("Positiv-Kontrolle: passende Identität bleibt vollständig sichtbar")
    func matchingIdentityStaysUntouched() throws {
        // Ohne diese Kontrolle bestünde ein Filter, der schlicht **alles**
        // ausblendet, sämtliche Prüfungen oben.
        let snapshot = try #require(
            reader.decode(
                try TestSupport.fixtureData("usage_real_format"),
                now: now,
                sequence: knowing(
                    ["1": Self.identity1, "2": Self.identity2],
                    active: "2",
                    aliases: ["1": "first"]
                )
            ).snapshot
        )

        #expect(snapshot.accounts.map(\.id) == ["1", "2"])
        #expect(snapshot.accounts.map(\.fiveHourPercent) == [49.0, 12.5])
        #expect(snapshot.accounts.map(\.sevenDayPercent) == [100.0, 30.0])
        #expect(snapshot.accounts.map(\.isActive) == [false, true])
        #expect(snapshot.accounts.map(\.displayName) == ["first", "user2@example.com"])
    }

    @Test("Sagt die Quelle nichts, wird nicht gefiltert")
    func unknownSetFiltersNothing() throws {
        #expect(try visibleIdentifiers(knowing(nil)) == ["1", "2"])
        #expect(try visibleIdentifiers(.empty) == ["1", "2"])
    }

    @Test("Ein unlesbarer Eintrag in sequence.json filtert nichts")
    func partiallyUnreadableSetFiltersNothing() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // „2" ist unlesbar. Eine Teilmenge {„1"} zu übernehmen hieße, „2" als
        // entfernt auszulegen — dann versteckte ein Tippfehler in der
        // Nebenquelle echte Zahlen.
        let store = try TestSupport.writeStoreLayout(
            in: root,
            usage: try TestSupport.fixtureData("usage_real_format"),
            sequence: Data("""
            {"accounts": {"1": {"email": "user1@example.com"}, "2": "nur ein Text"}}
            """.utf8)
        )

        let snapshot = try #require(reader.read(contentsOf: store, now: now).snapshot)
        #expect(snapshot.accounts.map(\.id) == ["1", "2"])
        #expect(snapshot.accounts.map(\.fiveHourPercent) == [49.0, 12.5])
    }

    @Test("Ein leeres accounts-Objekt blendet alles aus")
    func emptyAccountsObjectHidesEverything() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Genau das schreibt claude-swap beim Erstlauf und nachdem der letzte
        // Account entfernt wurde — dann gibt es wirklich keinen mehr.
        let store = try TestSupport.writeStoreLayout(
            in: root,
            usage: try TestSupport.fixtureData("usage_real_format"),
            sequence: Data("{\"activeAccountNumber\": 1, \"accounts\": {}}".utf8)
        )

        let snapshot = try #require(reader.read(contentsOf: store, now: now).snapshot)
        #expect(snapshot.accounts.isEmpty)
    }

    @Test("Ohne organizationUuid im Eintrag entscheidet allein die E-Mail")
    func missingOrganizationComparesEmailOnly() throws {
        // Alter claude-swap-Stand: Das Feld wird erst bei Gelegenheit
        // nachgefüllt. Ein strenger Vergleich blendete hier einen
        // **existierenden** Account dauerhaft aus.
        let unstated = AccountIdentity(email: Self.identity1.email, organizationUuid: nil)
        #expect(try visibleIdentifiers(knowing(["1": unstated, "2": Self.identity2])) == ["1", "2"])

        // `""` ist dagegen eine Aussage (persönlicher Account) und wird streng
        // verglichen — der Account aus der Fixture trägt eine Organisation.
        let personal = AccountIdentity(email: Self.identity1.email, organizationUuid: "")
        #expect(try visibleIdentifiers(knowing(["1": personal, "2": Self.identity2])) == ["2"])
    }

    @Test("Fehlt das Feld in usage.json, gilt es als leer — wie bei claude-swap selbst")
    func missingOrganizationInStoreCountsAsEmpty() throws {
        let usage = Data("""
        {"schemaVersion": 2,
         "accounts": {"1": {"email": "a@b.c", "lastGood": {"five_hour": {"pct": 10.0}}}}}
        """.utf8)
        let snapshot = try #require(
            reader.decode(
                usage,
                now: now,
                sequence: knowing(["1": AccountIdentity(email: "a@b.c", organizationUuid: "")])
            ).snapshot
        )
        #expect(snapshot.accounts.map(\.id) == ["1"])
    }

    @Test("Auch jenseits von 64 Slots wird richtig gefiltert")
    func filteringSurvivesBeyondTheAliasCap() throws {
        let slots = AccountSequenceReader.maximumAccounts + 40
        // Die beiden echten Accounts liegen bewusst **hinter** dem Alias-Deckel:
        // Ein Deckel auf der Identitätsmenge machte sie zu Unbekannten und
        // blendete sie aus.
        let realIdentifiers = [String(slots - 1), String(slots)]
        let entries = (1...slots)
            .map { "\"\($0)\": {\"email\": \"user\($0)@example.com\", \"organizationUuid\": \"org-\($0)\"}" }
            .joined(separator: ", ")
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = Data("""
        {"schemaVersion": 2, "accounts": {
          "\(realIdentifiers[0])": {"email": "user\(realIdentifiers[0])@example.com",
            "organizationUuid": "org-\(realIdentifiers[0])",
            "lastGood": {"five_hour": {"pct": 10.0}}},
          "\(realIdentifiers[1])": {"email": "user\(realIdentifiers[1])@example.com",
            "organizationUuid": "org-\(realIdentifiers[1])",
            "lastGood": {"five_hour": {"pct": 20.0}}},
          "999": {"email": "ghost@example.com", "organizationUuid": "org-999",
            "lastGood": {"five_hour": {"pct": 1.0}}}
        }}
        """.utf8)
        let store = try TestSupport.writeStoreLayout(
            in: root,
            usage: usage,
            sequence: Data("{\"accounts\": {\(entries)}}".utf8)
        )

        let snapshot = try #require(reader.read(contentsOf: store, now: now).snapshot)
        // Der Geist „999" ist weg, die beiden hohen Slots sind da.
        #expect(snapshot.accounts.map(\.id) == realIdentifiers)
    }
}
