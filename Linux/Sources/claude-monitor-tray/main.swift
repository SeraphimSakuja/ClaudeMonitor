import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Autostart
import ClaudeMonitorCore
import ClaudeMonitorShared
import DBusWire
import TrayPresentation
import Update

// CM-20 — residenter Tray-Prozess für Linux.
//
// Der residente Tray-Prozess ist strikt lesend, wie die Rauchprobe: kein
// Schreiben, kein Lock, kein `SnapshotStore.write` (Leitplanke L1). Die
// Tray-Ziele binden `SnapshotStore` nicht einmal ein — die Zusage ist damit
// nicht nur eingehalten, sondern mechanisch nicht brechbar. Das gilt auch für
// `--selftest`.
//
// Ausnahmen sind die Unterbefehle, und nur sie (CM-21, CM-29): Die
// Unit-Befehle schreiben ihre Units (`--install-autostart`,
// `--install-auto-update` — Timer und Service), und `--update` ersetzt das
// eigene Binary und sperrt dazu dessen Verzeichnis per `flock`.
// `--check-update` (CM-36) schreibt nur in sein privates Temp-Verzeichnis.
// Keiner davon berührt `usage.json`.
//
// Ins Netz geht der residente Tray nur über Kindprozesse: `--update` auf
// Klick („Check for updates now") und `--check-update` ab Werk selbst —
// 15 min nach dem Start, dann alle 24 h, abschaltbar mit
// `CLAUDE_MONITOR_NO_UPDATE_CHECK=1` (CM-36, `pollAutomaticCheck(now:)`).
//
// Für den Druckvertrag (was dieser Prozess NIE ausgibt) siehe `TrayLog`.

// MARK: - Exit-Vertrag

/// Die Beendigungscodes dieses Prozesses.
///
/// Sie sind eine Zusage an `CM-21`: Der systemd-Nutzerdienst unterscheidet
/// daran „falsch eingerichtet" von „gescheitert" und entscheidet, ob ein
/// Neustart überhaupt Sinn hat.
///
/// `127` und `203` sind vergeben, ohne dass die App sie nutzt: Die Unit
/// schließt sie vom Neustart aus (Lader bzw. systemd, siehe
/// `AutostartUnit.restartPreventExitStatus`). Ein künftiger Fall hier darf
/// keinen der beiden Werte tragen, sonst würde er stillschweigend nie neu
/// gestartet.
enum TrayExit: Int32 {
    /// Normal beendet, oder `--selftest` erfolgreich.
    case ok = 0
    /// `DBUS_SESSION_BUS_ADDRESS` fehlt — es gibt keine Sitzung.
    case busAddressMissing = 5
    /// Verbindung oder SASL gescheitert.
    case connectionFailed = 6
    /// Nur `--selftest`: registriert, aber die Abfragefolge blieb aus.
    case selftestIncomplete = 7
    /// Eine zweite Instanz läuft bereits (Auflage 5).
    case alreadyRunning = 8
    /// Nur `--selftest`: kein `org.kde.StatusNotifierWatcher` auf dem Bus
    /// (Auflage 13). Im Normalbetrieb ist das **kein** Abbruchgrund — dort
    /// wartet der Prozess auf den Watcher.
    case watcherMissing = 9
    /// Nur die Autostart-Unterbefehle: Die Bitte ließ sich nicht ausführen —
    /// etwas am Zielort steht dagegen (fremde Datei, Symlink, Maske), systemd
    /// lädt für den Namen eine andere Unit-Datei (CM-32), oder der Aufruf war
    /// nicht auswertbar (unbekanntes Argument). Der Zustand bleibt,
    /// wie er war; es wurde nichts überschrieben.
    case autostartBlocked = 10
    /// Nur die Autostart-Unterbefehle: Es konnte **gar nichts gemessen** werden
    /// — kein Nutzermanager erreichbar, kein Home ableitbar, `systemctl`
    /// antwortet mit einem Zustand, der keine Auskunft ist, oder welche
    /// Unit-Datei systemd lädt, ließ sich nicht bestimmen (CM-32). Ausdrücklich NICHT
    /// „nicht eingerichtet": Das wäre eine Aussage über eine Messung, die nicht
    /// stattgefunden hat.
    case autostartUnavailable = 11
    /// Nur `--update` und `--check-update` (CM-29, CM-36): **nichts
    /// gemessen** — kein `curl`/`wget`, Netz- oder HTTP-Fehler,
    /// Zeitüberschreitung, auch **kein Manifest**.
    /// Ausdrücklich NICHT „aktuell": Das darf nur nach einem gültig gelesenen
    /// Manifest gemeldet werden.
    case updateUnavailable = 12
    /// Nur `--update` und `--check-update` (CM-29, CM-36): **abgelehnt** —
    /// Signatur fehlt oder passt nicht, Manifest ungültig oder in anderem
    /// Format, Größe oder Prüfsumme falsch, unter dem Kompatibilitätsboden,
    /// Ladeprobe gescheitert, Verzeichnis nicht schreibbar, ein anderes Update
    /// läuft (die letzten drei nur `--update`). Das installierte Binary ist
    /// unverändert.
    case updateRefused = 13
    /// Nur `--check-update` (CM-36 · FE-7): ein gültig gelesenes Manifest
    /// bietet eine neuere Fassung an, die den glibc-Boden dieses Rechners
    /// erfüllt; **nichts wurde geladen**. Ob sie sich selbst installieren lässt
    /// (Verzeichnis schreibbar), sagt der Text, nicht der Code.
    ///
    /// Der residente Tray endet nie mit 12, 13 oder 14 — darum bleibt
    /// `RestartPreventExitStatus` der Autostart-Unit unverändert.
    case updateAvailable = 14

