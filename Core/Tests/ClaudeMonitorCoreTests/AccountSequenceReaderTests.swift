import Foundation
import Testing
@testable import ClaudeMonitorCore

/// `sequence.json` ist **Beiwerk**: Sie sagt, welcher Account aktiv ist und wie
/// die Accounts kurz heißen. Fehlt oder misslingt sie, laufen die Zahlen aus
/// `usage.json` unverändert weiter.
@Suite("AccountSequenceReader — aktiver Account und Aliase")
struct AccountSequenceReaderTests {

    /// Anonymisierte Fassung des echten Aufbaus: Kennungen als Strings, die
    /// aktive Nummer als Zahl, ein Account ohne Alias.
    private func sequenceJSON(active: String = "1") -> Data {
        Data("""
        {
          "activeAccountNumber": \(active),
          "lastUpdated": "2026-08-08T07:39:09Z",
          "sequence": [1, 2, 3],
          "accounts": {
            "1": {"email": "user1@example.com", "alias": "first"},
            "2": {"email": "user2@example.com", "alias": "second"},
            "3": {"email": "user3@example.com"}
          }
        }
        """.utf8)
    }

    // MARK: - Aufbau lesen

    @Test("Aktiver Account und Aliase werden gelesen")
    func readsActiveAndAliases() {
        let info = AccountSequenceReader.decode(sequenceJSON())

        #expect(info.activeAccountID == "1")
        #expect(info.isActive("1"))
        #expect(info.isActive("2") == false)
        #expect(info.alias(for: "1") == "first")
        #expect(info.alias(for: "2") == "second")
        // Account 3 hat real keinen Alias — dann steht hier auch keiner.
        #expect(info.alias(for: "3") == nil)
    }

    @Test("Die Zahl activeAccountNumber wird zur Kennung String(activeAccountNumber)")
    func numberBecomesStringIdentifier() {
        #expect(AccountSequenceReader.decode(sequenceJSON(active: "2")).activeAccountID == "2")
        #expect(AccountSequenceReader.decode(sequenceJSON(active: "12")).activeAccountID == "12")
    }

    @Test("Leerer oder nur aus Leerzeichen bestehender Alias zählt als nicht vorhanden")
    func blankAliasIsNoAlias() {
        let data = Data("""
        {"activeAccountNumber": 1,
         "accounts": {"1": {"alias": ""}, "2": {"alias": "   "}, "3": {"alias": " third "}}}
        """.utf8)
        let info = AccountSequenceReader.decode(data)

        #expect(info.alias(for: "1") == nil)
        #expect(info.alias(for: "2") == nil)
        // Umgebende Leerzeichen werden beschnitten, der Name bleibt.
        #expect(info.alias(for: "3") == "third")
    }

    // MARK: - Fehlfälle: alle enden bei `empty`

    @Test("Kein JSON ⇒ nichts bekannt, kein Absturz")
    func garbageIsEmpty() {
        #expect(AccountSequenceReader.decode(Data("nicht mal JSON {{{".utf8)) == .empty)
    }

    @Test("Halb geschriebener Stand ⇒ nichts bekannt")
    func truncatedIsEmpty() {
        let full = sequenceJSON()
        let half = full.prefix(full.count / 2)
        #expect(AccountSequenceReader.decode(Data(half)) == .empty)
    }

    @Test("Unerwarteter Aufbau ⇒ nichts bekannt")
    func unexpectedShapeIsEmpty() {
        #expect(AccountSequenceReader.decode(Data("[1, 2, 3]".utf8)) == .empty)
        // `accounts` als Liste statt als Objekt: keine Aliase, aber auch kein
        // Fehler — die aktive Kennung bleibt trotzdem gültig.
        let info = AccountSequenceReader.decode(
            Data("{\"activeAccountNumber\": 2, \"accounts\": [\"1\", \"2\"]}".utf8)
        )
        #expect(info.activeAccountID == "2")
        #expect(info.aliases.isEmpty)
    }

