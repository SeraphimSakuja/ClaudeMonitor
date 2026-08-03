import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("UsageStoreReader — Quellformat von claude-swap")
struct UsageStoreReaderTests {

    private let reader = UsageStoreReader()
    private let now = TestSupport.now

    // MARK: - Echtes Format

    @Test("Echtes Format wird vollständig gelesen")
    func realFormat() throws {
        let result = reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now)
        let snapshot = try #require(result.snapshot)

        #expect(snapshot.sourceSchemaVersion == ClaudeMonitorCore.supportedSchemaVersion)
        #expect(snapshot.capturedAt == now)
        #expect(snapshot.accounts.map(\.id) == ["1", "2"])

        let first = snapshot.accounts[0]
        #expect(first.displayName == "user1@example.com")
        #expect(first.state == .ok)
        #expect(first.fiveHourPercent == 49.0)
        #expect(first.sevenDayPercent == 100.0)
        #expect(first.fetchedAt == Date(timeIntervalSince1970: 1_754_230_000))
        #expect(first.hasUsableData)
    }

    @Test("resets_at mit Mikrosekunden wird auf den exakten Zeitpunkt geparst")
    func parsesMicroseconds() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now).snapshot
        )
        let fiveHour = try #require(snapshot.accounts[0].window(kind: .fiveHour))
        let resetsAt = try #require(fiveHour.resetsAt)

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 3
        components.hour = 16; components.minute = 50; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try #require(calendar.date(from: components)).addingTimeInterval(0.191)

        // Ohne Kürzung des Bruchteils läge der Wert um über drei Minuten daneben.
        #expect(abs(resetsAt.timeIntervalSince(expected)) < 0.001)
    }

    @Test("countdown und clock werden verworfen — Restzeit kommt live aus resets_at")
    func discardsFrozenStrings() throws {
        let data = try TestSupport.fixtureData("usage_real_format")
        let json = try #require(String(data: data, encoding: .utf8))
        // Gegenprobe: Die Fixture enthält die eingefrorenen Strings wirklich …
        #expect(json.contains("\"countdown\""))
        #expect(json.contains("\"clock\""))

        // … das Modell trägt sie aber nirgends weiter.
        let snapshot = try #require(reader.decode(data, now: now).snapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
        #expect(encodedJSON.contains("countdown") == false)
        #expect(encodedJSON.contains("2h 44m") == false)
        #expect(encodedJSON.contains("18:50") == false)
    }

    @Test("scoped-Array wird zu n benannten Fenstern")
    func scopedWindows() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now).snapshot
        )
        let account = snapshot.accounts[1]
        let scoped = account.windows.filter {
            if case .scoped = $0.kind { return true }
            return false
        }
        #expect(scoped.count == 2)
        #expect(scoped.map(\.label).sorted() == ["Fable", "Sonnet"])
        #expect(account.window(kind: .scoped(name: "Fable"))?.percent == 88.0)
        #expect(account.window(kind: .scoped(name: "Fable"))?.status == .red)
        #expect(account.window(kind: .scoped(name: "Sonnet"))?.status == .green)
    }

    @Test("spend-Fenster inklusive Betragsdetails")
    func spendWindow() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now).snapshot
        )
        let spend = try #require(snapshot.accounts[1].window(kind: .spend))
        #expect(spend.percent == 16.8)
        #expect(spend.spend?.used == 4.2)
        #expect(spend.spend?.limit == 25.0)
        #expect(spend.spend?.currency == "USD")
    }

    @Test("Fensterreihenfolge ist stabil, obwohl JSON-Objekte ungeordnet sind")
    func stableWindowOrder() throws {
        let data = try TestSupport.fixtureData("usage_real_format")
        for _ in 0..<5 {
            let snapshot = try #require(reader.decode(data, now: now).snapshot)
            let kinds = snapshot.accounts[1].windows.map(\.kind)
            #expect(kinds == [
                .fiveHour, .sevenDay, .spend,
                .scoped(name: "Fable"), .scoped(name: "Sonnet")
            ])
        }
    }

    @Test("Mehr als zwei Fenster werden getragen")
    func carriesNWindows() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now).snapshot
        )
        #expect(snapshot.accounts[1].windows.count == 5)
    }

    // MARK: - Zustände

    @Test("lastGood fehlt oder ist null ⇒ noch keine Daten, nicht 0 %")
    func lastGoodNull() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_last_good_null"), now: now).snapshot
        )
        for account in snapshot.accounts {
            #expect(account.state == .noData)
            #expect(account.windows.isEmpty)
            #expect(account.hasUsableData == false)
            #expect(account.fiveHourPercent == nil)     // kein 0 %
            #expect(account.overallStatus == nil)       // keine Ampel ohne Daten
        }
    }

    @Test("authDeadStrikes über der Schwelle ⇒ toter Token")
    func authDead() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_states"), now: now).snapshot
        )
        let account = try #require(snapshot.accounts.first { $0.id == "1" })
        #expect(account.state == .authDead(strikes: 3))
        #expect(account.hasUsableData == false)
    }

    @Test("backoffUntil in der Zukunft ⇒ Backoff aktiv")
    func backoffActive() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_states"), now: now).snapshot
        )
        let account = try #require(snapshot.accounts.first { $0.id == "2" })
        #expect(account.state == .backoff(until: Date(timeIntervalSince1970: 1_754_233_600)))
        #expect(account.hasUsableData)
    }

    @Test("backoffUntil in der Vergangenheit ist kein Backoff mehr")
    func backoffExpired() throws {
        let later = Date(timeIntervalSince1970: 1_754_240_000)
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_states"), now: later).snapshot
        )
        let account = try #require(snapshot.accounts.first { $0.id == "2" })
        #expect(account.state == .failing(message: "http 429"))
    }

    @Test("lastError ohne Backoff ⇒ Fehlversuch, Daten bleiben nutzbar")
    func failingState() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_states"), now: now).snapshot
        )
        let account = try #require(snapshot.accounts.first { $0.id == "3" })
        #expect(account.state == .failing(message: "http 500"))
        #expect(account.hasUsableData)
    }

    // MARK: - Defensives Decodieren

    @Test("Unbekannte Felder werden ignoriert, unbekannte Fenstertypen getragen")
    func unknownFields() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_unknown_fields"), now: now).snapshot
        )
        let account = try #require(snapshot.accounts.first)
        #expect(account.state == .ok)
        #expect(account.fiveHourPercent == 20.0)

        let unknown = try #require(account.window(kind: .other(rawKey: "thirty_day")))
        #expect(unknown.percent == 61.5)
        #expect(unknown.label == "thirty_day")
        // Unbekannte Fenster sortieren hinter die bekannten.
        #expect(account.windows.map(\.kind) == [.fiveHour, .other(rawKey: "thirty_day")])
    }

    @Test("Felder mit falschem Typ kippen nicht den ganzen Account")
    func wrongFieldTypes() throws {
        let json = """
        {
          "schemaVersion": 2,
          "accounts": {
            "1": {
              "email": 42,
              "lastGood": {
                "five_hour": { "pct": 33.0, "resets_at": "2026-08-03T16:50:00.000000+00:00" },
                "seven_day": { "pct": "kaputt", "resets_at": 12345 }
              },
              "fetchedAt": "gestern",
              "authDeadStrikes": null,
              "lastError": { "code": 500 }
            }
          }
        }
        """
        let snapshot = try #require(reader.decode(Data(json.utf8), now: now).snapshot)
        let account = try #require(snapshot.accounts.first)
        #expect(account.displayName == "Account 1")   // email unbrauchbar → Fallback
        #expect(account.fiveHourPercent == 33.0)      // brauchbares Fenster bleibt
        #expect(account.sevenDayPercent == nil)       // unbrauchbares Fenster entfällt
        #expect(account.fetchedAt == nil)
        #expect(account.state == .ok)
    }

    // MARK: - Fehlfälle

    @Test("Abweichende schemaVersion wird hart abgelehnt")
    func wrongSchemaVersion() throws {
        let result = reader.decode(try TestSupport.fixtureData("usage_wrong_schema"), now: now)
        #expect(result == .unsupportedSchemaVersion(found: 3, expected: 2))
        // Keine stille Teilinterpretation.
        #expect(result.snapshot == nil)
    }

    @Test("Fehlende schemaVersion wird ebenfalls abgelehnt")
    func missingSchemaVersion() throws {
        let result = reader.decode(Data("{\"accounts\":{}}".utf8), now: now)
        #expect(result == .unsupportedSchemaVersion(found: nil, expected: 2))
    }

    @Test("Kaputtes JSON ergibt einen definierten Fehlzustand")
    func brokenJSON() throws {
        let result = reader.decode(try TestSupport.fixtureData("usage_broken"), now: now)
        guard case .unreadable = result else {
            Issue.record("Erwartet .unreadable, war \(result)")
            return
        }
    }

    @Test("Fehlende Store-Datei ergibt „claude-swap nicht gefunden“")
    func storeNotFound() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ClaudeMonitorTests-\(UUID().uuidString)/usage.json")
        let result = reader.read(contentsOf: missing, now: now)
        #expect(result == .storeNotFound(searchedPaths: [missing.path]))
    }

    @Test("Suche liefert alle Kandidatenpfade, wenn nichts gefunden wird")
    func locatorReportsCandidates() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ClaudeMonitorHome-\(UUID().uuidString)")
        let result = reader.read(
            environment: ["XDG_DATA_HOME": "/nirgendwo"],
            homeDirectory: home,
            now: now
        )
        guard case .storeNotFound(let paths) = result else {
            Issue.record("Erwartet .storeNotFound, war \(result)")
            return
        }
        #expect(paths.count == 3)
        #expect(paths[0].hasSuffix(UsageStoreLocator.macRelativePath))
        #expect(paths[1] == "/nirgendwo/" + UsageStoreLocator.xdgRelativePath)
        #expect(paths[2].hasSuffix(".local/share/" + UsageStoreLocator.xdgRelativePath))
    }

    // MARK: - Dateizugriff

    @Test("Liest eine echte Datei, ohne sie zu verändern")
    func readsFileReadOnly() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ClaudeMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "usage.json")
        let original = try TestSupport.fixtureData("usage_real_format")
        try original.write(to: file)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: file.path)

        let result = reader.read(contentsOf: file, now: now)
        #expect(result.snapshot?.accounts.count == 2)

        #expect(try Data(contentsOf: file) == original)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(
            attributesBefore[.modificationDate] as? Date == attributesAfter[.modificationDate] as? Date
        )
    }

    // MARK: - Snapshot-Transport

    @Test("Snapshot überlebt den JSON-Roundtrip in den App-Group-Container")
    func snapshotRoundtrip() throws {
        let snapshot = try #require(
            reader.decode(try TestSupport.fixtureData("usage_real_format"), now: now).snapshot
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AccountsSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}
