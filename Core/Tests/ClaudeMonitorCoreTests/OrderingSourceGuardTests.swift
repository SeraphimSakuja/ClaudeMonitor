import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Wächter: Es darf nur **eine** Ordnung für Account-Kennungen geben.
///
/// Ein reiner Verhaltenstest kann das nicht belegen — `localizedStandardCompare`
/// liefert unter der Test-Locale zufällig dieselbe Reihenfolge wie die eigene
/// Ordnung. Der Fehler wäre erst auf einem System mit anderer Locale sichtbar.
/// Deshalb wird hier die Quelle geprüft.
@Suite("Ordnung der Kennungen — Quellwächter")
struct OrderingSourceGuardTests {

    /// Quellverzeichnis, aus dem Pfad dieser Testdatei abgeleitet.
    private static func sourceFiles(_ filePath: String = #filePath) throws -> [(name: String, text: String)] {
        let sources = URL(fileURLWithPath: filePath)      // …/Tests/ClaudeMonitorCoreTests/…swift
            .deletingLastPathComponent()                  // …/Tests/ClaudeMonitorCoreTests
            .deletingLastPathComponent()                  // …/Tests
            .deletingLastPathComponent()                  // …/Core
            .appending(path: "Sources/ClaudeMonitorCore")
        let urls = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Entfernt reine Kommentarzeilen — sonst schlägt der Wächter an den
    /// Doc-Kommentaren an, die das verbotene Symbol *erklären*.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Der Wächter liest die Quellen wirklich — Gegenprobe")
    func guardActuallyReadsSources() throws {
        let files = try Self.sourceFiles()
        #expect(files.count >= 10)
        #expect(files.contains { $0.name == "AccountIdentifierOrder.swift" })
        // Positiv-Nadel: Wäre der Scan kaputt, fände er auch das hier nicht.
        let order = try #require(files.first { $0.name == "AccountIdentifierOrder.swift" })
        #expect(order.text.contains("static func compare"))
        #expect(Self.code(order.text).contains("static func compare"))
    }

    @Test("Der Kommentarfilter entfernt nur Kommentare — Gegenprobe")
    func commentFilterIsHonest() throws {
        let order = try #require(
            try Self.sourceFiles().first { $0.name == "AccountIdentifierOrder.swift" }
        )
        // Die Datei erklärt das verbotene Symbol im Doc-Kommentar …
        #expect(order.text.contains("localizedStandard" + "Compare"))
        // … benutzt es im Code aber nicht.
        #expect(Self.code(order.text).contains("localizedStandard" + "Compare") == false)
    }

    @Test("Kein Quellcode benutzt localizedStandardCompare für Kennungen")
    func noLocaleDependentCompare() throws {
        let offenders = try Self.sourceFiles()
            .filter { Self.code($0.text).contains("localizedStandard" + "Compare") }
            .map(\.name)
        #expect(offenders.isEmpty, "Locale-abhängiger Vergleich in: \(offenders.joined(separator: ", "))")
    }

    @Test("Reader und Ranking sortieren beide über AccountIdentifierOrder")
    func bothUseSharedOrder() throws {
        let files = try Self.sourceFiles()
        for name in ["UsageStoreReader.swift", "AccountRanking.swift"] {
            let file = try #require(files.first { $0.name == name })
            #expect(
                Self.code(file.text).contains("AccountIdentifierOrder.isOrderedBefore"),
                "\(name) benutzt die gemeinsame Ordnung nicht"
            )
        }
    }
}
