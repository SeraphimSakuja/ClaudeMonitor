import Foundation

/// Alle kundensichtbaren Texte der Autostart-Unterbefehle — **englisch,
/// unlokalisiert**, wie ``TrayTexts`` im Nachbarziel und aus demselben Grund:
/// Ein einzeln ausgeliefertes Linux-Binary hat kein Bundle, gegen das ein
/// `.xcstrings`-Katalog auflösen könnte.
///
/// Sie stehen im Bibliotheks-Ziel und nicht im Programm (Auflage 11): Texte
/// sind eine Regel, und Regeln sind in diesem Projekt ohne Prozessstart
/// prüfbar. Inline-Strings in `AutostartInstaller.swift` bräuchen die
/// CM-20-Schichtung.
public enum AutostartTexts {

    /// Der Befehl, mit dem der Nutzer eine Maske wieder aufhebt.
    ///
    /// ⚠️ **Kein Verweis auf „Systemeinstellungen"** (Auflage 12): Das ist
    /// macOS-Sprache aus `LoginItemState.needsSystemSettings`. Unter Linux
    /// gibt es keine Oberfläche dafür — der einzige Weg ist dieser Befehl.
    public static func unmaskCommand(unitName: String) -> String {
        "systemctl --user unmask \(unitName)"
    }

    // MARK: - Erfolgsfälle

    /// Eingerichtet.
    ///
    /// Sagt ausdrücklich, ab **wann** es wirkt: `install` startet den Dienst
    /// nicht (Fachentscheid, siehe ``AutostartTexts/takesEffectNote``).
    public static func installed(unitPath: String) -> String {
        "Autostart set up: \(unitPath)\n\(takesEffectNote)"
    }

    /// War schon eingerichtet; die Unit wurde aufgefrischt.
    public static func alreadyEnabled(unitPath: String) -> String {
        "Autostart was already set up; the unit file was refreshed: \(unitPath)\n\(takesEffectNote)"
    }

    /// Entfernt.
    public static func removed(unitPath: String) -> String {
        "Autostart removed: \(unitPath)\nA tray process that is running right now keeps running until you log out."
    }

    /// Beim Entfernen: Die Maske bleibt stehen.
    ///
    /// Fachentscheid (Auflage 3): Eine Maske ist eine Entscheidung des Nutzers
    /// über systemd, nicht über diese App — das Entfernen des Autostarts hebt
    /// sie nicht auf. Es wird deshalb auch kein `disable` versucht: Bei einer
    /// maskierten Unit meldet es rc=0 („is masked, ignoring") und lässt den
    /// `.wants`-Verweis stehen.
    public static func maskKept(unitName: String) -> String {
        "\(unitName) is masked; the mask stays as it is — it is your systemd setting, not this program's.\n"
            + "Undo it yourself with: \(unmaskCommand(unitName: unitName))"
    }

    /// Es war nichts eingerichtet.
    public static func nothingToRemove(unitPath: String) -> String {
        "Autostart was not set up — nothing to remove (\(unitPath))."
    }

    /// Die gemeinsame Wahrheit über den Wirkzeitpunkt.
    ///
    /// Fachentscheid (Auflage 16): Weder `--install-autostart` startet den
    /// Dienst, noch beendet `--uninstall-autostart` einen laufenden. Ein
    /// laufender Prozess behält den Pfad, mit dem er gestartet wurde.
    public static let takesEffectNote = "It takes effect at your next login; the service is not started now."

    // MARK: - Zustandsauskunft (`--autostart-status`)

    public static func statusEnabled(unitPath: String) -> String {
        "Autostart is enabled (\(unitPath))."
    }

    /// CM-34: der Pfad, den die Unit beim Login startet.
    public static func statusExecutable(path: String) -> String {
        "It starts \(path)."
    }

    public static func statusExecutableDiffers(running: String) -> String {
        "That is not the binary you ran (\(running)) — run --install-autostart with the binary that should start, or untick and tick \"Start at login\" in its tray."
    }

    public static func statusExecutableMissing(path: String) -> String {
        "It starts \(path), which does not exist or is not executable — systemd fails at every login (203/EXEC). Run --install-autostart with the binary that should start."
    }

    public static func statusDisabled(unitPath: String) -> String {
        "Autostart is not set up (\(unitPath))."
    }

    // MARK: - Blockierte Fälle

    /// Die Unit ist maskiert — `enable` bliebe wirkungslos.
    public static func masked(unitName: String) -> String {
        "Autostart is masked: \(unitName) is blocked in systemd and will not start.\n"
            + "Undo it with: \(unmaskCommand(unitName: unitName))"
    }

    /// Am Zielpfad liegt eine fremde Datei.
    public static func foreignFile(unitPath: String) -> String {
        "There is already a unit file at \(unitPath) that was not written by this program.\n"
            + "It was left untouched. Move it aside and run --install-autostart again."
    }

