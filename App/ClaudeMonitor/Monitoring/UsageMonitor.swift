import Foundation
import OSLog
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Der Poller: liest claude-swaps Cache alle 30 s und veröffentlicht das
/// Ergebnis an die UI.
///
/// **Leitplanke L1/L2:** Es wird ausschließlich gelesen — kein Schreiben in
/// `usage.json`, kein File-Lock, kein eigener OAuth-Refresh, kein Aufruf des
/// `cswap`-Binaries. Der Monitor beobachtet, er greift nicht ein.
///
/// Gepollt wird **durchgehend**, auch wenn das Menü geschlossen ist: Derselbe
/// Snapshot versorgt die Widget-Extension, die selbst nicht lesen darf.
@MainActor
final class UsageMonitor: ObservableObject {

    /// Abstand zweier Lesevorgänge. Passend zu claude-swaps eigenem 30-s-Poller
    /// — häufiger zu lesen brächte keine neuen Zahlen.
    static let pollInterval: Duration = .seconds(30)

    /// Gemeinsame Instanz. Die App hat kein Fenster und damit keinen
    /// natürlichen Besitzer; der Lebenszyklus hängt am `NSApplicationDelegate`.
    static let shared = UsageMonitor()

    /// Aktueller Zustand für die Views.
    @Published private(set) var state = MonitorViewState()
    /// Ergebnis des letzten Schreibversuchs in den App-Group-Container.
    ///
    /// Bewusst **nicht** `@Published`: Der Wert wird nirgends gerendert, er
    /// dient allein der Log-Entprellung. Als `@Published` löste er 30-Sekunden-
    /// weise Neuzeichnungen der Menüleiste aus, ohne dass sich etwas Sichtbares
    /// geändert hätte.
    private(set) var lastWriteResult: SnapshotStore.WriteResult?

    private let reader: UsageStoreReader
    private let writer: SnapshotStore
    private var pollingTask: Task<Void, Never>?
    /// Gerade laufender Lesedurchlauf, falls einer läuft.
    private var refreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: AppGroup.loggingSubsystem, category: "UsageMonitor")

    init(reader: UsageStoreReader = UsageStoreReader(), writer: SnapshotStore = SnapshotStore()) {
        self.reader = reader
        self.writer = writer
    }

    /// Startet den Poller. Mehrfachaufrufe sind wirkungslos.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: UsageMonitor.pollInterval)
                } catch {
                    // Abbruch der Task ist der einzige erwartete Fehler.
                    return
                }
            }
        }
    }

    /// Beendet den Poller. Wird beim Programmende aufgerufen, damit keine
    /// Task über den Lebenszyklus hinaus weiterläuft.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Ein Lesedurchlauf: Store lesen, Zustand fortschreiben, Snapshot in den
    /// App-Group-Container schreiben.
    ///
    /// **Nicht wiedereintrittsfähig, und das mit Absicht:** Poller und der
    /// Knopf „Jetzt aktualisieren" können gleichzeitig auslösen. Ohne Wache
    /// überholten sich zwei Durchläufe, der ältere schriebe seinen Zustand über
    /// den neueren — und wiederholtes Klicken erzeugte unbegrenzt viele Tasks.
    /// Ein bereits laufender Durchlauf wird deshalb nur abgewartet, statt einen
    /// zweiten zu starten. Der Aufrufer bekommt trotzdem erst dann die
    /// Kontrolle zurück, wenn frische Zahlen anliegen.
    func refresh() async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        let reader = self.reader
        let writer = self.writer
        // Datei-I/O gehört nicht auf den MainActor — die Menüleiste soll auch
        // dann flüssig bleiben, wenn der Store gerade langsam ist.
        //
        // Die Entitlement-Wache wird hier **nicht** mehr eigens abgefragt: Sie
        // sitzt in ``SnapshotStore/containerDirectory`` und ist damit nicht zu
        // umgehen. `write` meldet ohne Deklaration `containerUnavailable`,
        // ohne den Container je anzufassen.
        let outcome = await Task.detached(priority: .utility) { () -> (UsageStoreReadResult, SnapshotStore.WriteResult?) in
            let result = reader.read()
            guard case .success(let snapshot) = result else { return (result, nil) }
            return (result, writer.write(snapshot))
        }.value

        state = state.reduced(with: outcome.0)
        if let writeResult = outcome.1 {
            logIfChanged(writeResult)
            lastWriteResult = writeResult
        }

        if let issue = state.issue { log(issue) }
    }

    /// Protokolliert Schreibergebnisse nur bei Änderung — sonst flutet der
    /// 30-s-Takt das Log mit derselben Zeile.
    private func logIfChanged(_ result: SnapshotStore.WriteResult) {
        guard result != lastWriteResult else { return }
        switch result {
        case .written:
            logger.info("Snapshot in den App-Group-Container geschrieben.")
        case .containerUnavailable(let group):
            logger.notice(
                """
                App Group \(group, privacy: .public) nicht verfügbar (Entitlement fehlt) — \
                Widgets bekommen keine Daten. Menüleiste läuft weiter.
                """
            )
        case .failed(let reason):
            // Ohne `.public`: Die Begründung stammt aus `SnapshotStore` und
            // kann den Container-Pfad enthalten — siehe `log(_:)`.
            logger.error("Snapshot konnte nicht geschrieben werden: \(reason)")
        }
    }

    /// Protokolliert Fehlzustände.
    ///
    /// **Pfade und fremde Fehlertexte werden bewusst NICHT als `.public`
    /// markiert.** `os_log` redigiert dynamische Zeichenketten von sich aus;
    /// ein `.public` hebt genau diesen Schutz auf. Die Kandidatenpfade
    /// enthalten den macOS-Kontonamen (`/Users/<Name>/…`), und dieser landete
    /// damit im dauerhaften Log-Archiv und in jedem `sysdiagnose`. Das Projekt
    /// hält bewusst keine Nutzerpfade im Code, weil es veröffentlicht werden
    /// könnte — über das Log gingen sie sonst trotzdem nach außen. In
    /// Console.app sind die Werte beim lokalen Debuggen weiterhin sichtbar.
    private func log(_ issue: MonitorIssue) {
        switch issue {
        case .storeNotFound(let paths):
            logger.notice("claude-swap-Cache nicht gefunden. Gesucht: \(paths.joined(separator: ", "))")
        case .unsupportedSchema(let found, let expected):
            // Reine Zahlen — die will man im Log lesen können.
            logger.error("Unerwartete schemaVersion \(found ?? -1, privacy: .public) (erwartet \(expected, privacy: .public)) — Zahlen werden nicht angezeigt.")
        case .unreadable(let reason):
            logger.notice("Cache momentan nicht lesbar: \(reason)")
        }
    }
}
