import Foundation
import Testing
@testable import ClaudeMonitorCore
#if canImport(Glibc)
import Glibc
#endif

/// Die Wache vor dem vollständigen Lesen fremdbestimmter Dateien.
///
/// Hintergrund: `Data(contentsOf:)` auf einer FIFO blockiert beim Öffnen, bis
/// ein Schreiber erscheint. Der Lesedurchlauf läuft in einer abgesetzten Task
/// und kehrte nie zurück — dieselbe Fehlerklasse wie die App-Group-Blockade aus
/// Leitplanke L7.
///
/// `readIfSafe(_:)` (CM-16) öffnet die Datei mit `O_NONBLOCK` — genau deshalb
/// wird die FIFO unten mit Zeitschranke tatsächlich vorgelegt, als Beweis,
/// dass das Öffnen selbst nicht mehr blockiert.
@Suite("Wache vor dem Lesen fremder Dateien")
struct SourceFileGuardTests {

    private static func makeFIFO(in directory: URL) throws -> URL {
        let url = directory.appending(path: "fifo.json")
        #expect(mkfifo(url.path, 0o600) == 0)
        return url
    }

    /// Kleine `@unchecked Sendable`-Box, um das Ergebnis aus dem Hintergrund-
    /// Thread unten zurückzutragen — sicher, weil der Semaphore eine
    /// Geschieht-vorher-Beziehung zwischen Schreiben und Lesen erzwingt.
    private final class ResultBox: @unchecked Sendable {
        var value: SourceFileGuard.ReadResult?
    }

    @Test("CM-16: Das tatsächliche Lesen einer FIFO blockiert nicht mehr")
    func fifoReadDoesNotBlock() throws {
        // Defekt-Fixture, nicht nur gelesen: vor dem Fix hätte `open` hier auf
        // eine FIFO ohne Schreiber gewartet — endlos, siehe Dateikopf. Läuft
        // der Aufruf auf einem eigenen Thread mit Zeitschranke: kehrt ein
        // Regress zur alten TOCTOU-Lücke zurück, macht das den Test rot statt
        // die ganze Suite aufzuhängen.
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try Self.makeFIFO(in: root)

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = SourceFileGuard.readIfSafe(fifo)
            semaphore.signal()
        }

        let outcome = semaphore.wait(timeout: .now() + 2)
        #expect(outcome == .success, "readIfSafe(fifo) kehrte nicht innerhalb von 2s zurück — blockiert vermutlich beim Öffnen der FIFO")
        #expect(box.value == .rejected(.notRegularFile))

        // Lebender Vertrag (hier mitgeprüft, keine eigene Testfunktion mehr):
        // `UsageStoreReader` fällt bei `.unavailable` auf einen eigenen Text
        // zurück (`verdict.reason ?? "..."`, s. UsageStoreReader.swift:103) —
        // dieser Fall muss `nil` bleiben, sonst verdeckt die Wache die
        // eigentliche Fallback-Meldung.
        #expect(SourceFileGuard.Verdict.unavailable.reason == nil)
    }

    // MARK: - Die Leser befragen die Wache wirklich

    @Test("Der Store-Leser lehnt ein Verzeichnis mit der Begründung der Wache ab")
    func storeReaderConsultsTheGuard() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "usage.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = UsageStoreReader().read(contentsOf: directory)

        // Gegen die **Begründung** geprüft, nicht nur gegen den Fehlerfall:
        // Ohne die Wache liefe `Data(contentsOf:)` in seinen eigenen Fehler und
        // ergäbe ebenfalls `.unreadable` — nur mit dem Text von Foundation.
        guard case .unreadable(let reason) = result else {
            Issue.record("Erwartet: .unreadable, bekommen: \(result)")
            return
        }
        #expect(reason == SourceFileGuard.Verdict.notRegularFile.reason)
        // Und der Grund trägt weder Pfad noch Kontonamen.
        #expect(!reason.contains("/"))
    }

    @Test("Der Sequence-Leser übernimmt aus einer übergroßen Datei nichts")
    func sequenceReaderConsultsTheGuard() throws {
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Die Datei muss **gültiges** JSON bleiben, sonst scheiterte schon der
        // Parser und der Test wäre auch ohne die Wache grün. Deshalb wird im
        // JSON selbst aufgefüllt, nicht per `truncate` mit NUL-Bytes.
        let url = root.appending(path: "sequence.json")
        let padding = String(repeating: "a", count: SourceFileGuard.maximumFileSize)
        let json = #"{"activeAccountNumber": 1, "accounts": {"1": {"alias": "kurz"}}, "padding": ""#
            + padding + #""}"#
        try Data(json.utf8).write(to: url)

        // Ohne die Wache läse der Leser die Datei und übernähme Alias und
        // aktive Kennung — mit ihr bleibt nichts übrig.
        #expect(AccountSequenceReader.read(contentsOf: url) == .empty)
        // Gegenprobe, dass genau dieser Inhalt sonst etwas ergäbe:
        #expect(AccountSequenceReader.decode(Data(json.utf8)).aliases["1"] == "kurz")
    }
}
