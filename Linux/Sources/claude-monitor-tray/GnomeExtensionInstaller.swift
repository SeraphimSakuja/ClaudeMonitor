import Foundation
import Autostart
import GnomeExtension
#if canImport(Glibc)
import Glibc
#endif

/// `--install-gnome-extension`, `--uninstall-gnome-extension` und
/// `--refresh-gnome-extension` (CM-43): Ein- und Ausgabe der GNOME-Extension.
/// Die Regeln (Nutzlast, Pfade, Listenformat, Plan, Texte) stehen im Ziel
/// `GnomeExtension`; hier liegen Dateien und Prozesse.
///
/// Exit-Werte wie bei den Autostart-Unterbefehlen: **10** = die Bitte ließ
/// sich nicht ausführen, am Zielort steht etwas dagegen (Symlink, fremder
/// Inhalt, zweiter Lauf, Austausch gescheitert); **11** = es ließ sich nichts
/// messen oder die Einstellung hielt nicht. Ausnahme zu „nichts überschrieben":
/// scheitert ein Einzel-`rename` nach dem ersten, meldet der Lauf
/// „partly replaced" mit 10 — der Austausch ist dann nicht atomar.
///
/// ⚠️ **FE-9 — was wann greift.** Stylesheets und `schemas/gschemas.compiled`
/// liest die laufende Shell schon beim nächsten Entsperren bzw. Farbwechsel
/// neu von der Platte (`extensionSystem.js:44-45,104-121`, `:258-259`;
/// `sharedInternals.js:97-104`). `extension.js` und `popoverState.js` bleiben
/// bis zum nächsten Login alt. Darum gilt für jede neue Fassung: Schema-
/// Schlüssel und CSS-Klassen werden nur hinzugefügt, nie umbenannt oder
/// entfernt — sonst zeichnet das alte Skript mit neuer Vorlage falsch.
///
/// Ablauf je Befehl: (1) `dataHome`, (2) Einstellungen messen, **vor** jedem
/// Schreiben, (3) Sperre, Ziel prüfen, (4) Staging, (5) Austausch,
/// (6) `enabled-extensions` setzen und zurücklesen, (7) Meldung.
struct GnomeExtensionInstaller {

    let environment: [String: String]
    let runner: CommandRunner
    let emit: (String) -> Void

    private static let payloadPaths = GnomeExtensionPayload.files.map(\.relativePath)

    // MARK: - Befehle

    func install() -> TrayExit {
        guard let dataHome = resolveDataHome() else { return .autostartUnavailable }
        let settings: Settings
        switch readSettings(includeDisabled: true) {
        case .success(let value): settings = value
        case .failure(let exit): return exit
        }

        guard let lock = acquireLock(dataHome: dataHome) else { return .autostartBlocked }
        defer { close(lock) }

        let target = GnomeExtensionPaths.target(dataHome: dataHome)
        let state: TargetState
        switch inspectTarget(target) {
        case .success(let value): state = value
        case .failure(let exit): return exit
        }

        if let exit = putInPlace(dataHome: dataHome, target: target, existing: state == .directory, command: GnomeExtensionTexts.install) { return exit }

        if let exit = switchOn(settings: settings) { return exit }

        let version = GnomeExtensionPayload.shellVersions.joined(separator: ", ")
        emit(state == .absent
            ? GnomeExtensionTexts.installed(path: target, shellVersion: version)
            : GnomeExtensionTexts.updated(path: target, shellVersion: version))
        if settings.userExtensionsDisabled { emit(GnomeExtensionTexts.userExtensionsDisabled) }
        if settings.installationNotAllowed { emit(GnomeExtensionTexts.installationNotAllowed) }
        return .ok
    }

