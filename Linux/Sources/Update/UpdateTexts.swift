import Foundation
import Autostart

/// Alle kundensichtbaren Texte des Linux-Auto-Updates (CM-29) — **englisch,
/// unlokalisiert**, wie ``AutostartTexts`` und aus demselben Grund: Ein einzeln
/// ausgeliefertes Linux-Binary hat kein Bundle, gegen das ein
/// `.xcstrings`-Katalog auflösen könnte.
///
/// Ursachen werden mit festen Bezeichnern genannt, nie über `strerror` — dessen
/// Text hängt von der Spracheinstellung des Systems ab.
public enum UpdateTexts {

    /// Was abgerufen wird (CM-36, 2b-Mitnahme 14) — Grundlage von Nennwort und
    /// Ablehnungsgrund. Manifest und Tarball werden hieran unterschieden, nie
    /// am Text.
    public enum Download: Equatable, Sendable {
        case manifest
        case tarball

        /// Das Nennwort in den Meldungen.
        public var noun: String {
            switch self {
            case .manifest: return "update manifest"
            case .tarball: return "update"
            }
        }
    }

    // MARK: - `--update`/`--check-update`: Ergebnis

    /// Kein neueres Angebot — nur nach einem gültig gelesenen Manifest.
    public static func upToDate(version: String, buildVersion: Int) -> String {
        "claude-monitor-tray is up to date (\(version), build \(buildVersion))."
    }

    /// Ersetzt.
    public static func updated(version: String, buildVersion: Int, path: String) -> String {
        "Updated to \(version) (build \(buildVersion)): \(path)\n"
            + "The previous binary is gone; going back means downloading the old version by hand."
    }

    /// Der Tray-Dienst wurde neu gestartet.
    ///
    /// `try-restart` startet nur einen laufenden Dienst neu — der Satz sagt
    /// deshalb nicht, dass er lief.
    public static let trayRestarted = "The tray service was restarted with the new version if it was running."

    /// Kein Neustart — der Nutzer startet den Tray selbst neu.
    public static func restartTheTray(version: String) -> String {
        "Restart the tray to use \(version) — a tray that is running right now keeps the old version until then."
    }

    // MARK: - `--check-update`: Exit 14 (CM-36 · FE-7, FE-13)

    /// Neuere Fassung gefunden, das Verzeichnis des Binarys ist schreibbar —
    /// `--update` kann sie installieren. Geladen wurde nichts.
    public static func updateAvailable(version: String, buildVersion: Int, ownVersion: String, ownBuildVersion: Int) -> String {
        "Version \(version) (build \(buildVersion)) is available; this is \(ownVersion) (build \(ownBuildVersion)).\n"
            + "Nothing was downloaded. Install it with: claude-monitor-tray --update"
    }

    /// Neuere Fassung gefunden, aber dieses Binary kann sich nicht selbst
    /// ersetzen (2b-Auflage 2) — kein Installationsversprechen, nur der
    /// Handdownload.
    ///
    /// - Parameter directory: das nicht schreibbare Verzeichnis; `nil`, wenn
    ///   der eigene Pfad nicht bestimmbar war.
    public static func updateAvailableByHand(
        version: String,
        buildVersion: Int,
        ownVersion: String,
        ownBuildVersion: Int,
        directory: String?
    ) -> String {
        let why = directory.map { "The directory \($0) is not writable for you, so this binary cannot replace itself" }
            ?? "The path of this program cannot be determined, so it cannot replace itself"
        return "Version \(version) (build \(buildVersion)) is available; this is \(ownVersion) (build \(ownBuildVersion)).\n"
            + "Nothing was downloaded. \(why) — download the new version by hand "
            + "(see \"Download and verify\" in INSTALL.md)."
    }

    // MARK: - `--update`: Exit 12 (nichts gemessen)

    public static let noFetchTool =
        "Neither curl nor wget is installed, so no update could be checked. Install one of them and try again."

    public static func fetchToolNotRunnable(tool: String, reason: String) -> String {
        "Could not run \(tool) (\(reason)). No update was checked; nothing was changed."
    }