    /// Am Zielpfad liegt eine Datei, die sich nicht lesen ließ.
    ///
    /// Bewusst ein anderer Text als ``foreignFile(unitPath:)``: Ob die Datei
    /// von dieser Einrichtung stammt, ist unbekannt, nicht widerlegt — die
    /// Ursache ist der Lesefehler, nicht ein fehlender Marker.
    public static func foreignFileUnreadable(unitPath: String, reason: String) -> String {
        "There is already a file at \(unitPath), but it could not be read (\(reason)).\n"
            + "It was left untouched. Fix the permissions and run --install-autostart again."
    }

    /// Der Zielpfad ist ein Symlink.
    ///
    /// Bewusst ein **anderer** Text als ``masked(unitName:)`` (Auflage 8):
    /// andere Ursache, anderer Ausweg.
    public static func symlinkAtTarget(unitPath: String) -> String {
        "The target path \(unitPath) is a symbolic link.\n"
            + "Nothing was written — following it could overwrite a file somewhere else. "
            + "Remove the link and run --install-autostart again."
    }

    // MARK: - Blockiertes Entfernen (CM-30, 2b-Auflage 3)

    /// Am Zielpfad liegt eine fremde Datei — sie wird nicht entfernt.
    public static func foreignFileNotRemoved(unitPath: String) -> String {
        "The unit file at \(unitPath) was not written by this program.\n"
            + "It was left untouched and autostart was not removed. Remove or disable it by hand."
    }

    /// Am Zielpfad liegt eine unlesbare Datei — sie wird nicht entfernt.
    public static func unreadableFileNotRemoved(unitPath: String, reason: String) -> String {
        "There is a file at \(unitPath), but it could not be read (\(reason)).\n"
            + "It was left untouched and autostart was not removed. Fix the permissions and run --uninstall-autostart again."
    }

    /// Der Zielpfad ist ein Symlink — er wird nicht entfernt.
    public static func symlinkNotRemoved(unitPath: String) -> String {
        "The target path \(unitPath) is a symbolic link, which this program never creates.\n"
            + "It was left untouched and autostart was not removed. Remove the link by hand."
    }

    // MARK: - Andere wirksame Unit (CM-32)

    /// Einrichten: systemd lädt für den Namen eine andere Datei.
    ///
    /// Neutral formuliert — die andere Datei kann auch in einem Verzeichnis
    /// liegen, das systemd **nach** dem Zielverzeichnis durchsucht.
    public static func shadowedNotInstalled(fragmentPath: String, unitPath: String) -> String {
        "systemd uses \(fragmentPath) for \(AutostartPaths.unitName), not \(unitPath).\n"
            + "Nothing was written or enabled — enabling would switch on that other unit. "
            + "Move \(fragmentPath) aside and run --install-autostart again."
    }

    /// Entfernen: systemd lädt für den Namen eine andere Datei.
    ///
    /// Zwei getrennte Auswege: `disable` stoppt die andere Unit, lässt aber
    /// die eigene Datei liegen — ein zweites `--uninstall-autostart` endete
    /// wieder hier. Erst das Beiseitelegen der anderen Datei lässt es durch.
    public static func shadowedNotRemoved(fragmentPath: String, unitPath: String) -> String {
        "systemd uses \(fragmentPath) for \(AutostartPaths.unitName), not \(unitPath).\n"
            + "Nothing was disabled or removed.\n"
            + "To stop that unit from starting at login, run: systemctl --user disable \(AutostartPaths.unitName)\n"
            + "Or move \(fragmentPath) aside and run --uninstall-autostart again; then this program's own unit file is removed."
    }

    /// Entfernen bei Maske: Ein `.wants`-Verweis zeigt auf eine andere Datei.
    public static func foreignWantsLinkNotRemoved(linkPath: String, unitPath: String) -> String {
        "The link \(linkPath) points at a unit file other than \(unitPath).\n"
            + "Nothing was removed and the mask stays as it is. "
            + "Remove that link by hand if it is not needed, then run --uninstall-autostart again."
    }

    /// Welche Datei systemd lädt, ließ sich nicht bestimmen.
    public static func effectiveUnitUndetermined(reason: String) -> String {
        "Could not determine which unit file systemd uses for \(AutostartPaths.unitName) (\(reason)).\n"
            + "Nothing was changed."
    }

    /// `show` lieferte keinen absoluten Pfad.
    public static func effectiveUnitUnusableValue(_ value: String) -> String {
        effectiveUnitUndetermined(reason: "unexpected FragmentPath value \"\(value)\"")
    }

    // MARK: - Nicht messbare Fälle

    /// Kein Nutzermanager erreichbar.
    public static let managerUnavailable =
        "No systemd user manager is reachable (no XDG_RUNTIME_DIR / session bus).\n"
        + "Autostart was neither read nor changed. Run this from a logged-in graphical session."