    func uninstall() -> TrayExit {
        guard let dataHome = resolveDataHome() else { return .autostartUnavailable }
        let settings: Settings
        switch readSettings(includeDisabled: false) {
        case .success(let value): settings = value
        case .failure(let exit): return exit
        }

        guard let lock = acquireLock(dataHome: dataHome) else { return .autostartBlocked }
        defer { close(lock) }

        let target = GnomeExtensionPaths.target(dataHome: dataHome)
        let state: TargetState
        switch inspectTarget(target) {
        case .success(let value): state = value
        case .failure(let exit): return exit
        }
        let listed = GnomeExtensionSettings.planDisable(enabled: settings.enabled, uuid: GnomeExtensionPayload.uuid)

        if state == .absent {
            guard let newList = listed else {
                emit(GnomeExtensionTexts.notInstalled)
                return .ok
            }
            if let exit = setEnabled(newList) { return exit }
            emit(GnomeExtensionTexts.switchedOffNothingInstalled)
            return .ok
        }

        if let exit = checkNoForeignContent(target) { return exit }

        // Zuerst ausschalten: Die laufende Shell reagiert auf
        // `changed::enabled-extensions` sofort (`extensionSystem.js:693-694`),
        // dadurch wird der Name frei und das Tray-Symbol ist zurück.
        if let newList = listed, let exit = setEnabled(newList) { return exit }

        for relative in Self.payloadPaths + [GnomeExtensionPayload.compiledSchemaPath] {
            let path = target + "/" + relative
            if unlink(path) != 0 && errno != ENOENT {
                emit(GnomeExtensionTexts.removeFailed(path: path, reason: AutostartInstaller.errnoName(errno)))
                return .autostartBlocked
            }
        }
        for directory in [target + "/" + GnomeExtensionPayload.schemasDirectory, target] {
            if rmdir(directory) != 0 && errno != ENOENT {
                emit(GnomeExtensionTexts.removeFailed(path: directory, reason: AutostartInstaller.errnoName(errno)))
                return .autostartBlocked
            }
        }
        emit(GnomeExtensionTexts.removed(path: target))
        return .ok
    }

    func refresh() -> TrayExit {
        guard let dataHome = resolveDataHome() else { return .autostartUnavailable }
        let target = GnomeExtensionPaths.target(dataHome: dataHome)

        // Kein Ziel ⇒ nichts zu tun, ohne Ausgabe und ohne etwas anzulegen
        // (kein Automatismus; unter KDE entstünde sonst ein leerer Ordner).
        var probe = stat()
        if lstat(target, &probe) != 0 && errno == ENOENT { return .ok }

        guard let lock = acquireLock(dataHome: dataHome) else { return .autostartBlocked }
        defer { close(lock) }

        let state: TargetState
        switch inspectTarget(target) {
        case .success(let value): state = value
        case .failure(let exit): return exit
        }
        if state == .absent { return .ok }
        if isUpToDate(target) { return .ok }

        if let exit = putInPlace(dataHome: dataHome, target: target, existing: true, command: GnomeExtensionTexts.refresh) { return exit }
        emit(GnomeExtensionTexts.refreshed)
        return .ok
    }

    // MARK: - Einstellungen

    private struct Settings {
        var enabled: [String]
        var disabled: [String]
        var userExtensionsDisabled: Bool
        var installationNotAllowed: Bool
    }

    private func readSettings(includeDisabled: Bool) -> Result<Settings, TrayExit> {
        let enabled: [String]
        switch readList("enabled-extensions") {
        case .success(let value): enabled = value
        case .failure(let exit): return .failure(exit)
        }
        var disabled: [String] = []
        if includeDisabled {
            switch readList("disabled-extensions") {
            case .success(let value): disabled = value
            case .failure(let exit): return .failure(exit)
            }
        }
        // Nur Warnungen: ein nicht lesbarer Wert verhindert nichts.
        let userDisabled = readBoolean("disable-user-extensions") ?? false
        let notAllowed = readBoolean("allow-extension-installation").map { !$0 } ?? false
        return .success(Settings(
            enabled: enabled,
            disabled: disabled,
            userExtensionsDisabled: userDisabled,
            installationNotAllowed: notAllowed
        ))
    }

