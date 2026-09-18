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

    /// Der Zielpfad ist ein Symlink.
    ///
    /// Bewusst ein **anderer** Text als ``masked(unitName:)`` (Auflage 8):
    /// andere Ursache, anderer Ausweg.
    public static func symlinkAtTarget(unitPath: String) -> String {
        "The target path \(unitPath) is a symbolic link.\n"
            + "Nothing was written — following it could overwrite a file somewhere else. "
            + "Remove the link and run --install-autostart again."
    }

    // MARK: - Nicht messbare Fälle

    /// Kein Nutzermanager erreichbar.
    public static let managerUnavailable =
        "No systemd user manager is reachable (no XDG_RUNTIME_DIR / session bus).\n"
        + "Autostart was neither read nor changed. Run this from a logged-in graphical session."

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

    /// Mehr als ein Autostart-Unterbefehl auf einmal.
    public static let conflictingOptions = "Use only one of --install-autostart, --uninstall-autostart, --autostart-status.\n\(usage)"

    public static let usage = """
        Usage:
          claude-monitor-tray                      run the tray (foreground)
          claude-monitor-tray --selftest           check the session bus and exit
          claude-monitor-tray --install-autostart  set up the systemd user service
          claude-monitor-tray --uninstall-autostart  remove it again
          claude-monitor-tray --autostart-status   report whether it is set up
        """
}