    /// `systemctl` wurde gar nicht erst gestartet (Spawn/Pipe gescheitert).
    ///
    /// Bewusst ein anderer Text als ``managerUnavailable`` (Auflage 1): Der
    /// Grund liegt beim Aufruf selbst, nicht bei `XDG_RUNTIME_DIR`/dem
    /// Sitzungsbus — die beiden können in Wahrheit gesetzt sein.
    public static func systemctlUnavailable(reason: String) -> String {
        "Could not run systemctl (\(reason)).\n"
            + "Autostart was neither read nor changed."
    }

    /// Kein Home-Verzeichnis ableitbar.
    public static let noHomeDirectory =
        "Neither XDG_DATA_HOME nor HOME holds an absolute path, so the unit directory is unknown.\n"
        + "Nothing was written — guessing a path would put the unit where systemd never looks."

    /// `systemctl` meldet ein bekanntes, aber hier bedeutungsloses Wort.
    public static func unexpectedState(word: String) -> String {
        "systemctl reports an unexpected state for \(AutostartPaths.unitName): \"\(word)\".\n"
            + "Nothing was changed. Check it with: systemctl --user status \(AutostartPaths.unitName)"
    }

    /// `systemctl` antwortete mit etwas Unbekanntem.
    public static func unreadableState(word: String) -> String {
        word.isEmpty
            ? "systemctl gave no readable answer for \(AutostartPaths.unitName). Nothing was changed."
            : "systemctl gave an unknown answer for \(AutostartPaths.unitName): \"\(word)\". Nothing was changed."
    }

    /// Das eigene Binary taugt nicht als `ExecStart`.
    public static func executableNotUsable(reason: String) -> String {
        "Cannot determine a usable path to this program (\(reason)).\n"
            + "Nothing was written — a unit with a wrong ExecStart would only fail at your next login."
    }

    /// Das Zielverzeichnis ließ sich nicht anlegen.
    public static func directoryNotCreated(path: String, reason: String) -> String {
        "Cannot create \(path) (\(reason)). Nothing was written."
    }

    /// Die Unit ließ sich nicht schreiben.
    public static func writeFailed(path: String, reason: String) -> String {
        "Cannot write \(path) (\(reason)). Autostart was not set up."
    }

    /// `enable` lief durch, aber der Zustand danach sagt etwas anderes.
    ///
    /// Gemeldet wird **immer** der neu erfragte Zustand, nie der Rückgabecode
    /// von `enable` — dasselbe Vorgehen wie im macOS-Vorbild
    /// (`LoginItemController.swift:47-58`).
    public static func enableDidNotTake(unitName: String) -> String {
        "systemctl accepted the request, but \(unitName) still does not report as enabled. "
            + "Autostart is not set up."
    }

    /// Ein `.wants`-Verweis zeigt noch auf die gelöschte Unit.
    public static func staleWantsLink(path: String) -> String {
        "A leftover link still points at the removed unit: \(path)\n"
            + "Autostart is NOT fully removed. Delete that link by hand."
    }

    // MARK: - Warnungen

    /// `graphical-session.target` ist nicht aktiv.
    ///
    /// Fachentscheid (Auflage 15b): Das ist **kein** Abbruchgrund — die Unit
    /// wird geschrieben und eingeschaltet. Aber „eingerichtet" allein zu
    /// melden wäre unvollständig, wenn die Zielgruppe auf diesem System nie
    /// aktiv wird (etwa unter einer Sitzung, die sie nicht startet).
    public static func graphicalSessionInactive(word: String) -> String {
        "Warning: \(AutostartPaths.installTargetName) is not active right now (\"\(word)\").\n"
            + "The unit was set up anyway, but it will only start once that target becomes active."
    }

    // MARK: - Aufruf

    /// Ein unbekanntes `--`-Argument.
    ///
    /// Auflage 13: Ohne diese Meldung startete ein Tippfehler den residenten
    /// Tray, während der Nutzer glaubt, er habe eingerichtet.
    public static func unknownOption(_ argument: String) -> String {
        "Unknown option: \(argument)\n\(usage)"
    }

    /// Mehr als ein Unterbefehl auf einmal.
    public static let conflictingOptions = "Use only one of --install-autostart, --uninstall-autostart, --autostart-status, "
        + "--version, --update, --check-update, --install-auto-update, --uninstall-auto-update, --auto-update-status.\n\(usage)"

    public static let usage = """
        Usage:
          claude-monitor-tray                          run the tray (foreground)
          claude-monitor-tray --selftest               check the session bus and exit
          claude-monitor-tray --install-autostart      set up the systemd user service
          claude-monitor-tray --uninstall-autostart    remove it again
          claude-monitor-tray --autostart-status       report whether it is set up
          claude-monitor-tray --version                print the version and exit
          claude-monitor-tray --update                 check for an update and install it now
          claude-monitor-tray --check-update           check for an update, install nothing
          claude-monitor-tray --install-auto-update    install updates by itself once a day (systemd timer)
          claude-monitor-tray --uninstall-auto-update  turn that off again
          claude-monitor-tray --auto-update-status     report whether it is set up
        """
}