    private func readList(_ key: String) -> Result<[String], TrayExit> {
        let outcome = runner.run(executable: "gsettings", arguments: ["get", "org.gnome.shell", key])
        guard outcome.didRun else {
            emit(GnomeExtensionTexts.toolNotRunnable(tool: "gsettings", reason: outcome.standardError))
            return .failure(.autostartUnavailable)
        }
        guard outcome.exitStatus == 0 else {
            emit(GnomeExtensionTexts.notGnomeSession)
            return .failure(.autostartUnavailable)
        }
        guard let list = GnomeExtensionSettings.parseStrv(outcome.standardOutput) else {
            emit(GnomeExtensionTexts.settingUnreadable(key: key))
            return .failure(.autostartUnavailable)
        }
        return .success(list)
    }

    private func readBoolean(_ key: String) -> Bool? {
        let outcome = runner.run(executable: "gsettings", arguments: ["get", "org.gnome.shell", key])
        guard outcome.didRun, outcome.exitStatus == 0 else { return nil }
        switch outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `set` + Zurücklesen. Abweichung ⇒ 11, die Dateien bleiben stehen.
    ///
    /// `set` kann ohne erreichbaren dconf-Dienst wirkungslos bleiben (rc 0),
    /// `get` liest die Datenbank direkt — darum zählt erst das Zurücklesen.
    private func setList(_ key: String, _ list: [String]) -> TrayExit? {
        let outcome = runner.run(
            executable: "gsettings",
            arguments: ["set", "org.gnome.shell", key, GnomeExtensionSettings.renderStrv(list)]
        )
        guard outcome.didRun else {
            emit(GnomeExtensionTexts.toolNotRunnable(tool: "gsettings", reason: outcome.standardError))
            return .autostartUnavailable
        }
        guard outcome.exitStatus == 0 else {
            emit(GnomeExtensionTexts.settingDidNotStick)
            return .autostartUnavailable
        }
        guard case .success(let readBack) = readList(key), readBack == list else {
            emit(GnomeExtensionTexts.settingDidNotStick)
            return .autostartUnavailable
        }
        return nil
    }

    private func setEnabled(_ list: [String]) -> TrayExit? {
        setList("enabled-extensions", list)
    }

    private func switchOn(settings: Settings) -> TrayExit? {
        guard let plan = GnomeExtensionSettings.planEnable(
            enabled: settings.enabled,
            disabled: settings.disabled,
            uuid: GnomeExtensionPayload.uuid
        ) else { return nil }
        if let enabled = plan.enabled, let exit = setList("enabled-extensions", enabled) { return exit }
        if let disabled = plan.disabled, let exit = setList("disabled-extensions", disabled) { return exit }
        return nil
    }

    // MARK: - Pfade, Sperre

    private func resolveDataHome() -> String? {
        switch AutostartPaths.dataHome(environment: environment) {
        case .success(let path): return path
        case .failure:
            emit(GnomeExtensionTexts.noDataDirectory)
            return nil
        }
    }

    /// `flock` mit `LOCK_EX`+`LOCK_NB` auf einen `O_DIRECTORY`-Deskriptor von
    /// `<dataHome>/gnome-shell` (Muster `UpdateClient.run`) — keine Sperrdatei.
    /// Ein Staging-Rest wird erst unter dieser Sperre entfernt.
    private func acquireLock(dataHome: String) -> Int32? {
        let directory = GnomeExtensionPaths.shellDirectory(dataHome: dataHome)
        if let reason = AutostartInstaller.createDirectory(directory) {
            emit(GnomeExtensionTexts.lockFailed(reason: reason))
            return nil
        }
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            emit(GnomeExtensionTexts.lockFailed(reason: AutostartInstaller.errnoName(errno)))
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            emit(code == EWOULDBLOCK
                ? GnomeExtensionTexts.anotherCommandRunning
                : GnomeExtensionTexts.lockFailed(reason: AutostartInstaller.errnoName(code)))
            return nil
        }
        return descriptor
    }

    // MARK: - Ziel prüfen

    private enum TargetState { case absent, directory }

