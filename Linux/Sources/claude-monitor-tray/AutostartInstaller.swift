import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Autostart
import ClaudeMonitorShared

/// Die I/O-Seite des Autostarts (CM-21): Datei anlegen, `systemctl` rufen,
/// Ergebnis melden.
///
/// Die **Regeln** stehen im Ziel `Autostart` — Pfadauflösung, Unit-Text,
/// Auswertung der `is-enabled`-Antwort, Entscheidungstabelle und sämtliche
/// Texte. Hier steht nur, was ohne echtes Dateisystem und ohne echten
/// Nutzermanager nicht geht (CM-20-Schichtung).
struct AutostartInstaller {

    /// Die Umgebung, aus der **alle** Pfade abgeleitet werden.
    let environment: [String: String]
    /// Der Zugang zu `systemctl`.
    let runner: CommandRunner
    /// Der Ausgabekanal.
    let emit: (String) -> Void

    // MARK: - Unterbefehle

    /// `--install-autostart`
    func install() -> TrayExit {
        guard let layout = resolvedLayout() else { return .autostartUnavailable }
        guard managerReachable() else { return .autostartUnavailable }

        let executablePath: String
        switch AutostartExecutable.resolve() {
        case .usable(let path):
            executablePath = path
        case .unusable(let reason):
            emit(AutostartTexts.executableNotUsable(reason: reason))
            return .autostartBlocked
        }

        let before = currentReading()
        guard let stateBefore = usableState(before) else { return .autostartUnavailable }

        let target = probe(unitPath: layout.unitPath)
        switch AutostartPlan.plan(target: target, status: before) {
        case .refuseSymlink:
            emit(AutostartTexts.symlinkAtTarget(unitPath: layout.unitPath))
            return .autostartBlocked
        case .refuseForeignFile:
            emit(AutostartTexts.foreignFile(unitPath: layout.unitPath))
            return .autostartBlocked
        case .alreadyMaskedInform:
            emit(AutostartTexts.masked(unitName: AutostartPaths.unitName))
            return .autostartBlocked
        case .install:
            break
        }

        // Auflage 17: Scheitert schon das Verzeichnis, wird nicht
        // weitergelaufen — sonst folgte ein `enable` auf eine Unit, die es
        // nicht gibt, und die Meldung wäre erfunden.
        if let reason = createDirectory(layout.unitDirectory) {
            emit(AutostartTexts.directoryNotCreated(path: layout.unitDirectory, reason: reason))
            return .autostartUnavailable
        }

        let unitText = AutostartUnit.render(executablePath: executablePath)
        if let code = writeUnit(unitText, to: layout.unitPath) {
            // `O_NOFOLLOW` beantwortet einen Symlink am Zielpfad mit `ELOOP`.
            // Das ist der Abbruchgrund — niemals ein Überschreiben: Ein
            // `Data.write(to:options:.atomic)` ersetzte den Symlink still
            // durch eine reguläre Datei, ein nicht-atomares Schreiben schriebe
            // lautlos an sein Ziel (etwa `/dev/null`). Beides gemessen.
            if code == ELOOP {
                emit(AutostartTexts.symlinkAtTarget(unitPath: layout.unitPath))
                return .autostartBlocked
            }
            emit(AutostartTexts.writeFailed(path: layout.unitPath, reason: errnoName(code)))
            return .autostartUnavailable
        }

        _ = systemctl(["daemon-reload"])
        _ = systemctl(["enable", AutostartPaths.unitName])

        // Auflage 15b: Eine fehlende grafische Zielgruppe bricht die
        // Einrichtung NICHT ab — die Unit ist geschrieben und eingeschaltet
        // und greift, sobald die Zielgruppe aktiv wird. Sie darf aber auch
        // nicht verschwiegen werden, sonst wartet der Nutzer auf etwas, das
        // auf seinem System nie kommt.
        let activity = systemctl(["is-active", AutostartPaths.installTargetName])
        let activityWord = AutostartStatus.firstWordOfOutput(activity.standardOutput)
        if activityWord != "active" {
            emit(AutostartTexts.graphicalSessionInactive(word: activityWord.isEmpty ? "unknown" : activityWord))
        }

        // Der Zustand wird NEU erfragt und genau er gemeldet — nie aus dem
        // Rückgabecode von `enable` abgeleitet. Das ist das Vorgehen des
        // macOS-Vorbilds (`LoginItemController.swift:47-58`): Der Zustand ist
        // das, was das System sagt, nicht das, was der letzte Aufruf vorhatte.
        let after = currentReading()
        guard let stateAfter = usableState(after) else { return .autostartUnavailable }
        switch stateAfter {
        case .enabled:
            emit(stateBefore == .enabled
                ? AutostartTexts.alreadyEnabled(unitPath: layout.unitPath)
                : AutostartTexts.installed(unitPath: layout.unitPath))
            return .ok
        case .requiresApproval:
            emit(AutostartTexts.masked(unitName: AutostartPaths.unitName))
            return .autostartBlocked
        case .disabled:
            emit(AutostartTexts.enableDidNotTake(unitName: AutostartPaths.unitName))
            return .autostartBlocked
        }
    }