    /// Ein **fester** Bezeichner je Verbindungsfehler.
    ///
    /// Bewusst eine Handabbildung und kein `String(describing:)`: Der
    /// Druckvertrag in `TrayLog` verbietet Reflexionsausgabe, und
    /// `connectFailed(errno:)` trägt einen Zahlenwert, der über die Abbildung
    /// als benannter Skalar hinausgeht statt als Reflexionsrumpf.
    static func reason(for error: DBusConnection.ConnectError) -> String {
        switch error {
        case .addressUnavailable: return "addressUnavailable"
        case .connectFailed(let number): return "connectFailed errno=\(number)"
        case .authenticationFailed: return "authenticationFailed"
        case .disconnected: return "disconnected"
        case .timedOut: return "timedOut"
        case .errorReply: return "errorReply"
        case .malformedReply: return "malformedReply"
        }
    }

    /// Der **feste** Bus-Zustand, der zum Fehler passt.
    ///
    /// Fund N1 (CM-27, Rework R2): Die `bus=`-Logzeilen bei `requestName` und
    /// `nameHasOwner` waren hartkodiert auf `"disconnected"`, auch wenn
    /// `reason(for:)` inzwischen `errorReply` oder `malformedReply` lieferte —
    /// ein Widerspruch innerhalb derselben Logzeile. Feste Bezeichner, kein
    /// Fremdtext — gleicher Druckvertrag wie `reason(for:)`.
    static func busState(for error: DBusConnection.ConnectError) -> String {
        switch error {
        case .disconnected: return "disconnected"
        case .errorReply: return "error"
        case .malformedReply: return "malformed"
        case .timedOut: return "timedOut"
        case .addressUnavailable, .connectFailed, .authenticationFailed: return "disconnected"
        }
    }
}

// MARK: - Signale

/// Abbruchwunsch aus einem Signalhandler.
///
/// `sig_atomic_t` und sonst nichts: In einem Signalhandler ist fast jede
/// Funktion verboten — kein `print`, keine Speicheranforderung, kein Swift-
/// Laufzeitaufruf. Der Handler setzt deshalb nur dieses Flag; abgebaut wird im
/// nächsten Durchlauf der Schleife, im normalen Programmfluss.
nonisolated(unsafe) var trayStopRequested: sig_atomic_t = 0

func trayNoteStopSignal(_ number: Int32) {
    trayStopRequested = 1
}

// MARK: - Prozess

/// Ereignisschleife, Registrierung, Abbau.
///
/// ⚠️ **Die Nebenläufigkeit ist hier NEU gefasst und nicht von `UsageMonitor`
/// übernommen** (Fachentscheid 5.9). Kein `@MainActor`, kein `Task`, kein
/// `Task.detached`, kein `Task.sleep`: Es gibt genau eine `poll()`-Schleife
/// über den Bus-Deskriptor. Ihr Zeitlimit ist die Restzeit bis zum nächsten
/// Lesevorgang; D-Bus-Aufrufe werden sofort beantwortet, der Store wird inline
/// im Zeitlimit-Zweig gelesen.
///
/// Der Grund ist gemessen: Die Gegenstelle hat Fristen. GDBus gibt nach 25 s
/// auf (`dbusProxy.js:96,104`), die Liveness-Abfrage der Extension nach 10 s
/// (Auflage 4). Ein Modell mit zwei Ausführungspfaden müsste beweisen, dass
/// eine Antwort nie hinter einem Lesevorgang wartet; ein Modell mit einem Pfad
/// muss nur zeigen, dass der Lesevorgang kurz ist — und das ist er, weil
/// `SourceFileGuard.maximumFileSize` die Quelle auf 8 MiB deckelt
/// (`SourceFileGuard.swift:33,96`).
final class TrayProcess {

    /// Takt des Lesevorgangs — identisch zu macOS
    /// (`UsageMonitor.pollInterval`, Fachentscheid 5.10). Häufiger zu lesen
    /// brächte keine neuen Zahlen: claude-swap schreibt selbst nicht öfter.
    static let pollInterval: TimeInterval = 30

    /// Der Well-Known-Name, über den die Einzelinstanz durchgesetzt wird
    /// (Auflage 5). Ohne ihn ergäbe ein Doppelstart — Autostart-Instanz plus
    /// Handstart, der Normalfall sobald `CM-21` existiert — **zwei**
    /// Panel-Einträge, weil der Watcher Items unter `busName@objectPath`
    /// führt (`statusNotifierWatcher.js:89-95`).
    static let wellKnownName = "org.claudemonitor.Tray"

    static let itemPath = "/StatusNotifierItem"
    static let menuPath = "/StatusNotifierItem/Menu"
    static let watcherName = "org.kde.StatusNotifierWatcher"
    static let watcherPath = "/StatusNotifierWatcher"

    /// Wie lange `--selftest` auf die Abfragefolge wartet. Der Prototyp hat
    /// gemessen, dass die Extension binnen weniger Sekunden fragt; 20 s liegen
    /// deutlich darüber und bleiben doch unter einer Minute Laufzeit.
    static let selftestTimeout: TimeInterval = 20

    private let log: TrayLog
    private let homeDirectory: URL
    private let reader = UsageStoreReader()
    private let connection: DBusConnection
    private let item: StatusNotifierItemObject
    private let menu: DBusMenuObject

    /// Der Autostart für den Menüeintrag „Start at login" (CM-30).
    private let installer: AutostartInstaller

