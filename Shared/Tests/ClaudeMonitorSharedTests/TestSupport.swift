import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Bauhelfer für Testdaten — anonymisiert, keine echten Kennungen.
enum Fixture {

    /// Fester Bezugszeitpunkt, damit Restzeiten reproduzierbar sind.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func window(
        _ kind: LimitWindow.Kind,
        percent: Double,
        resetsAt: Date? = nil
    ) -> LimitWindow {
        LimitWindow(
            id: kind.rawKey,
            kind: kind,
            label: kind.rawKey,
            percent: percent,
            resetsAt: resetsAt
        )
    }

    static func account(
        id: String = "1",
        name: String = "account-a",
        windows: [LimitWindow] = [],
        fetchedAt: Date? = Fixture.now,
        nextPollAt: Date? = nil,
        state: AccountState = .ok
    ) -> MonitoredAccount {
        MonitoredAccount(
            id: id,
            displayName: name,
            windows: windows,
            fetchedAt: fetchedAt,
            nextPollAt: nextPollAt,
            state: state
        )
    }

    static func snapshot(_ accounts: [MonitoredAccount]) -> AccountsSnapshot {
        AccountsSnapshot(
            accounts: accounts,
            capturedAt: now,
            sourceSchemaVersion: ClaudeMonitorCore.supportedSchemaVersion
        )
    }

    /// Verzeichnis für Dateitests; wird vom Aufrufer wieder entfernt.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