    /// `--uninstall-autostart`
    func uninstall() -> TrayExit {
        guard let layout = resolvedLayout() else { return .autostartUnavailable }
        guard managerReachable() else { return .autostartUnavailable }

        // Auflage 3: Der Zustand wird VOR `disable` gemessen. Bei einer
        // maskierten Unit antwortet `systemctl --user disable` mit „is masked,
        // ignoring" und rc=0, entfernt den `.wants`-Verweis aber NICHT — nach
        // dem Löschen der Unit-Datei bliebe ein toter Link liegen, und
        // „entfernt" wäre eine Falschauskunft.
        let before = currentReading()
        guard let stateBefore = usableState(before) else { return .autostartUnavailable }

        let existedBefore = probe(unitPath: layout.unitPath).exists
            || layout.wantsLinkPaths.contains { pathExists($0) }

        if stateBefore == .requiresApproval {
            // Die Maske selbst bleibt stehen: Sie ist eine Entscheidung des
            // Nutzers über systemd, nicht über diese App. Aufgehoben wird sie
            // von Hand (`systemctl --user unmask …`).
            emit(AutostartTexts.maskKept(unitName: AutostartPaths.unitName))
        } else if stateBefore == .enabled {
            _ = systemctl(["disable", AutostartPaths.unitName])
        }

        if unlink(layout.unitPath) != 0 && errno != ENOENT {
            emit(AutostartTexts.writeFailed(path: layout.unitPath, reason: errnoName(errno)))
            return .autostartBlocked
        }

        for link in layout.wantsLinkPaths where pathExists(link) {
            if unlink(link) != 0 && errno != ENOENT {
                emit(AutostartTexts.staleWantsLink(path: link))
                return .autostartBlocked
            }
        }

        _ = systemctl(["daemon-reload"])

        // Gegenprobe statt Zusage: Erst wenn kein Verweis mehr auf die
        // gelöschte Unit zeigt, darf „entfernt" gemeldet werden.
        if let remaining = layout.wantsLinkPaths.first(where: { pathExists($0) }) {
            emit(AutostartTexts.staleWantsLink(path: remaining))
            return .autostartBlocked
        }

        emit(existedBefore
            ? AutostartTexts.removed(unitPath: layout.unitPath)
            : AutostartTexts.nothingToRemove(unitPath: layout.unitPath))
        return .ok
    }

    /// `--autostart-status`
    func status() -> TrayExit {
        guard let layout = resolvedLayout() else { return .autostartUnavailable }
        guard managerReachable() else { return .autostartUnavailable }

        guard let state = usableState(currentReading()) else { return .autostartUnavailable }
        switch state {
        case .enabled:
            emit(AutostartTexts.statusEnabled(unitPath: layout.unitPath))
        case .disabled:
            emit(AutostartTexts.statusDisabled(unitPath: layout.unitPath))
        case .requiresApproval:
            emit(AutostartTexts.masked(unitName: AutostartPaths.unitName))
        }
        // Eine Auskunft ist gelungen — auch „maskiert" ist eine. Blockiert ist
        // hier nichts, weil nichts eingerichtet werden sollte.
        return .ok
    }

    // MARK: - Gemeinsame Schritte

    private func resolvedLayout() -> AutostartPaths.Layout? {
        switch AutostartPaths.layout(environment: environment) {
        case .success(let layout):
            return layout
        case .failure(.noHomeDirectory):
            emit(AutostartTexts.noHomeDirectory)
            return nil
        }
    }

    /// Vorbedingung vor jedem `systemctl`-Aufruf.
    ///
    /// Ohne `XDG_RUNTIME_DIR`/Sitzungsbus gibt es keinen Nutzermanager; jede
    /// Antwort wäre dann eine Aussage über eine Messung, die nicht
    /// stattgefunden hat (Auflage 1).
    private func managerReachable() -> Bool {
        guard AutostartPaths.managerCanBeReachable(environment: environment) else {
            emit(AutostartTexts.managerUnavailable)
            return false
        }
        return true
    }

    private func currentReading() -> AutostartStatus.Reading {
        let outcome = systemctl(["is-enabled", AutostartPaths.unitName])
        return AutostartStatus.reading(
            isEnabledOutput: outcome.standardOutput,
            exitStatus: outcome.exitStatus,
            standardError: outcome.standardError
        )
    }

    /// Wandelt eine Messung in einen Schalterzustand — oder meldet, warum das
    /// nicht geht, und gibt `nil` zurück.
    private func usableState(_ reading: AutostartStatus.Reading) -> LoginItemState? {
        switch reading {
        case .known(let state):
            return state
        case .unexpected(let word):
            emit(AutostartTexts.unexpectedState(word: word))
            return nil
        case .unreadable(let word):
            emit(AutostartTexts.unreadableState(word: word))
            return nil
        case .managerUnavailable:
            emit(AutostartTexts.managerUnavailable)
            return nil
        }
    }