    private var state: MonitorViewState
    private var autostart: TrayAutostartDisplay
    /// „Automatic updates" — der Timer des Auto-Updates (CM-37).
    private var autoUpdate: TrayAutoUpdateDisplay
    /// „Check for updates now" (CM-37) und die Suche ab Werk (CM-36).
    private var updateCheck = TrayUpdateCheck.idle
    /// Was das laufende Kind ist.
    private enum UpdateChildKind {
        /// `--update` auf Klick (CM-37).
        case install
        /// `--check-update` ab Werk (CM-36), mit Startzeit und ob es der
        /// eine Nachversuch nach Exit 12 ist.
        case automaticCheck(startedAt: Date, isRetry: Bool)
    }
    /// Das laufende Kind samt dem Pfad, den es ersetzen kann bzw. prüft.
    /// Höchstens eines zur Zeit (CM-36 · FE-12).
    private var updateChild: (pid: pid_t, path: String, kind: UpdateChildKind)?
    /// CM-36 · FE-8: der nächste Start der Suche ab Werk; `nil`, wenn sie
    /// abgeschaltet ist (FE-9). Nur im Speicher — keine Zeitstempeldatei.
    private var nextAutomaticCheck: Date?
    /// 2b-Auflage 11: Der nächste Start ist der eine Nachversuch nach Exit 12.
    private var automaticRetryPending = false
    /// FE-10: der Menüzustand vor der laufenden automatischen Suche.
    private var updateCheckBeforeAutomatic = TrayUpdateCheck.idle
    private let starter: BackgroundStarter
    private var nextRead: Date
    private var registeredWithWatcher = false

    /// - Parameters:
    ///   - environment: Quelle der Unit-Pfade und Umgebung von `systemctl`.
    ///   - runner: Zugang zu `systemctl`; `nil` ⇒ ``PosixCommandRunner``.
    ///     Die Naht ist nötig, weil `posix_spawnp` über den PATH des
    ///     **aufrufenden** Prozesses sucht, nicht über das übergebene
    ///     Environment — eine PATH-Attrappe wirkt in-process nicht
    ///     (2b-Auflage 4).
    ///   - starter: Zugang zu `--update` und `--check-update` als
    ///     Kindprozess; `nil` ⇒ ``PosixBackgroundStarter``. Tests injizieren
    ///     immer einen Starter; ohne ihn startet ein Klick das Testbinary mit
    ///     `--update`.
    ///   - now: auch der Bezug der ersten Suche ab Werk (`now` + 15 min).
    init(
        connection: DBusConnection,
        homeDirectory: URL,
        log: TrayLog,
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: CommandRunner? = nil,
        starter: BackgroundStarter? = nil
    ) {
        self.connection = connection
        self.homeDirectory = homeDirectory
        self.log = log
        self.starter = starter ?? PosixBackgroundStarter(environment: environment, log: { log.always($0) })

        let result = UsageStoreReader().read(homeDirectory: homeDirectory, now: now)
        state = MonitorViewState().reduced(with: result)
        nextRead = now.addingTimeInterval(Self.pollInterval)
        if TrayUpdateCheck.automaticChecksEnabled(environment: environment) {
            nextAutomaticCheck = now.addingTimeInterval(TrayUpdateCheck.automaticFirstDelay)
        } else {
            log.always("update=autocheck disabled by \(TrayUpdateCheck.disableVariable)=1")
        }

        // Die Installer-Meldungen tragen Unit-Pfade aus `$HOME`
        // (`AutostartPaths.swift:74-76`) — der Redaktionspräfix muss derselbe
        // sein, nicht der aus der Passwortdatenbank (Muster wie
        // `trayFrontDoor`).
        let autostartLog = TrayLog(homeDirectory: URL(
            fileURLWithPath: AutostartPaths.homeDirectory(environment: environment) ?? "/"
        ))
        let installer = AutostartInstaller(
            environment: environment,
            runner: runner ?? PosixCommandRunner(environment: environment),
            emit: { autostartLog.always($0) }
        )
        self.installer = installer
        let autostart = TrayAutostartDisplay(reading: installer.reading(), binary: installer.binaryMatch())
        self.autostart = autostart
        let autoUpdate = TrayAutoUpdateDisplay(reading: installer.autoUpdateReading())
        self.autoUpdate = autoUpdate

        let view = Self.makeView(
            state: state, autostart: autostart, autoUpdate: autoUpdate, updateCheck: updateCheck, now: now
        )
        item = StatusNotifierItemObject(
            objectPath: Self.itemPath,
            menuPath: Self.menuPath,
            view: view
        )
        menu = DBusMenuObject(objectPath: Self.menuPath, items: view.menu)
        connection.register(item)
        connection.register(menu)
        report(result)
    }

    // MARK: Registrierung

    /// Meldet das Item beim Watcher an.
    func registerWithWatcher() {
        connection.call(
            destination: Self.watcherName,
            path: Self.watcherPath,
            interface: Self.watcherName,
            member: "RegisterStatusNotifierItem",
            arguments: [.string(Self.itemPath)]
        )
        registeredWithWatcher = true
        log.always("watcher=registered path=\(Self.itemPath)")
    }

    /// Bestellt die Nachricht ab, dass der Watcher kommt oder geht.
    ///
    /// Ohne sie bliebe das Item nach einem `gnome-shell`-Neustart für immer
    /// weg, obwohl der Prozess weiterläuft.
    func observeWatcher() {
        connection.addMatch(
            "type='signal',sender='org.freedesktop.DBus',"
            + "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
            + "arg0='\(Self.watcherName)'"
        )
    }

    // MARK: Schleife

    /// Läuft, bis ein Signal, ein „Beenden"-Klick oder — bei `--selftest` —
    /// die Abnahme das Ende setzt.
    func run(selftestDeadline: Date?) -> TrayExit {
        while trayStopRequested == 0 {
            let now = Date()
            if let selftestDeadline {
                if selftestPassed { return .ok }
                if now >= selftestDeadline { return .selftestIncomplete }
            }

            // Zeitlimit = Restzeit bis zum nächsten Lesevorgang, gedeckelt,
            // damit Signale und die Selbsttest-Frist zeitnah greifen.
            let remaining = nextRead.timeIntervalSince(now)
            let timeout = Int32(min(max(remaining, 0), 1) * 1000)

            let incoming: [DBusMessage]
            do {
                incoming = try connection.pump(timeoutMilliseconds: timeout)
            } catch {
                // Der Bus ist weg. Weiterlaufen hieße, mit 100 % CPU ins Leere
                // zu fragen; der Dienst startet uns neu, wenn die Sitzung
                // wieder da ist.
                log.always("bus=disconnected — shutting down")
                return .connectionFailed
            }

            for message in incoming { handle(signal: message) }

            if let exit = handleMenuEvents() { return exit }
            pollUpdateCheck()
            // FE-8: `--selftest` löst nie eine Suche aus.
            if selftestDeadline == nil { pollAutomaticCheck(now: Date()) }

            if Date() >= nextRead { refresh(now: Date()) }
        }
        log.always("signal=stop — shutting down")
        return .ok
    }