    /// Abruf gescheitert — Netz, HTTP-Fehler (auch 404), Zeitüberschreitung.
    ///
    /// Ausdrücklich NICHT „up to date": Ohne gültig gelesenes Manifest ist
    /// nichts gemessen.
    public static func fetchFailed(download: Download, tool: String, exitStatus: Int32, detail: String) -> String {
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return "Could not download the \(download.noun) (\(tool) exit \(exitStatus)\(suffix)).\n"
            + "Whether an update exists is unknown; nothing was changed."
    }

    public static func toolNotRunnable(tool: String, reason: String) -> String {
        "Could not run \(tool) (\(reason)). Nothing was changed."
    }

    public static func temporaryDirectoryFailed(reason: String) -> String {
        "Could not create a private temporary directory (\(reason)). Nothing was changed."
    }

    // MARK: - `--update`: Exit 13 (abgelehnt)

    public static func executableNotUsable(reason: String) -> String {
        "Cannot determine the path of this program (\(reason)), so it cannot be replaced. Nothing was changed."
    }

    /// FE 12: geprüft vor jedem Netzzugriff.
    public static func directoryNotWritable(directory: String) -> String {
        "The directory \(directory) is not writable for you, so this binary cannot replace itself.\n"
            + "Nothing was downloaded or changed. Install the binary in a directory you own (for example ~/.local/bin)."
    }

    public static let anotherUpdateRunning = "Another update is running right now. Nothing was changed."

    public static func lockFailed(reason: String) -> String {
        "Could not lock the binary's directory (\(reason)). Nothing was changed."
    }

    /// - Parameter limit: die Größengrenze des Abrufs (`--max-filesize`). Nur
    ///   beim Tarball kündigt etwas eine Größe an (das Manifest); beim Manifest
    ///   ist es die feste Grenze (CM-29 3b Fund 3).
    public static func refusedFetch(download: Download, tool: String, exitStatus: Int32, limit: Int) -> String {
        let reason: String
        if exitStatus == 63 {
            reason = download == .manifest ? "it is larger than \(limit) bytes" : "it is larger than announced"
        } else {
            reason = "it was redirected to a non-https address"
        }
        return "The \(download.noun) was refused (\(tool) exit \(exitStatus)): \(reason). Nothing was changed."
    }

    public static func manifestTooLarge(limit: Int) -> String {
        "The update manifest is larger than \(limit) bytes and was not read. Nothing was changed."
    }

    public static func manifestUnreadable(reason: String) -> String {
        "The update manifest could not be read (\(reason)). Nothing was changed."
    }

    /// Das Manifest wurde abgelehnt.
    public static func manifestRejected(_ rejection: UpdateManifest.Rejection) -> String {
        let reason: String
        switch rejection {
        case .notJSON:
            reason = "it is not a JSON object"
        case .formatChanged(let found):
            return "The update format changed (schemaVersion \(found)); this version cannot read it.\n"
                + "Nothing was downloaded. Download the current version by hand."
        case .missingField(let field):
            reason = "field \"\(field)\" is missing or has the wrong type"
        case .wrongProduct(let field, let value):
            reason = "\(field) is \"\(value)\", not \"\(field == "product" ? UpdateEndpoints.product : UpdateEndpoints.platform)\""
        case .invalidVersion(let value):
            reason = "version \"\(value)\" is not a plain version number"
        case .unexpectedURL(let value):
            reason = "the download address \(value) is not the one this program expects"
        case .invalidChecksum:
            reason = "sha256 is not 64 hex characters"
        case .invalidSize:
            reason = "size is not a positive number"
        case .invalidFloor(let value):
            reason = "minimum.glibc \"\(value)\" is not a plain version number"
        case .signatureMissing:
            reason = "it carries no signature"
        case .signatureInvalid:
            reason = "its signature does not match this program's key"
        }
        return "The update manifest was refused: \(reason). Nothing was downloaded or changed."
    }

