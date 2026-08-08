import Foundation
import Testing
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Die Auszeichnung des in claude-swap aktiven Accounts.
///
/// Sie ist reine Anzeige: Sie darf keine Auswahl treffen, keine Reihenfolge
/// ändern und kein Segment am Leben halten, das nichts zu sagen hat.
@Suite("Aktiver Account in der Anzeige")
struct ActiveAccountDisplayTests {

    private func state(_ accounts: [MonitoredAccount]) -> MonitorViewState {
        MonitorViewState(snapshot: Fixture.snapshot(accounts), isLoading: false)
    }

    private func account(_ id: String, percent: Double, isActive: Bool = false) -> MonitoredAccount {
        Fixture.account(
            id: id,
            name: "account-\(id)",
            windows: [
                Fixture.window(.fiveHour, percent: percent),
                Fixture.window(.sevenDay, percent: percent / 2)
            ],
            isActive: isActive
        )
    }

    // MARK: - Markierung

    @Test("Genau der aktive Account trägt die Markierung")
    func exactlyTheActiveSegmentIsMarked() {
        let accounts = [
            account("1", percent: 30),
            account("2", percent: 40, isActive: true),
            account("3", percent: 50)
        ]
        let display = MenuBarDisplay.make(for: state(accounts), mode: .allAccounts, now: Fixture.now)

        #expect(display.segments.map(\.isActive) == [false, true, false])
        #expect(display.segments.filter(\.isActive).count == 1)
        #expect(display.segments.map(\.markerText) == [nil, "▸", nil])
        #expect(ActiveAccountDisplay.marker == "▸")
    }

    @Test("Ohne aktiven Account trägt niemand eine Markierung")
    func nothingIsMarkedWithoutSequenceData() {
        // Genau der Zustand bei fehlender oder kaputter `sequence.json`.
        let accounts = [account("1", percent: 30), account("2", percent: 40)]
        let display = MenuBarDisplay.make(for: state(accounts), mode: .allAccounts, now: Fixture.now)

        #expect(display.segments.contains(where: \.isActive) == false)
        #expect(display.segments.compactMap(\.markerText).isEmpty)
        // … und die Zahlen stehen trotzdem vollständig da.
        #expect(display.segments.map(\.numbersText) == ["30/15", "40/20"])
    }

    @Test("Die Markierung gilt in beiden Modi")
    func markerAppliesInBothModes() {
        // Der aktive Account ist zugleich der beste — im Modus „nur bester"
        // ist er der einzige gezeigte und muss ebenso ausgezeichnet sein.
        let accounts = [account("1", percent: 5, isActive: true), account("2", percent: 90)]

        for mode in MenuBarMode.allCases {
            let display = MenuBarDisplay.make(for: state(accounts), mode: mode, now: Fixture.now)
            let marked = display.segments.filter(\.isActive)
            #expect(marked.map(\.id) == ["1"], "Modus \(mode): aktiver Account nicht markiert")
        }
    }

    @Test("Im Modus „nur bester“ bleibt ein nicht gezeigter aktiver Account außen vor")
    func inactiveModeShowsOnlyTheBest() {
        // Der aktive ist hier der schlechtere: Die Markierung darf ihn nicht
        // in die Leiste holen — sie zeichnet aus, sie wählt nicht.
        let accounts = [account("1", percent: 5), account("2", percent: 90, isActive: true)]
        let display = MenuBarDisplay.make(for: state(accounts), mode: .bestAccount, now: Fixture.now)

        #expect(display.segments.map(\.id) == ["1"])
        #expect(display.segments.contains(where: \.isActive) == false)
    }

    @Test("Die Markierung ändert die Reihenfolge in der Leiste nicht")
    func markerDoesNotReorder() {
        func ids(activeIndex: Int?) -> [String] {
            let accounts = ["1", "2", "10"].enumerated().map { index, id in
                account(id, percent: Double(index * 10 + 5), isActive: index == activeIndex)
            }
            return MenuBarDisplay
                .make(for: state(accounts), mode: .allAccounts, now: Fixture.now)
                .segments.map(\.id)
        }

        #expect(ids(activeIndex: nil) == ["1", "2", "10"])
        #expect(ids(activeIndex: 2) == ["1", "2", "10"])
        #expect(ids(activeIndex: 0) == ["1", "2", "10"])
    }

    @Test("Ein aktiver Account ohne Daten hält die Leiste nicht am Leben")
    func activeWithoutDataStaysSilent() {
        let accounts = [
            Fixture.account(id: "1", name: "account-1", windows: [], state: .noData, isActive: true),
            Fixture.account(id: "2", name: "account-2", state: .authDead(strikes: 1))
        ]
        // Sonst stünde beim Erststart allein „▸●–/–" in der Leiste.
        #expect(MenuBarDisplay.make(for: state(accounts), mode: .allAccounts, now: Fixture.now).segments.isEmpty)

        // Ist dagegen etwas zu sagen, bleibt der tote Token markiert — die
        // Auskunft „dieser hier ist gerade aktiv" ist dann besonders wertvoll.
        let mixed = accounts + [account("3", percent: 20)]
        let display = MenuBarDisplay.make(for: state(mixed), mode: .allAccounts, now: Fixture.now)
        #expect(display.segments.first { $0.id == "1" }?.isActive == true)
    }

    // MARK: - Regel 1: sequence.json erzeugt niemals einen Fehlzustand

    /// Ein minimaler Store mit einem Account und beiden Fenstern.
    private static let usageJSON = Data("""
    {"schemaVersion": 2,
     "accounts": {"1": {"email": "user1@example.com",
       "lastGood": {"five_hour": {"pct": 43.0}, "seven_day": {"pct": 32.0}},
       "fetchedAt": 1800000000.0, "authDeadStrikes": 0, "backoffUntil": null, "lastError": null}}}
    """.utf8)

    @Test("Fehlende oder kaputte sequence.json ergibt keinen MonitorIssue", arguments: [
        nil, "", "kein JSON", "[]", "{\"activeAccountNumber\": \"1\"}"
    ] as [String?])
    func sequenceProblemsNeverBecomeAnIssue(_ sequence: String?) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMonitorSequenceTests-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = cache.appending(path: "usage.json")
        try Self.usageJSON.write(to: store)
        if let sequence {
            try Data(sequence.utf8).write(to: root.appending(path: "sequence.json"))
        }

        let result = UsageStoreReader().read(contentsOf: store, now: Fixture.now)
        let state = MonitorViewState().reduced(with: result)

        #expect(state.issue == nil, "sequence.json darf keinen Fehlzustand erzeugen")
        let display = MenuBarDisplay.make(for: state, mode: .allAccounts, now: Fixture.now)
        // Die Prozentwerte laufen unverändert weiter …
        #expect(display.segments.map(\.numbersText) == ["43/32"])
        // … nur ausgezeichnet ist niemand.
        #expect(display.segments.contains(where: \.isActive) == false)
        // … und der Name fällt auf die E-Mail zurück.
        #expect(display.segments.map(\.displayName) == ["user1@example.com"])
    }

    // MARK: - Anzeigename

    @Test("Der Anzeigename der Leiste ist der des Accounts — Alias inbegriffen")
    func segmentCarriesDisplayName() {
        let account = Fixture.account(
            id: "1",
            name: "first",
            windows: [Fixture.window(.fiveHour, percent: 10)],
            isActive: true
        )
        let segment = MenuBarDisplay.segment(for: account)

        #expect(segment.displayName == "first")
        #expect(segment.isActive)
    }
}