    /// Verarbeitet, was seit dem letzten Durchlauf im Menü geschah: Öffnen
    /// und Klicks. Aus der Schleife gezogen, damit der Klickpfad ohne
    /// `run(selftestDeadline:)` fahrbar ist (2b-Auflage 4).
    ///
    /// - Returns: ein Beendigungscode, wenn „Quit" angeklickt wurde.
    func handleMenuEvents() -> TrayExit? {
        // CM-30 · F5: Beim Öffnen neu erfragen, damit eine Änderung im
        // Terminal sichtbar wird. Gewollte Nebenwirkung: Auch alle
        // zeitabhängigen Zeilen („Checked … ago", Restzeiten) werden dabei
        // neu berechnet.
        if menu.takeMenuOpened() {
            autostart = autostart.afterRequery(reading: installer.reading(), binary: installer.binaryMatch())
            autoUpdate = autoUpdate.afterRequery(reading: installer.autoUpdateReading())
            publish(makeView(now: Date()))
        }

        // Mehrere Klicks auf „Start at login" in einem Durchlauf trugen alle
        // denselben angezeigten Stand — ein Versuch genügt.
        var autostartAttempted = false
        var autoUpdateAttempted = false
        for item in menu.takePendingActions() {
            switch item.role {
            case .quit:
                log.always("menu=quit requested")
                return .ok
            case .refresh:
                // „Jetzt aktualisieren": sofort lesen statt bis zu 30 s
                // zu warten.
                nextRead = Date()
            case .startAtLogin:
                guard !autostartAttempted else { continue }
                autostartAttempted = true
                attemptAutostart(showing: item.checkmark)
            case .automaticUpdates:
                guard !autoUpdateAttempted else { continue }
                autoUpdateAttempted = true
                attemptAutoUpdate(showing: item.checkmark)
            case .checkForUpdates:
                startUpdateCheck()
            case .information, .separator:
                break
            }
        }
        return nil
    }

    /// Ein Klick auf „Check for updates now" (CM-37 · FE 8/11): `--update` als
    /// Kindprozess, ohne zu warten. Ein Klick während einer laufenden Prüfung
    /// startet nichts (Mehrfachklicks im selben Durchlauf ergeben ein Kind).
    private func startUpdateCheck() {
        guard updateCheck.canStart else { return }
        switch AutostartExecutable.resolve() {
        case .usable(let path):
            log.always("update=check starting")
            if let pid = starter.start(executable: path, arguments: ["--update"]) {
                log.always("update=check started pid=\(pid)")
                updateChild = (pid, path, .install)
                updateCheck = .running
            } else {
                log.always("update=check spawn failed")
                updateCheck = .finished(.couldNotRun)
            }
        case .unusable(let reason):
            log.always("update=check unusable — \(reason)")
            updateCheck = .finished(.couldNotRun)
        }
        publish(makeView(now: Date()))
    }

    /// Die Suche ab Werk (CM-36): startet `--check-update` als Kind, wenn sie
    /// fällig ist. Je Schleifendurchlauf aus `run` aufgerufen; nicht privat und
    /// mit Zeitparameter, damit Takt, Abschalter und Wartepflicht ohne
    /// `run(selftestDeadline:)` fahrbar sind (2b-Auflage 6).
    ///
    /// * FE-8: erste Fälligkeit `now` des Initialisierers + 15 min, danach
    ///   24 h ab dem Start der vorigen Suche; nach Exit 12 genau ein
    ///   Nachversuch 15 min nach deren Start (2b-Auflage 11,
    ///   `TrayUpdateCheck.nextAutomaticCheck`).
    /// * FE-9: abgeschaltet ⇒ `nextAutomaticCheck == nil`, nie ein Start.
    /// * FE-12: Läuft schon ein Kind, wartet die Suche, bis es abgeholt ist;
    ///   während sie läuft, zeigt das Menü die gesperrte Laufzeile.
    /// * FE-15 (2b-Auflage 10): Die Suche läuft **unabhängig** vom Opt-in-Timer
    ///   „Automatic updates" — auch wenn er eingeschaltet ist (dann gibt es
    ///   zwei Abrufe am Tag, nur der des Timers installiert). Der Tray kennt
    ///   den Timerzustand ohnehin nur aus der Abfrage beim Öffnen des Menüs
    ///   (`handleMenuEvents`) und richtet die Suche nicht danach aus.
    /// * FE-10 (2b-Auflage 5): Je Suche schreibt der Tray dieselben drei
    ///   Zeilen wie bei „Check for updates now", mit `autocheck`
    ///   (`starting`, `started pid=`, beim Abholen `exit= outcome=`); die
    ///   Meldung des Kindes steht zusätzlich im Journal (es erbt stderr).
    ///   „Kein Fehlerschwall" heißt: keine Menüänderung bei 12 oder „konnte
    ///   nicht laufen", kein Wiederholversuch außer dem einen Nachversuch.
    func pollAutomaticCheck(now: Date) {
        guard let due = nextAutomaticCheck, now >= due, updateChild == nil else { return }
        let isRetry = automaticRetryPending
        automaticRetryPending = false
        // Gilt, wenn kein Kind zustande kommt; beim Abholen neu gesetzt.
        nextAutomaticCheck = now.addingTimeInterval(TrayUpdateCheck.automaticInterval)

        switch AutostartExecutable.resolve() {
        case .usable(let path):
            log.always("update=autocheck starting")
            if let pid = starter.start(executable: path, arguments: ["--check-update"]) {
                log.always("update=autocheck started pid=\(pid)")
                updateCheckBeforeAutomatic = updateCheck
                updateChild = (pid, path, .automaticCheck(startedAt: now, isRetry: isRetry))
                updateCheck = .running
                publish(makeView(now: now))
            } else {
                log.always("update=autocheck spawn failed")
            }
        case .unusable(let reason):
            log.always("update=autocheck unusable — \(reason)")
        }
    }