    private func systemctl(_ arguments: [String]) -> CommandOutcome {
        runner.run(executable: "systemctl", arguments: ["--user"] + arguments)
    }

    // MARK: - Dateisystem

    private func probe(unitPath: String) -> AutostartTargetProbe {
        var info = stat()
        // `lstat`, nicht `stat`: Gefragt ist der Zielpfad SELBST, nicht das,
        // worauf er zeigt.
        guard lstat(unitPath, &info) == 0 else {
            return AutostartTargetProbe(exists: false, isSymlink: false, carriesMarker: false)
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            return AutostartTargetProbe(exists: true, isSymlink: true, carriesMarker: false)
        }
        let contents = (try? String(contentsOfFile: unitPath, encoding: .utf8)) ?? ""
        return AutostartTargetProbe(
            exists: true,
            isSymlink: false,
            carriesMarker: AutostartUnit.carriesMarker(contents)
        )
    }

    /// Ob am Pfad etwas liegt — auch ein toter Symlink zählt.
    private func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Legt das Verzeichnis samt Elternteilen an.
    ///
    /// - Returns: `nil` bei Erfolg, sonst der benannte Grund.
    private func createDirectory(_ path: String) -> String? {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if mkdir(current, 0o755) == 0 { continue }
            let code = errno
            if code == EEXIST {
                var info = stat()
                if stat(current, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR { continue }
                return "\(current) exists and is not a directory"
            }
            return "\(current): \(errnoName(code))"
        }
        return nil
    }

    /// Schreibt die Unit — **ohne** Symlink zu folgen.
    ///
    /// - Returns: `nil` bei Erfolg, sonst `errno`.
    private func writeUnit(_ text: String, to path: String) -> Int32? {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_TRUNC, mode_t(0o644))
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }

        let bytes = Array(text.utf8)
        var offset = 0
        var failure: Int32?
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                failure = errno
                return
            }
        }
        return failure
    }

    /// Ein **fester** Bezeichner je `errno` — kein `strerror`, dessen Text von
    /// der Spracheinstellung des Systems abhängt.
    ///
    /// Das ist kein Meldungstext, sondern ein benannter Grund, wie ihn
    /// `TrayExit.reason(for:)` liefert: Der Satz drumherum steht in
    /// ``AutostartTexts``, hier steht nur das Wort für die Ursache (Auflage 11).
    private func errnoName(_ code: Int32) -> String {
        switch code {
        case EACCES: return "EACCES (permission denied)"
        case EPERM: return "EPERM (operation not permitted)"
        case EEXIST: return "EEXIST (already exists)"
        case ELOOP: return "ELOOP (symbolic link)"
        case ENOENT: return "ENOENT (no such file or directory)"
        case ENOSPC: return "ENOSPC (no space left)"
        case ENOTDIR: return "ENOTDIR (not a directory)"
        case EROFS: return "EROFS (read-only file system)"
        case EDQUOT: return "EDQUOT (disk quota exceeded)"
        default: return "errno=\(code)"
        }
    }
}

/// Der Pfad des LAUFENDEN Binaries — die Grundlage von `ExecStart=`.
enum AutostartExecutable {

    /// ⚠️ **Nicht** `CommandLine.arguments[0]`: Beim Start über `PATH` — dem in
    /// `Linux/INSTALL.md` beschriebenen Normalweg — steht dort nur
    /// `claude-monitor-tray`. Ein `ExecStart=claude-monitor-tray` ließe
    /// systemd erst beim nächsten Anmelden mit `203/EXEC` scheitern, also
    /// lange nachdem „eingerichtet" gemeldet wurde.
    ///
    /// Geprüft wird vor dem Rendern: absolut, vorhanden, reguläre Datei,
    /// ausführbar. Scheitert eine dieser Prüfungen, wird keine Unit
    /// geschrieben.
    static func resolve() -> Resolution {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return readlink("/proc/self/exe", base, pointer.count - 1)
        }
        guard count > 0 else { return .unusable(reason: "readlink /proc/self/exe failed, errno=\(errno)") }
        let path = String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        guard path.hasPrefix("/") else { return .unusable(reason: "the resolved path is not absolute") }
        guard !path.hasSuffix(" (deleted)") else {
            return .unusable(reason: "the running binary has been deleted")
        }
        var info = stat()
        guard stat(path, &info) == 0 else { return .unusable(reason: "cannot stat \(path), errno=\(errno)") }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .unusable(reason: "\(path) is not a regular file")
        }
        guard access(path, X_OK) == 0 else { return .unusable(reason: "\(path) is not executable") }
        return .usable(path)
    }

    /// Das Ergebnis der Auflösung.
    enum Resolution: Equatable {
        case usable(String)
        case unusable(reason: String)
    }
}