    /// Symlink oder Nicht-Ordner am Ziel bzw. an `<ziel>/schemas` ⇒ 10, bevor
    /// irgendetwas geschrieben wird (ein `rename`/`unlink` folgte sonst dem
    /// Link aus dem Ziel hinaus).
    private func inspectTarget(_ target: String) -> Result<TargetState, TrayExit> {
        var info = stat()
        if lstat(target, &info) != 0 {
            if errno == ENOENT { return .success(.absent) }
            emit(GnomeExtensionTexts.targetBlocked(path: target))
            return .failure(.autostartBlocked)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            emit(GnomeExtensionTexts.targetBlocked(path: target))
            return .failure(.autostartBlocked)
        }
        let schemas = target + "/" + GnomeExtensionPayload.schemasDirectory
        var schemasInfo = stat()
        if lstat(schemas, &schemasInfo) == 0 {
            guard (schemasInfo.st_mode & S_IFMT) == S_IFDIR else {
                emit(GnomeExtensionTexts.schemasBlocked(path: schemas))
                return .failure(.autostartBlocked)
            }
        } else if errno != ENOENT {
            emit(GnomeExtensionTexts.schemasBlocked(path: schemas))
            return .failure(.autostartBlocked)
        }
        return .success(.directory)
    }

    /// Nur die bekannten Dateien (7 + `gschemas.compiled`) und `schemas/` —
    /// alles andere ist fremd und wird nicht gelöscht.
    private func checkNoForeignContent(_ target: String) -> TrayExit? {
        let known = Set(Self.payloadPaths + [GnomeExtensionPayload.compiledSchemaPath])
        let schemas = GnomeExtensionPayload.schemasDirectory
        func entries(_ path: String) -> [String]? {
            try? FileManager.default.contentsOfDirectory(atPath: path)
        }
        guard let top = entries(target) else {
            emit(GnomeExtensionTexts.foreignContent(path: target))
            return .autostartBlocked
        }
        var foreign = false
        for name in top {
            if name == schemas { continue }
            if !known.contains(name) || !isRegularFile(target + "/" + name) { foreign = true }
        }
        if let inner = entries(target + "/" + schemas) {
            for name in inner where !known.contains(schemas + "/" + name)
                || !isRegularFile(target + "/" + schemas + "/" + name) {
                foreign = true
            }
        }
        if foreign {
            emit(GnomeExtensionTexts.foreignContent(path: target))
            return .autostartBlocked
        }
        return nil
    }

    private func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Alle 7 Dateien bytegleich und `schemas/gschemas.compiled` vorhanden.
    private func isUpToDate(_ target: String) -> Bool {
        for file in GnomeExtensionPayload.files {
            let path = target + "/" + file.relativePath
            guard isRegularFile(path), let data = FileManager.default.contents(atPath: path),
                  [UInt8](data) == file.bytes else { return false }
        }
        return isRegularFile(target + "/" + GnomeExtensionPayload.compiledSchemaPath)
    }

    // MARK: - Staging und Austausch (FE-1 (4)–(5))