    /// FE 7: vor dem Download.
    public static func belowFloor(local: String, minimum: String) -> String {
        "This machine is below the floor: glibc \(local), the new version needs glibc ≥ \(minimum).\n"
            + "Nothing was downloaded or changed."
    }

    public static let glibcUnknown =
        "The glibc version of this machine could not be determined, so the floor cannot be checked. Nothing was changed."

    public static func sizeMismatch(expected: Int, actual: Int) -> String {
        "The download has \(actual) bytes, the manifest announced \(expected). It was discarded; nothing was changed."
    }

    public static let checksumMismatch =
        "The download does not match the sha256 checksum from the manifest. It was discarded; nothing was changed."

    public static func checksumUnreadable(detail: String) -> String {
        "sha256sum gave no usable checksum (\(detail)). The download was discarded; nothing was changed."
    }

    public static func memberMissing(member: String) -> String {
        "The archive does not contain \(member) as a regular file. It was discarded; nothing was changed."
    }

    public static func stagingFailed(path: String, reason: String) -> String {
        "Could not write \(path) (\(reason)). Nothing was changed."
    }

    /// FE 8: Ladeprobe gescheitert.
    public static func probeFailed(expected: String, exitStatus: Int32, output: String) -> String {
        let seen = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "The new binary failed its load test: expected \"\(expected)\", got exit \(exitStatus)"
            + (seen.isEmpty ? "" : " and \"\(seen)\"")
            + ".\nIt was discarded; the installed binary is unchanged."
    }

    public static func replaceFailed(path: String, reason: String) -> String {
        "Could not replace \(path) (\(reason)). The installed binary is unchanged."
    }

    // MARK: - Unit-Befehle: Erfolg

    /// Wirkzeitpunkt (FE 1): Einschalten startet den Timer nicht.
    public static let takesEffectNote =
        "The first check runs 15 minutes after your next login, then once a day; nothing is started now."

    public static func installed(timerPath: String, servicePath: String) -> String {
        "Automatic updates set up: \(timerPath)\n  and \(servicePath)\n\(takesEffectNote)"
    }

    public static func alreadyEnabled(timerPath: String, servicePath: String) -> String {
        "Automatic updates were already set up; the unit files were refreshed: \(timerPath)\n  and \(servicePath)\n"
            + takesEffectNote
    }

    /// FE 10 (2b-Auflage 10): Abschalten wirkt sofort.
    public static func removed(timerPath: String, servicePath: String) -> String {
        "Automatic updates removed: \(timerPath)\n  and \(servicePath)\n"
            + "The timer was stopped; no update check runs in this session any more."
    }

    public static func nothingToRemove(timerPath: String) -> String {
        "Automatic updates were not set up — nothing to remove (\(timerPath))."
    }

    public static func statusEnabled(timerPath: String) -> String {
        "Automatic updates are enabled (\(timerPath))."
    }

    public static func statusDisabled(timerPath: String) -> String {
        "Automatic updates are not set up (\(timerPath))."
    }

    /// 2b-Auflage 9: Der letzte Lauf endete mit 12 oder 13.
    public static func lastRunFailed(exitStatus: Int, timestamp: String) -> String {
        let when = timestamp.isEmpty ? "" : " at \(timestamp)"
        let meaning = exitStatus == 12 ? "nothing could be checked" : "the update was refused"
        return "The last update run\(when) ended with exit \(exitStatus) (\(meaning)).\n"
            + "Details: journalctl --user -u \(UpdateUnits.serviceName)"
    }

    // MARK: - Unit-Befehle: blockiert

    public static func masked(unitName: String) -> String {
        "Automatic updates are masked: \(unitName) is blocked in systemd and will not run.\n"
            + "Undo it with: \(AutostartTexts.unmaskCommand(unitName: unitName))"
    }

    /// FE 12: Schreibrecht vor dem Einrichten.
    public static func directoryNotWritableForSetup(directory: String) -> String {
        "The directory \(directory) is not writable for you, so this binary could never replace itself.\n"
            + "Nothing was written. Install the binary in a directory you own (for example ~/.local/bin) and run --install-auto-update again."
    }