    /// Holt das Kind von „Check for updates now" bzw. der Suche ab Werk ab,
    /// falls es beendet ist — je Schleifendurchlauf (≤ 1 s, FE 11). Nicht
    /// privat, damit der Pfad ohne `run(selftestDeadline:)` fahrbar ist.
    ///
    /// Bei Exit 0 trennt die **Dateiidentität** „aktuell" von „ersetzt"
    /// (2b-Auflage 1): Identität(Pfad) ≠ Identität(`/proc/self/exe`). Der Pfad
    /// kann schon VOR dem Klick ersetzt gewesen sein (früherer Lauf ohne
    /// Neustart); ein Vorher/Nachher-Vergleich verfehlte das. Das gilt auch
    /// für die Suche (CM-36 · FE-11). Bei Exit 14 entscheidet das Schreibrecht
    /// am Verzeichnis des Pfads, ob die Zeile Installation verspricht
    /// (2b-Auflage 2) — gemessen, nicht gesperrt.
    func pollUpdateCheck() {
        guard let child = updateChild else { return }
        guard case .exited(let code) = starter.poll(child.pid) else { return }
        updateChild = nil

        var exitStatus: Int32? = code
        var replaced = false
        var writable = true
        if code == 14 {
            writable = access(Self.parentDirectory(of: child.path), W_OK) == 0
        }
        if code == 0 {
            if let onDisk = AutostartExecutable.fileIdentity(followingLinks: child.path),
               let running = AutostartExecutable.fileIdentity(followingLinks: "/proc/self/exe") {
                replaced = onDisk != running
            } else {
                // Eigenes Binary nicht auflösbar (FE 9): kein „aktuell" behaupten.
                exitStatus = nil
            }
        }
        let outcome = TrayUpdateCheck.outcome(
            exitStatus: exitStatus, binaryReplaced: replaced, directoryWritable: writable
        )
        switch child.kind {
        case .install:
            log.always("update=check exit=\(code) outcome=\(outcome)")
            updateCheck = .finished(outcome)
        case .automaticCheck(let startedAt, let isRetry):
            log.always("update=autocheck exit=\(code) outcome=\(outcome)")
            updateCheck = TrayUpdateCheck.afterAutomaticCheck(outcome, previous: updateCheckBeforeAutomatic)
            if nextAutomaticCheck != nil {
                let next = TrayUpdateCheck.nextAutomaticCheck(startedAt: startedAt, outcome: outcome, wasRetry: isRetry)
                nextAutomaticCheck = next.date
                automaticRetryPending = next.isRetry
            }
        }
        publish(makeView(now: Date()))
    }

    /// Das Verzeichnis eines absoluten Pfads (wie `UpdateClient`).
    private static func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// Ein Klick auf „Start at login": Umkehr des beim Klick angezeigten
    /// Häkchens (F4), danach **immer** neu erfragen (F5).
    ///
    /// Synchron aus der einen Schleife — `daemon-reload` braucht gemessen
    /// ≈ 0,3 s, weit unter der 10-s-Frist der Gegenstelle.
    private func attemptAutostart(showing checkmark: TrayMenuItem.Checkmark?) {
        let attempt: TrayAutostartDisplay.Attempt = (checkmark?.isOn ?? false) ? .uninstall : .install
        let word = attempt == .install ? "install" : "uninstall"
        // Vor dem Versuch, damit ein hängender Nutzermanager im Journal
        // zuordenbar ist.
        log.always("autostart=\(word) started")
        let exit = attempt == .install ? installer.install() : installer.uninstall()
        autostart = autostart.afterAttempt(
            attempt,
            succeeded: exit == .ok,
            reading: installer.reading(),
            binary: installer.binaryMatch()
        )
        log.always("autostart=\(word) exit=\(exit.rawValue)")

        // 2b-Auflage 8: Während des Versuchs stand die Schleife; ein
        // erneuter Klick in dieser Zeit sah noch den alten Stand. Er wird
        // jetzt abgeholt und verworfen, statt den Versuch umzukehren.
        if let late = try? connection.pump(timeoutMilliseconds: 0) {
            for message in late { handle(signal: message) }
        }
        menu.discardPendingActions(role: .startAtLogin)

        publish(makeView(now: Date()))
    }

    /// Ein Klick auf „Automatic updates" (CM-37 · FE 3): wie
    /// ``attemptAutostart(showing:)``, nur für den Timer. Ankreuzen startet
    /// nichts sofort (FE 4); die erste Prüfung läuft 15 min nach dem nächsten
    /// Login.
    private func attemptAutoUpdate(showing checkmark: TrayMenuItem.Checkmark?) {
        let attempt: TrayAutoUpdateDisplay.Attempt = (checkmark?.isOn ?? false) ? .uninstall : .install
        let word = attempt == .install ? "install" : "uninstall"
        log.always("autoupdate=\(word) started")
        let exit = attempt == .install ? installer.installAutoUpdate() : installer.uninstallAutoUpdate()
        autoUpdate = autoUpdate.afterAttempt(
            attempt,
            succeeded: exit == .ok,
            reading: installer.autoUpdateReading()
        )
        log.always("autoupdate=\(word) exit=\(exit.rawValue)")

        // Spät eingegangene Klicks derselben Rolle werden abgeholt und
        // verworfen (wie bei „Start at login"); Klicks auf andere Rollen
        // bleiben unberührt.
        if let late = try? connection.pump(timeoutMilliseconds: 0) {
            for message in late { handle(signal: message) }
        }
        menu.discardPendingActions(role: .automaticUpdates)

        publish(makeView(now: Date()))
    }

