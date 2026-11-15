import Foundation

/// Alle kundensichtbaren Texte der GNOME-Extension-Befehle (CM-43) —
/// **englisch, unlokalisiert**, wie ``AutostartTexts`` und ``UpdateTexts``.
/// Die Meldungen nennen nur die eigene UUID und Pfade, nie fremde Einträge der
/// Listen.
public enum GnomeExtensionTexts {

    // MARK: - Optionsnamen (eine Quelle für Vordertür und `UpdateClient`)

    public static let install = "--install-gnome-extension"
    public static let uninstall = "--uninstall-gnome-extension"
    public static let refresh = "--refresh-gnome-extension"

    // MARK: - Vorbedingungen

    public static let noDataDirectory = "Cannot work out where your data directory is: neither XDG_DATA_HOME "
        + "nor HOME is an absolute path. Nothing was changed."

    public static func toolNotRunnable(tool: String, reason: String) -> String {
        "Cannot run \(tool): \(reason)\nNothing was changed."
    }

    public static let notGnomeSession = "This is not a GNOME session: gsettings has no org.gnome.shell schema. "
        + "Nothing was changed."

    public static func settingUnreadable(key: String) -> String {
        "Cannot read the GNOME setting \(key). Nothing was changed."
    }

    public static func targetBlocked(path: String) -> String {
        "\(path) is a symbolic link or not a directory. Nothing was changed."
    }

    public static func schemasBlocked(path: String) -> String {
        "\(path) is a symbolic link or not a directory. Nothing was changed."
    }

    public static func foreignContent(path: String) -> String {
        "\(path) holds files that are not part of this extension. Nothing was changed."
    }

    public static let anotherCommandRunning = "another GNOME extension command is running. Nothing was changed."

    public static func lockFailed(reason: String) -> String {
        "Cannot lock the GNOME extension directory (\(reason)). Nothing was changed."
    }

    // MARK: - Einrichten

    public static func stagingFailed(path: String, reason: String) -> String {
        "Cannot prepare the extension files in \(path): \(reason). Nothing was changed."
    }

    public static func compileFailed(exit: Int32) -> String {
        "glib-compile-schemas failed (exit \(exit)). Nothing was changed."
    }

    public static func differentFileSystem(path: String) -> String {
        "\(path) lies on a different file system than the staging folder. Nothing was changed."
    }

    public static func replaceFailed(path: String, reason: String) -> String {
        "Cannot put the extension in place at \(path): \(reason). Nothing was changed."
    }

    public static let partlyReplaced = "The GNOME extension was partly replaced — run "
        + "claude-monitor-tray \(install) again."

    public static let settingDidNotStick = "The extension files are in place, but the setting did not stick "
        + "— no session bus? Switch it on with the Extensions app or run the command again in a desktop session."

    public static func installed(path: String, shellVersion: String) -> String {
        "GNOME extension installed and switched on for GNOME Shell \(shellVersion): \(path)\n"
            + "Log out and back in once to load it."
    }

    public static func updated(path: String, shellVersion: String) -> String {
        "GNOME extension updated and switched on for GNOME Shell \(shellVersion): \(path)\n"
            + "It takes full effect at your next log-in."
    }

    public static let refreshed = "GNOME extension brought up to date — takes full effect at your next log-in."

    // MARK: - Entfernen

    public static func removeFailed(path: String, reason: String) -> String {
        "Cannot remove \(path): \(reason). The GNOME extension is partly removed."
    }

    public static func removed(path: String) -> String {
        "GNOME extension removed: \(path)"
    }

    public static let notInstalled = "The GNOME extension is not installed."
    public static let switchedOffNothingInstalled = "GNOME extension switched off — nothing was installed."

    // MARK: - Warnungen

    public static let userExtensionsDisabled = "Warning: GNOME has user extensions switched off "
        + "(disable-user-extensions), so this one stays off.\n"
        + "Run: gsettings set org.gnome.shell disable-user-extensions false (or use the main switch of the Extensions app)."

    public static let installationNotAllowed = "Warning: GNOME has allow-extension-installation off, so the shell "
        + "does not look for user extensions at all.\n"
        + "Run: gsettings set org.gnome.shell allow-extension-installation true"
}
