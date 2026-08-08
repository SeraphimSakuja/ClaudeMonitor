import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Hilfen für die Tests: Fixture-Zugriff und schnelle Modell-Baukästen.
enum TestSupport {

    /// Lädt eine Fixture-Datei aus dem Test-Bundle.
    static func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        )
        return try #require(url, "Fixture \(name).json nicht im Test-Bundle gefunden")
    }

    /// Lädt den Inhalt einer Fixture-Datei.
    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: try fixtureURL(name))
    }

    /// Fester Bezugszeitpunkt, damit Tests nicht von der Uhr abhängen.
    static let now = Date(timeIntervalSince1970: 1_754_230_000)

    /// Verzeichnis für Dateitests; wird vom Aufrufer wieder entfernt.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMonitorCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Baut den Ablageaufbau von claude-swap nach — `cache/usage.json` und
    /// wahlweise die Geschwisterdatei `sequence.json` eine Ebene darüber.
    ///
    /// - Returns: Pfad der geschriebenen `usage.json`.
    @discardableResult
    static func writeStoreLayout(
        in root: URL,
        usage: Data = Data("{\"schemaVersion\": 2, \"accounts\": {}}".utf8),
        sequence: Data?
    ) throws -> URL {
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = cache.appending(path: "usage.json")
        try usage.write(to: store)
        if let sequence {
            try sequence.write(to: root.appending(path: UsageStoreLocator.sequenceFileName))
        }
        return store
    }

    /// Baut ein Limitfenster mit minimalem Aufwand.
    static func window(
        _ kind: LimitWindow.Kind,
        percent: Double,
        resetsIn seconds: TimeInterval? = nil,
        relativeTo reference: Date = TestSupport.now
    ) -> LimitWindow {
        LimitWindow(
            id: kind.rawKey,
            kind: kind,
            label: kind.rawKey,
            percent: percent,
            resetsAt: seconds.map { reference.addingTimeInterval($0) }
        )
    }

    /// Baut einen Account mit 5h-/7d-Fenster.
    static func account(
        _ id: String,
        fiveHour: Double,
        sevenDay: Double,
        fiveHourResetsIn: TimeInterval? = nil,
        sevenDayResetsIn: TimeInterval? = nil,
        state: AccountState = .ok
    ) -> MonitoredAccount {
        MonitoredAccount(
            id: id,
            displayName: "account-\(id)@example.com",
            windows: [
                window(.fiveHour, percent: fiveHour, resetsIn: fiveHourResetsIn),
                window(.sevenDay, percent: sevenDay, resetsIn: sevenDayResetsIn)
            ],
            fetchedAt: now,
            state: state
        )
    }

    /// Account ohne verwertbare Daten.
    static func accountWithoutData(_ id: String, state: AccountState = .noData) -> MonitoredAccount {
        MonitoredAccount(
            id: id,
            displayName: "account-\(id)@example.com",
            windows: [],
            fetchedAt: nil,
            state: state
        )
    }
}

extension TestSupport {

    /// FileManager, der jede Existenzprüfung verneint — belegt, dass der
    /// injizierte Manager wirklich benutzt wird.
    final class DenyingFileManager: FileManager, @unchecked Sendable {
        private(set) var didAnswer = false
        override func fileExists(atPath path: String) -> Bool {
            didAnswer = true
            return false
        }
    }

    /// FileManager, der die Existenz einer nicht vorhandenen Datei behauptet —
    /// stellt das TOCTOU-Fenster her.
    final class ClaimingFileManager: FileManager, @unchecked Sendable {
        override func fileExists(atPath path: String) -> Bool { true }
    }
}

extension UsageStoreReadResult {
    /// Snapshot, falls erfolgreich — sonst `nil`.
    var snapshot: AccountsSnapshot? {
        if case .success(let snapshot) = self { return snapshot }
        return nil
    }
}