    /// Die Oberfläche aus dem aktuellen Zustand — der EINE Weg, auf dem der
    /// Prozess eine Ansicht baut, damit der Autostart-Block nie fehlt.
    private func makeView(now: Date) -> TrayView {
        Self.makeView(
            state: state, autostart: autostart, autoUpdate: autoUpdate, updateCheck: updateCheck, now: now
        )
    }

    /// Statisch, weil `init` die Ansicht braucht, bevor alle gespeicherten
    /// Eigenschaften belegt sind (2b-Auflage 1).
    private static func makeView(
        state: MonitorViewState,
        autostart: TrayAutostartDisplay,
        autoUpdate: TrayAutoUpdateDisplay,
        updateCheck: TrayUpdateCheck,
        now: Date
    ) -> TrayView {
        TrayPresentation.make(
            for: state, now: now, autostart: autostart, autoUpdate: autoUpdate, updateCheck: updateCheck
        )
    }

    /// Ist die Abnahmefolge des Selbsttests durchlaufen?
    ///
    /// Verlangt **beides**: eine Eigenschaftsabfrage auf dem Item und einen
    /// Layout-Abruf auf dem Menü. Nur zusammen belegen sie, dass die
    /// Gegenstelle das Item wirklich aufnimmt — ein Item ohne abgefragtes Menü
    /// wäre nach Fachentscheid 5.1 unsichtbar.
    private var selftestPassed: Bool {
        let served = connection.servedCalls
        let askedProperties = served.contains("org.freedesktop.DBus.Properties.GetAll")
            || served.contains("org.freedesktop.DBus.Properties.Get")
        return askedProperties && served.contains("com.canonical.dbusmenu.GetLayout")
    }

    /// Reagiert auf Bus-Signale — im Kern auf das Kommen des Watchers.
    func handle(signal message: DBusMessage) {
        guard message.type == .signal,
              message.member == "NameOwnerChanged"
        else { return }
        var reader = message.bodyReader()
        guard let name = try? reader.readString(), name == Self.watcherName else { return }
        _ = try? reader.readString()
        let newOwner = (try? reader.readString()) ?? ""
        guard !newOwner.isEmpty else {
            log.always("watcher=gone — waiting")
            registeredWithWatcher = false
            return
        }
        registerWithWatcher()
    }

    // MARK: Lesen und Senden

    /// Ein Lesevorgang samt Aktualisierung der Oberfläche.
    func refresh(now: Date) {
        nextRead = now.addingTimeInterval(Self.pollInterval)
        let result = reader.read(homeDirectory: homeDirectory, now: now)
        state = state.reduced(with: result)
        report(result)
        publish(makeView(now: now))
    }

    /// Schickt, was sich geändert hat — und nur das (Fachentscheid 5.12).
    private func publish(_ view: TrayView) {
        let changes = item.apply(view)
        if !changes.isEmpty {
            connection.emit(
                path: Self.itemPath,
                interface: "org.freedesktop.DBus.Properties",
                member: "PropertiesChanged",
                arguments: [
                    .string(TraySNIProperties.itemInterface),
                    .dictionary(changes),
                    .array(elementSignature: "s", elements: [])
                ]
            )
            // Manche Panels hören auf das alte Signal statt auf
            // `PropertiesChanged`; es kostet nichts und deckt beide ab.
            if changes.contains(where: { $0.key == "IconPixmap" }) {
                connection.emit(
                    path: Self.itemPath,
                    interface: TraySNIProperties.itemInterface,
                    member: "NewIcon",
                    arguments: []
                )
            }
        }

        let update = menu.apply(view.menu)
        if update.structureChanged {
            connection.emit(
                path: Self.menuPath,
                interface: TraySNIProperties.menuInterface,
                member: "LayoutUpdated",
                arguments: [.uint32(menu.revision), .int32(TrayMenuIdentifiers.root)]
            )
        } else if !update.isEmpty {
            connection.emit(
                path: Self.menuPath,
                interface: TraySNIProperties.menuInterface,
                member: "ItemsPropertiesUpdated",
                arguments: [update.updated, update.removed]
            )
        }
    }

    /// Protokolliert den Ausgang eines Lesevorgangs — entprellt und redigiert.
    ///
    /// Nur benannte Skalare. Insbesondere geht der `reason`-Text des Falls
    /// `unreadable` **nicht** hinaus: Er ist ein fremdbestimmter Decoder-Text
    /// und kann Dateiinhalt tragen. Die Rauchprobe druckt ihn bewusst noch —
    /// sie ist ein einmalig gestartetes Entwicklerwerkzeug. Dieser Prozess ist
    /// resident, und seine Zeilen bleiben im Journal stehen.
    private func report(_ result: UsageStoreReadResult) {
        switch result {
        case .success(let snapshot):
            log.note("store", "store=ok accounts=\(snapshot.accounts.count)")
        case .storeNotFound(let paths):
            log.note("store", "store=notFound searched=\(paths.count)")
            if log.canPrintPaths {
                for path in paths { log.note("path.\(path)", "searched: \(path)") }
            }
        case .unsupportedSchemaVersion(let found, let expected):
            log.note(
                "store",
                "store=unsupportedSchemaVersion found=\(found.map(String.init) ?? "none") "
                    + "expected=\(expected)"
            )
        case .unreadable:
            log.note("store", "store=unreadable (reason withheld by print contract)")
        }
    }

    /// Sauberer Abbau: Verbindung schließen. Der Watcher merkt das über
    /// `NameOwnerChanged` und nimmt das Item aus dem Panel (gemessen: Liste
    /// 5 → 4).
    func shutDown() {
        connection.close()
    }
}

// MARK: - Start

