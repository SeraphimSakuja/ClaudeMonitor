import Foundation
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Bauhelfer für Testdaten — anonymisiert, keine echten Kennungen.
enum Fixture {

    /// Fester Bezugszeitpunkt, damit Restzeiten reproduzierbar sind.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// - Parameter id: Kennung des Fensters. Vorgabe ist der Rohschlüssel der
    ///   Art — für mehrere `scoped`-Fenster muss sie gesetzt werden, weil der
    ///   echte Reader dort `scoped:<index>:<name>` vergibt und gleiche
    ///   `Identifiable`-Kennungen sonst kollidieren.
    static func window(
        _ kind: LimitWindow.Kind,
        percent: Double,
        resetsAt: Date? = nil,
        id: String? = nil
    ) -> LimitWindow {
        LimitWindow(
            id: id ?? kind.rawKey,
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
        state: AccountState = .ok,
        isActive: Bool = false
    ) -> MonitoredAccount {
        MonitoredAccount(
            id: id,
            displayName: name,
            windows: windows,
            fetchedAt: fetchedAt,
            nextPollAt: nextPollAt,
            state: state,
            isActive: isActive
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