    @Test("activeAccountNumber fehlt oder ist keine ganze Zahl ⇒ kein aktiver Account")
    func unusableActiveNumberIsNil() {
        let cases = [
            "{\"accounts\": {}}",                           // fehlt ganz
            "{\"activeAccountNumber\": null}",              // ausdrücklich leer
            "{\"activeAccountNumber\": \"2\"}",             // Text statt Zahl
            "{\"activeAccountNumber\": true}",              // Wahrheitswert (käme als 1 durch)
            "{\"activeAccountNumber\": 2.5}",               // keine Kennung
            // Ganzzahlig und endlich, aber weit außerhalb von `Int`:
            // `number.intValue` lieferte hier einen
            // implementierungsdefinierten Wert — also eine Fantasie-Kennung,
            // die zufällig auf einen echten Account zeigen könnte.
            "{\"activeAccountNumber\": 1e30}",
            "{\"activeAccountNumber\": -1e30}"
        ]
        for json in cases {
            #expect(
                AccountSequenceReader.decode(Data(json.utf8)).activeAccountID == nil,
                "unerwartet eine Kennung aus: \(json)"
            )
        }
    }

    @Test("Ein Alias ohne aktiven Account bleibt trotzdem nutzbar")
    func aliasesSurviveMissingActiveNumber() {
        let info = AccountSequenceReader.decode(Data("{\"accounts\": {\"1\": {\"alias\": \"a\"}}}".utf8))
        #expect(info.activeAccountID == nil)
        #expect(info.alias(for: "1") == "a")
    }

    // MARK: - Pfadableitung und Dateizugriff

    @Test("Der Pfad wird aus der gefundenen usage.json abgeleitet, nicht gesucht")
    func pathIsDerivedFromStore() {
        let store = URL(fileURLWithPath: "/somewhere/.claude-swap-backup/cache/usage.json")
        #expect(
            UsageStoreLocator.sequenceURL(forStoreAt: store)?.path
                == "/somewhere/.claude-swap-backup/sequence.json"
        )
        // Gilt genauso für die XDG-Fundstelle — die Ableitung kennt keine
        // Sonderfälle, sie geht vom `cache`-Verzeichnis eine Ebene hoch.
        let xdg = URL(fileURLWithPath: "/data/claude-swap/cache/usage.json")
        #expect(UsageStoreLocator.sequenceURL(forStoreAt: xdg)?.path == "/data/claude-swap/sequence.json")
    }

    @Test("Liegt die usage.json nicht in einem cache-Verzeichnis, wird nichts abgeleitet")
    func pathIsNotDerivedOutsideCacheDirectory() {
        // Verschöbe claude-swap die Datei, läse eine blinde Zwei-Ebenen-
        // Ableitung still eine **fremde** sequence.json — Marker und Aliase
        // kämen aus der falschen Installation.
        for path in [
            "/somewhere/.claude-swap-backup/usage.json",
            "/somewhere/.claude-swap-backup/state/usage.json",
            "/somewhere/Caches/usage.json",
            "/usage.json"
        ] {
            #expect(
                UsageStoreLocator.sequenceURL(forStoreAt: URL(fileURLWithPath: path)) == nil,
                "unerwartet abgeleitet aus: \(path)"
            )
        }
        // Und der Leser antwortet darauf mit „nichts bekannt" — nicht mit
        // einem Fehler: Ein Problem mit sequence.json blockiert nie die Zahlen.
        #expect(
            AccountSequenceReader.read(
                forStoreAt: URL(fileURLWithPath: "/somewhere/.claude-swap-backup/usage.json")
            ) == .empty
        )
    }

    @Test("Die Datei neben dem Cache-Verzeichnis wird wirklich gelesen")
    func readsSiblingFile() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TestSupport.writeStoreLayout(in: root, sequence: sequenceJSON(active: "3"))

        let info = AccountSequenceReader.read(forStoreAt: store)
        #expect(info.activeAccountID == "3")
        #expect(info.alias(for: "1") == "first")
    }

    @Test("Fehlende Datei ⇒ nichts bekannt, kein Fehler")
    func missingFileIsEmpty() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TestSupport.writeStoreLayout(in: root, sequence: nil)

        #expect(AccountSequenceReader.read(forStoreAt: store) == .empty)
    }
}
