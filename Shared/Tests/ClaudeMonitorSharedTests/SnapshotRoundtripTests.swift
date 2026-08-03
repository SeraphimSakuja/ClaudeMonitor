import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Der Vertrag mit der Widget-Extension aus Teilaufgabe 3.
///
/// Bricht er, zeigt das Widget stillschweigend nichts an — es gibt dort keine
/// Fehlermeldung, nur eine leere Kachel. Deshalb wird hier gegen genau den Weg
/// geprüft, den die Extension gehen wird: Datei aus dem Container lesen und
/// über ``SnapshotCoding`` dekodieren.
@Suite("Snapshot-Roundtrip App → App-Group → Widget")
struct SnapshotRoundtripTests {

    private func richSnapshot() -> AccountsSnapshot {
        let reset = Fixture.now.addingTimeInterval(3_600)
        // Sekundenbruchteile absichtlich drin: Eine verlustbehaftete
        // Datumsstrategie (z. B. ISO-8601 ohne Bruchteile) fiele hier auf.
        let fetched = Date(timeIntervalSince1970: 1_799_999_876.5)
        return Fixture.snapshot([
            Fixture.account(
                id: "1",
                name: "account-a",
                windows: [
                    Fixture.window(.fiveHour, percent: 42.5, resetsAt: reset),
                    Fixture.window(.sevenDay, percent: 61, resetsAt: reset.addingTimeInterval(86_400)),
                    Fixture.window(.scoped(name: "Modell X"), percent: 7.25, resetsAt: nil),
                    LimitWindow(
                        id: "spend",
                        kind: .spend,
                        label: "Spend",
                        percent: 12,
                        resetsAt: reset,
                        spend: LimitWindow.SpendDetail(used: 3.5, limit: 30, currency: "USD")
                    ),
                    Fixture.window(.other(rawKey: "future_window"), percent: 0)
                ],
                fetchedAt: fetched,
                nextPollAt: fetched.addingTimeInterval(30),
                state: .ok
            ),
            Fixture.account(id: "2", name: "account-b", windows: [], fetchedAt: nil, state: .noData),
            Fixture.account(id: "3", name: "account-c", state: .authDead(strikes: 1)),
            Fixture.account(id: "4", name: "account-d", state: .backoff(until: Fixture.now.addingTimeInterval(120))),
            Fixture.account(id: "5", name: "account-e", state: .failing(message: "boom"))
        ])
    }

    @Test("Geschriebene Datei ergibt einen identischen Snapshot")
    func roundtripThroughContainerFile() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SnapshotStore(groupIdentifier: "group.test", fileName: "snapshot.json")
        let original = richSnapshot()

        let result = writer.write(original, into: directory)
        guard case .written(let url) = result else {
            Issue.record("Schreiben fehlgeschlagen: \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let decoded = try writer.read(from: directory)
        #expect(decoded == original)
    }

    @Test("Alle Zustände und Fenstertypen überleben das Kodieren")
    func roundtripPreservesStatesAndWindows() throws {
        let original = richSnapshot()
        let decoded = try SnapshotCoding.decode(try SnapshotCoding.encode(original))

        #expect(decoded.accounts.map(\.state) == original.accounts.map(\.state))
        #expect(decoded.accounts[0].windows.map(\.kind) == original.accounts[0].windows.map(\.kind))
        #expect(decoded.accounts[0].windows.map(\.percent) == original.accounts[0].windows.map(\.percent))
        #expect(decoded.accounts[0].fetchedAt == original.accounts[0].fetchedAt)
        #expect(decoded.accounts[0].windows[3].spend == original.accounts[0].windows[3].spend)
    }

    @Test("Layout-Version wird mitgeschrieben")
    func formatVersionIsCarried() throws {
        let data = try SnapshotCoding.encode(richSnapshot())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["formatVersion"] as? Int == AccountsSnapshot.currentFormatVersion)
    }

    @Test("Ein zweiter Schreibvorgang ersetzt die Datei vollständig")
    func rewriteReplacesFile() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SnapshotStore(groupIdentifier: "group.test", fileName: "snapshot.json")

        writer.write(richSnapshot(), into: directory)
        let smaller = Fixture.snapshot([Fixture.account(id: "9", name: "account-z")])
        writer.write(smaller, into: directory)

        #expect(try writer.read(from: directory) == smaller)
    }

    @Test("Ein nicht beschreibbares Ziel ist ein definierter Zustand, kein Absturz")
    func unwritableTargetIsHandled() throws {
        // Bewusst KEIN Test gegen `write(_:)` ohne Verzeichnis: Diese Fassung
        // fragt `containerURL(forSecurityApplicationGroupIdentifier:)` und damit
        // `~/Library/Group Containers/…`. Ein nicht sandboxed Prozess löst dort
        // den macOS-Zustimmungsdialog „Zugriff auf Daten anderer Apps" aus —
        // im Testlauf unsichtbar, der Prozess blockiert dann endlos.
        // Geprüft wird stattdessen der Fehlerpfad an einem echten Verzeichnis.
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(groupIdentifier: "group.test", fileName: "snapshot.json")

        // Eine Datei dort, wo das Verzeichnis liegen müsste: Schreiben muss
        // scheitern — und zwar geordnet.
        let blocked = directory.appendingPathComponent("blocked", isDirectory: false)
        try Data("belegt".utf8).write(to: blocked)

        let result = store.write(Fixture.snapshot([]), into: blocked)
        guard case .failed = result else {
            Issue.record("Erwartet wurde ein definierter Fehlzustand, bekommen: \(result)")
            return
        }
    }
}
