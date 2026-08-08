import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Wächter: Es darf nur **eine** Ordnung für Account-Kennungen geben.
///
/// Ein reiner Verhaltenstest kann das nicht belegen — `localizedStandardCompare`
/// liefert unter der Test-Locale zufällig dieselbe Reihenfolge wie die eigene
/// Ordnung. Der Fehler wäre erst auf einem System mit anderer Locale sichtbar.
/// Deshalb wird hier die Quelle geprüft.
///
/// Der Wächter deckt **beide** Pakete ab. Seit ``AccountIdentifierOrder``
/// `public` ist, sortiert auch `Shared/` Kennungen; ein zweiter,
/// locale-abhängiger Vergleich dort fiele durch einen reinen Core-Scan
/// hindurch — und der Verhaltenstest der Menüleiste fängt ihn aus genau dem
/// Grund nicht, aus dem dieser Wächter überhaupt existiert.
@Suite("Ordnung der Kennungen — Quellwächter")
struct OrderingSourceGuardTests {

    /// Die überwachten Quellverzeichnisse, aus dem Pfad dieser Testdatei
    /// abgeleitet — nicht aus dem Arbeitsverzeichnis, das bei `swift test`
    /// nicht garantiert ist.
    private static func sourceDirectories(_ filePath: String = #filePath) -> [URL] {
        let core = URL(fileURLWithPath: filePath)         // …/Tests/ClaudeMonitorCoreTests/…swift
            .deletingLastPathComponent()                  // …/Tests/ClaudeMonitorCoreTests
            .deletingLastPathComponent()                  // …/Tests
            .deletingLastPathComponent()                  // …/Core
        let root = core.deletingLastPathComponent()       // Projektwurzel
        return [
            core.appending(path: "Sources/ClaudeMonitorCore"),
            root.appending(path: "Shared/Sources/ClaudeMonitorShared")
        ]
    }

    /// Alle überwachten Quelldateien beider Pakete.
    ///
    /// Wirft, wenn ein Verzeichnis fehlt: Ein Scan über ein leeres oder
    /// falsches Verzeichnis darf nie stillschweigend „bestanden" ergeben.
    private static func sourceFiles(_ filePath: String = #filePath) throws -> [(name: String, text: String)] {
        try sourceDirectories(filePath).flatMap { directory -> [(name: String, text: String)] in
            let urls = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    /// Entfernt reine Kommentarzeilen — sonst schlägt der Wächter an den
    /// Doc-Kommentaren an, die das verbotene Symbol *erklären*.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Der Wächter liest die Quellen beider Pakete wirklich — Gegenprobe")
    func guardActuallyReadsSources() throws {
        // Kein Verzeichnis darf still fehlen.
        for directory in Self.sourceDirectories() {
            #expect(
                FileManager.default.fileExists(atPath: directory.path),
                "Überwachtes Verzeichnis fehlt: \(directory.path)"
            )
        }

        let files = try Self.sourceFiles()
        #expect(files.count >= 20)

        // Positiv-Nadeln: Wäre einer der beiden Scans kaputt, fände er auch
        // das hier nicht — ein Scan über ein leeres Verzeichnis fiele sonst
        // stillschweigend als „bestanden" durch.
        let order = try #require(files.first { $0.name == "AccountIdentifierOrder.swift" })
        #expect(order.text.contains("static func compare"))
        #expect(Self.code(order.text).contains("static func compare"))

        let display = try #require(files.first { $0.name == "MenuBarDisplay.swift" })
        #expect(display.text.contains("public struct MenuBarDisplay"))
        #expect(Self.code(display.text).contains("public struct MenuBarDisplay"))
    }

    @Test("Der Kommentarfilter entfernt nur Kommentare — Gegenprobe, beide Pakete")
    func commentFilterIsHonest() throws {
        let files = try Self.sourceFiles()
        // Beide Dateien erklären die verbotenen Symbole im Doc-Kommentar,
        // benutzen sie im Code aber nicht. Griffe der Filter für eine der
        // beiden nicht, löste der Wächter hier falsch aus.
        for name in ["AccountIdentifierOrder.swift", "MenuBarDisplay.swift"] {
            let file = try #require(files.first { $0.name == name })
            #expect(file.text.contains("localizedStandard" + "Compare"), "\(name): Nadel fehlt")
            #expect(
                Self.code(file.text).contains("localizedStandard" + "Compare") == false,
                "\(name): Kommentarfilter greift nicht"
            )
        }
        // Dieselbe Probe für das zweite verbotene Muster.
        let display = try #require(files.first { $0.name == "MenuBarDisplay.swift" })
        #expect(display.text.contains("sorted" + "()"))
        #expect(Self.code(display.text).contains("sorted" + "()") == false)
    }

    @Test("Kein Quellcode benutzt localizedStandardCompare für Kennungen")
    func noLocaleDependentCompare() throws {
        let offenders = try Self.sourceFiles()
            .filter { Self.code($0.text).contains("localizedStandard" + "Compare") }
            .map(\.name)
        #expect(offenders.isEmpty, "Locale-abhängiger Vergleich in: \(offenders.joined(separator: ", "))")
    }

    @Test("Kein Quellcode sortiert ohne ausdrücklichen Vergleich")
    func noBareSorted() throws {
        // `sorted()` ohne Vergleichsfunktion auf Kennungen ist die zweite Art,
        // sich eine zweite Ordnung einzuhandeln — auf `String` ist sie sogar
        // Unicode-, nicht natürlich-numerisch („10" vor „2").
        let offenders = try Self.sourceFiles()
            .filter { Self.code($0.text).contains("sorted" + "()") }
            .map(\.name)
        #expect(offenders.isEmpty, "Sortierung ohne expliziten Vergleich in: \(offenders.joined(separator: ", "))")
    }

    @Test("Reader, Ranking und Menüleiste sortieren über AccountIdentifierOrder")
    func bothUseSharedOrder() throws {
        let files = try Self.sourceFiles()
        for name in ["UsageStoreReader.swift", "AccountRanking.swift", "MenuBarDisplay.swift"] {
            let file = try #require(files.first { $0.name == name })
            #expect(
                Self.code(file.text).contains("AccountIdentifierOrder.isOrderedBefore"),
                "\(name) benutzt die gemeinsame Ordnung nicht"
            )
        }
    }
}
