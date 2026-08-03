import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite("AccountsSnapshot — Transportformat für App-Group und Widget")
struct AccountsSnapshotTests {

    private let now = TestSupport.now

    private func snapshot() -> AccountsSnapshot {
        AccountsSnapshot(
            accounts: [TestSupport.account("1", fiveHour: 10, sevenDay: 20, fiveHourResetsIn: 600)],
            capturedAt: now,
            sourceSchemaVersion: ClaudeMonitorCore.supportedSchemaVersion
        )
    }

    @Test("Snapshot trägt seine eigene Layout-Version, getrennt von der Quell-Schemaversion")
    func carriesOwnFormatVersion() throws {
        let encoded = try JSONEncoder().encode(snapshot())
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("formatVersion"))

        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["formatVersion"] as? Int == AccountsSnapshot.currentFormatVersion)
        #expect(object["sourceSchemaVersion"] as? Int == ClaudeMonitorCore.supportedSchemaVersion)
    }

    @Test("Roundtrip erhält die Layout-Version")
    func roundtrip() throws {
        let original = snapshot()
        let decoded = try JSONDecoder().decode(
            AccountsSnapshot.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.formatVersion == AccountsSnapshot.currentFormatVersion)
    }

    @Test("Ein Snapshot aus einer fremden Layout-Version wird laut abgelehnt, nicht still halb gelesen")
    func rejectsForeignFormatVersion() throws {
        let encoded = try JSONEncoder().encode(snapshot())
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["formatVersion"] = AccountsSnapshot.currentFormatVersion + 1
        let tampered = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AccountsSnapshot.self, from: tampered)
        }
    }

    @Test("Snapshot ohne Versionsfeld gilt als erste Fassung und bleibt lesbar")
    func acceptsLegacySnapshotWithoutVersion() throws {
        let encoded = try JSONEncoder().encode(snapshot())
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "formatVersion")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AccountsSnapshot.self, from: legacy)
        #expect(decoded.accounts.map(\.id) == ["1"])
        #expect(decoded.formatVersion == AccountsSnapshot.currentFormatVersion)
    }
}