    /// Baut die Extension im Staging auf und tauscht sie ins Ziel. `nil` bei
    /// Erfolg, sonst der Exit; bei jedem Fehler ist das Staging entfernt. `command`
    /// ist der Befehl des Aufrufers, den `partlyReplaced` als Rat nennt.
    private func putInPlace(dataHome: String, target: String, existing: Bool, command: String) -> TrayExit? {
        let staging = GnomeExtensionPaths.staging(dataHome: dataHome)
        let extensions = GnomeExtensionPaths.shellDirectory(dataHome: dataHome) + "/extensions"

        if let exit = prepareStaging(staging) { return exit }
        if let exit = fill(staging: staging) {
            removeStaging(staging)
            return exit
        }

        if let reason = AutostartInstaller.createDirectory(extensions) {
            emit(GnomeExtensionTexts.stagingFailed(path: extensions, reason: reason))
            removeStaging(staging)
            return .autostartBlocked
        }
        // (a) `rename` geht nur innerhalb eines Dateisystems; `extensions/` kann
        // ein Symlink oder Mount sein.
        var stagingParent = stat()
        var extensionsInfo = stat()
        guard stat(GnomeExtensionPaths.shellDirectory(dataHome: dataHome), &stagingParent) == 0,
              stat(extensions, &extensionsInfo) == 0,
              stagingParent.st_dev == extensionsInfo.st_dev else {
            emit(GnomeExtensionTexts.differentFileSystem(path: extensions))
            removeStaging(staging)
            return .autostartBlocked
        }

        if !existing {
            // (b)
            guard rename(staging, target) == 0 else {
                emit(GnomeExtensionTexts.replaceFailed(path: target, reason: AutostartInstaller.errnoName(errno)))
                removeStaging(staging)
                return .autostartBlocked
            }
            return nil
        }

        // Fehlt `schemas/` im vorhandenen Ziel, entsteht es (`0755`); ein
        // Symlink dort wurde schon in `inspectTarget` abgelehnt.
        if let reason = AutostartInstaller.createDirectory(target + "/" + GnomeExtensionPayload.schemasDirectory) {
            emit(GnomeExtensionTexts.replaceFailed(path: target, reason: reason))
            removeStaging(staging)
            return .autostartBlocked
        }
        var replaced = 0
        for relative in Self.payloadPaths + [GnomeExtensionPayload.compiledSchemaPath] {
            if rename(staging + "/" + relative, target + "/" + relative) != 0 {
                let code = errno
                removeStaging(staging)
                if replaced == 0 {
                    emit(GnomeExtensionTexts.replaceFailed(path: target, reason: AutostartInstaller.errnoName(code)))
                } else {
                    // (c)
                    emit(GnomeExtensionTexts.partlyReplaced(command: command))
                }
                return .autostartBlocked
            }
            replaced += 1
        }
        removeStaging(staging)
        return nil
    }

    /// Ein Rest eines abgebrochenen Laufs wird entfernt (unter der Sperre);
    /// ein Symlink dort ⇒ 10.
    private func prepareStaging(_ staging: String) -> TrayExit? {
        var info = stat()
        if lstat(staging, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                emit(GnomeExtensionTexts.targetBlocked(path: staging))
                return .autostartBlocked
            case S_IFDIR:
                try? FileManager.default.removeItem(atPath: staging)
            default:
                _ = unlink(staging)
            }
        }
        if lstat(staging, &info) == 0 {
            emit(GnomeExtensionTexts.stagingFailed(path: staging, reason: "cannot remove the leftover"))
            return .autostartBlocked
        }
        return nil
    }

    private func removeStaging(_ staging: String) {
        var info = stat()
        guard lstat(staging, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            try? FileManager.default.removeItem(atPath: staging)
        } else {
            _ = unlink(staging)
        }
    }

    /// Die 7 Dateien bytegleich ins Staging, danach `glib-compile-schemas`.
    private func fill(staging: String) -> TrayExit? {
        for directory in [staging, staging + "/" + GnomeExtensionPayload.schemasDirectory] {
            if mkdir(directory, 0o755) != 0 {
                emit(GnomeExtensionTexts.stagingFailed(path: directory, reason: AutostartInstaller.errnoName(errno)))
                return .autostartBlocked
            }
        }
        for file in GnomeExtensionPayload.files {
            let path = staging + "/" + file.relativePath
            if let code = AutostartInstaller.writeBytes(file.bytes, to: path, mode: 0o644) {
                emit(GnomeExtensionTexts.stagingFailed(path: path, reason: AutostartInstaller.errnoName(code)))
                return .autostartBlocked
            }
        }
        let compile = runner.run(
            executable: "glib-compile-schemas",
            arguments: [staging + "/" + GnomeExtensionPayload.schemasDirectory]
        )
        guard compile.didRun else {
            emit(GnomeExtensionTexts.toolNotRunnable(tool: "glib-compile-schemas", reason: compile.standardError))
            return .autostartUnavailable
        }
        guard compile.exitStatus == 0 else {
            emit(GnomeExtensionTexts.compileFailed(exit: compile.exitStatus))
            return .autostartBlocked
        }
        return nil
    }
}