/// Baut alles auf und gibt den Beendigungscode zurück.
func runTray(arguments: [String], environment: [String: String]) -> TrayExit {
    // CM-27 — SIGPIPE prozessweit ignorieren, BEVOR die erste Verbindung steht.
    //
    // `DBusConnection.writeAll` schreibt mit `write(2)`; ein Flags-Parameter wie
    // `MSG_NOSIGNAL` existiert nur bei `send(2)` und steht hier nicht zur
    // Verfügung. Ohne diesen Schalter beendet die Standardaktion von SIGPIPE den
    // Prozess per Signal (Exit 141), sobald der Bus während eines
    // Schreibversuchs abreißt — und der Exit-Vertrag oben (`connectionFailed`
    // = 6), an dem der systemd-Dienst aus `CM-21` „falsch eingerichtet" von
    // „gescheitert" unterscheidet, wäre gebrochen. Mit `SIG_IGN` liefert
    // `write` stattdessen `-1`/`EPIPE`, der Abriss fällt im nächsten `pump()`
    // auf und die Schleife verlässt sich geordnet mit 6.
    //
    // Die Platzierung ist bewusst die allererste Anweisung: Schon der
    // SASL-Handshake in `DBusConnection(socketPath:)` schreibt, also lange vor
    // der SIGTERM/SIGINT-Registrierung weiter unten.
    //
    // ⚠️ Reichweite: Das schützt den Tray-PRODUKTIONSPROZESS. Wer
    // `DBusConnection` außerhalb von `runTray` aufbaut — insbesondere die Tests
    // — muss SIGPIPE selbst ignorieren (siehe `FakeSessionBus.sigpipeIgnoriert`).
    // Die `claude-monitor`-CLI ist bewusst NICHT erfasst: Sie darf beim Piping
    // weiter idiomatisch an SIGPIPE sterben.
    _ = signal(SIGPIPE, SIG_IGN)

    let isSelftest = arguments.contains("--selftest")
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let log = TrayLog(homeDirectory: homeDirectory)

    guard let socketPath = DBusConnection.sessionBusSocketPath() else {
        // Im dokumentierten Bau-/Testgleis (Container `swift:6.3.3`) ist das
        // der Normalfall — dort gibt es keine Sitzung. Exit 5 heißt „nicht
        // gelaufen" und ist NIE ein bestandener Selbsttest (Auflage 11).
        log.always("bus=unavailable (DBUS_SESSION_BUS_ADDRESS not set)")
        return .busAddressMissing
    }

    let connection: DBusConnection
    do {
        connection = try DBusConnection(socketPath: socketPath)
    } catch {
        log.always("bus=connectFailed")
        return .connectionFailed
    }

    // Einzelinstanz vor allem anderen: Eine zweite Instanz soll sich
    // verabschieden, bevor sie ein zweites Item anmeldet.
    //
    // Der Fehlerfall wird ausdrücklich unterschieden (CM-27): Ein Busabriss
    // WÄHREND `RequestName` ist kein „läuft schon" — er darf nicht auf Exit 8
    // führen, sondern gehört zum Verbindungsausgang 6. Nur ein ECHTES
    // `RequestName`-Ergebnis darf `.alreadyRunning` auslösen.
    let ownership: DBusConnection.RequestNameResult
    do {
        ownership = try connection.requestName(TrayProcess.wellKnownName)
    } catch let error as DBusConnection.ConnectError {
        log.always("bus=\(TrayExit.busState(for: error)) step=requestName reason=\(TrayExit.reason(for: error))")
        connection.close()
        return .connectionFailed
    } catch {
        log.always("bus=disconnected step=requestName")
        connection.close()
        return .connectionFailed
    }
    switch ownership {
    case .primaryOwner, .alreadyOwner:
        break
    case .exists, .inQueue:
        log.always("instance=alreadyRunning name=\(TrayProcess.wellKnownName)")
        connection.close()
        return .alreadyRunning
    }

    signal(SIGTERM, trayNoteStopSignal)
    signal(SIGINT, trayNoteStopSignal)

    let process = TrayProcess(
        connection: connection,
        homeDirectory: homeDirectory,
        log: log,
        now: Date(),
        environment: environment
    )
    process.observeWatcher()

    // Auch hier gilt CM-27: Ein Abriss während `NameHasOwner` ist kein
    // „Watcher fehlt" (Exit 9), sondern ein Verbindungsausgang (Exit 6). Nur
    // eine ECHTE Antwort des Busses darf auf `.watcherMissing` führen.
    let watcherPresent: Bool
    do {
        watcherPresent = try connection.nameHasOwner(TrayProcess.watcherName)
    } catch DBusConnection.ConnectError.timedOut {
        // Fund 1 (CM-27): Ein 5s-Bus-Haenger auf `NameHasOwner` ist kein
        // Abriss, sondern eine langsame Antwort — aber auch keine ECHTE
        // Antwort des Busses (siehe Kommentar oben). Im Normalbetrieb bleibt
        // das alte Verhalten (vor der Auflage-3-Umstellung auf do/catch)
        // erhalten: Watcher als "absent"/"waiting" behandeln statt den
        // Prozess zu beenden. Im Selbsttest darf ein bloßer Timeout aber NIE
        // auf `.watcherMissing` (Exit 9) münden — das wäre eine ECHTE
        // Antwort vortäuschen, wo keine da war. Stattdessen `.selftestIncomplete`
        // (Exit 7), derselbe Exit-Code wie beim Fristablauf in `run(...)`.
        if isSelftest {
            log.always("watcher=unknown step=nameHasOwner reason=timedOut — selftest incomplete")
            process.shutDown()
            return .selftestIncomplete
        }
        watcherPresent = false
    } catch let error as DBusConnection.ConnectError {
        log.always("bus=\(TrayExit.busState(for: error)) step=nameHasOwner reason=\(TrayExit.reason(for: error))")
        process.shutDown()
        return .connectionFailed
    } catch {
        log.always("bus=disconnected step=nameHasOwner")
        process.shutDown()
        return .connectionFailed
    }
    if watcherPresent {
        process.registerWithWatcher()
    } else if isSelftest {
        // Der Selbsttest braucht eine lebende Sitzung; ohne Watcher hat er
        // nichts zu messen und darf nicht „bestanden" melden (Auflage 13).
        log.always("watcher=absent name=\(TrayProcess.watcherName)")
        process.shutDown()
        return .watcherMissing
    } else {
        // Im Normalbetrieb ist das kein Abbruchgrund: Der Prozess läuft
        // weiter, sagt es EINMAL und meldet sich an, sobald der Watcher
        // erscheint (`NameOwnerChanged`).
        log.always("watcher=absent — waiting for \(TrayProcess.watcherName)")
    }

    let exitCode = process.run(
        selftestDeadline: isSelftest ? Date().addingTimeInterval(TrayProcess.selftestTimeout) : nil
    )
    process.shutDown()
    if isSelftest {
        log.always("selftest=\(exitCode == .ok ? "passed" : "incomplete") exit=\(exitCode.rawValue)")
    }
    return exitCode
}