    public static func foreignFile(unitPath: String) -> String {
        "There is already a unit file at \(unitPath) that was not written by this program.\n"
            + "It was left untouched and nothing was written. Move it aside and run --install-auto-update again."
    }

    public static func foreignFileUnreadable(unitPath: String, reason: String) -> String {
        "There is already a file at \(unitPath), but it could not be read (\(reason)).\n"
            + "It was left untouched and nothing was written. Fix the permissions and run --install-auto-update again."
    }

    public static func symlinkAtTarget(unitPath: String) -> String {
        "The target path \(unitPath) is a symbolic link.\n"
            + "Nothing was written — following it could overwrite a file somewhere else. "
            + "Remove the link and run --install-auto-update again."
    }

    public static func foreignFileNotRemoved(unitPath: String) -> String {
        "The unit file at \(unitPath) was not written by this program.\n"
            + "It was left untouched and automatic updates were not removed. Remove or disable it by hand."
    }

    public static func unreadableFileNotRemoved(unitPath: String, reason: String) -> String {
        "There is a file at \(unitPath), but it could not be read (\(reason)).\n"
            + "It was left untouched and automatic updates were not removed. "
            + "Fix the permissions and run --uninstall-auto-update again."
    }

    public static func symlinkNotRemoved(unitPath: String) -> String {
        "The target path \(unitPath) is a symbolic link, which this program never creates.\n"
            + "It was left untouched and automatic updates were not removed. Remove the link by hand."
    }

    public static func shadowedNotInstalled(fragmentPath: String, unitName: String, unitPath: String) -> String {
        "systemd uses \(fragmentPath) for \(unitName), not \(unitPath).\n"
            + "Nothing was written or enabled — enabling would switch on that other unit. "
            + "Move \(fragmentPath) aside and run --install-auto-update again."
    }

    public static func shadowedNotRemoved(fragmentPath: String, unitName: String, unitPath: String) -> String {
        "systemd uses \(fragmentPath) for \(unitName), not \(unitPath).\n"
            + "Nothing was disabled or removed. "
            + "Move \(fragmentPath) aside and run --uninstall-auto-update again."
    }

    public static func foreignWantsLinkNotRemoved(linkPath: String, unitPath: String) -> String {
        "The link \(linkPath) points at a unit file other than \(unitPath).\n"
            + "Nothing was removed and the mask stays as it is. "
            + "Remove that link by hand if it is not needed, then run --uninstall-auto-update again."
    }

    public static func effectiveUnitUndetermined(unitName: String, reason: String) -> String {
        "Could not determine which unit file systemd uses for \(unitName) (\(reason)).\nNothing was changed."
    }

    public static let managerUnavailable =
        "No systemd user manager is reachable (no XDG_RUNTIME_DIR / session bus).\n"
        + "Automatic updates were neither read nor changed. Run this from a logged-in session."

    public static func systemctlUnavailable(reason: String) -> String {
        "Could not run systemctl (\(reason)).\nAutomatic updates were neither read nor changed."
    }

    public static func unexpectedState(unitName: String, word: String) -> String {
        "systemctl reports an unexpected state for \(unitName): \"\(word)\".\n"
            + "Nothing was changed. Check it with: systemctl --user status \(unitName)"
    }

    public static func unreadableState(unitName: String, word: String) -> String {
        word.isEmpty
            ? "systemctl gave no readable answer for \(unitName). Nothing was changed."
            : "systemctl gave an unknown answer for \(unitName): \"\(word)\". Nothing was changed."
    }

    public static func writeFailed(path: String, reason: String) -> String {
        "Cannot write \(path) (\(reason)). Automatic updates were not set up."
    }

    public static func enableDidNotTake(unitName: String) -> String {
        "systemctl accepted the request, but \(unitName) still does not report as enabled. "
            + "Automatic updates are not set up."
    }

    public static func staleWantsLink(path: String) -> String {
        "A leftover link still points at the removed unit: \(path)\n"
            + "Automatic updates are NOT fully removed. Delete that link by hand."
    }
}