// MARK: - Vordertür (CM-21)

/// Wertet die Argumente aus, **bevor** irgendetwas mit dem Bus passiert.
///
/// Warum vor `runTray`: Die Verbindung zum Sitzungsbus beginnt dort, und ohne
/// Sitzung endet sie mit Exit 5. Die Autostart-Unterbefehle brauchen keinen
/// Bus — sie dürfen an diesem Ausgang nicht scheitern.
///
/// ⚠️ **Unbekannte `--`-Argumente brechen ab** (Auflage 13). Bis CM-21 war
/// `--selftest` das einzige ausgewertete Argument, alles andere fiel durch und
/// startete den residenten Tray. Mit drei Unterbefehlen mehr würde ein
/// Tippfehler (`--instal-autostart`) genau das tun, während der Nutzer glaubt,
/// er habe eingerichtet. Der argumentlose Start und `--selftest` bleiben
/// unverändert; freie Argumente ohne `--` werden weiterhin ignoriert.
func trayFrontDoor(arguments: [String], environment: [String: String]) -> TrayExit {
    // Auflage 5: derselbe Home-Wert, aus dem auch `AutostartPaths` den
    // Unit-Pfad ableitet — sonst redigiert der Filter ein Präfix, das in den
    // gedruckten Pfaden nicht vorkommt. Ziel ist wie überall stderr; einen
    // zweiten Ausgabeweg bekommt dieser Prozess nicht.
    let home = AutostartPaths.homeDirectory(environment: environment)
    let log = TrayLog(homeDirectory: URL(fileURLWithPath: home ?? "/"))

    // `--help`/`-h` zuerst und mit Exit 0: Vor CM-21-Fund 3 endete `--help`
    // als „Unknown option" (Exit 10) und `-h` fiel durch zu `runTray` (Exit 5,
    // startet den residenten Tray) — beides bricht ein bloßes Nachschauen der
    // Hilfe in jedem Skript. `-h` trägt keinen `--`-Präfix und muss deshalb
    // VOR dem `--`-Filter geprüft werden.
    let rawArguments = arguments.dropFirst()
    if rawArguments.contains("--help") || rawArguments.contains("-h") {
        log.always(AutostartTexts.usage)
        return .ok
    }

    let options = rawArguments.filter { $0.hasPrefix("--") }
    let autostartOptions = options.filter { $0 != "--selftest" }
    let known: Set<String> = [
        "--install-autostart", "--uninstall-autostart", "--autostart-status",
        // CM-29
        "--version", "--update",
        // CM-36
        "--check-update",
        "--install-auto-update", "--uninstall-auto-update", "--auto-update-status"
    ]

    if let unknown = autostartOptions.first(where: { !known.contains($0) }) {
        log.always(AutostartTexts.unknownOption(unknown))
        return .autostartBlocked
    }
    guard let subcommand = autostartOptions.first else {
        return runTray(arguments: arguments, environment: environment)
    }
    guard autostartOptions.count == 1, !options.contains("--selftest") else {
        log.always(AutostartTexts.conflictingOptions)
        return .autostartBlocked
    }

    if subcommand == "--version" {
        printVersion()
        return .ok
    }

    let runner = PosixCommandRunner(environment: environment)
    if subcommand == "--update" {
        return UpdateClient(environment: environment, runner: runner, emit: { log.always($0) }).run()
    }
    if subcommand == "--check-update" {
        return UpdateClient(environment: environment, runner: runner, emit: { log.always($0) }).check()
    }

    let installer = AutostartInstaller(
        environment: environment,
        runner: runner,
        emit: { log.always($0) }
    )
    switch subcommand {
    case "--install-autostart": return installer.install()
    case "--uninstall-autostart": return installer.uninstall()
    case "--install-auto-update": return installer.installAutoUpdate()
    case "--uninstall-auto-update": return installer.uninstallAutoUpdate()
    case "--auto-update-status": return installer.autoUpdateStatus()
    default: return installer.status()
    }
}

/// `--version` (CM-29).
///
/// ⚠️ **Eingefrorener Client-Vertrag.** Jeder installierte Client startet das
/// NEUE Binary vor dem Austausch mit `--version` und vergleicht die Ausgabe
/// zeichengleich (FE 8). Kanal (`UpdateDecision.versionOutputDescriptor`,
/// stdout) und Wortlaut (`UpdateDecision.versionLine`) stehen deshalb im Ziel
/// `Update` und nur dort. Ändert eine spätere Fassung eines von beiden, lehnen
/// alle installierten Clients jedes Update dauerhaft mit 13 ab.
/// `scripts/release-linux.sh` prüft die Zeile am gebauten und am ausgepackten
/// Binary. Nicht über `TrayLog`: der schreibt auf stderr und redigiert.
func printVersion() {
    let line = UpdateDecision.versionLine(version: TrayTexts.version, buildVersion: TrayTexts.buildVersion) + "\n"
    let bytes = Array(line.utf8)
    var offset = 0
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        while offset < bytes.count {
            let written = Glibc.write(UpdateDecision.versionOutputDescriptor, base + offset, bytes.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            return
        }
    }
}

exit(trayFrontDoor(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
).rawValue)
