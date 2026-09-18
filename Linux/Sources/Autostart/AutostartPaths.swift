import Foundation

/// Wo die systemd-Nutzer-Unit liegt — abgeleitet **ausschließlich** aus einem
/// injizierten Environment.
///
/// ⚠️ **Warum kein `NSHomeDirectory()` und kein
/// `FileManager.default.homeDirectoryForCurrentUser`:** Beide fragen unter
/// Linux die Passwortdatenbank und ignorieren `$HOME`. `systemd --user` sucht
/// seine Units aber genau dort, wo `$HOME`/`$XDG_DATA_HOME` hinzeigen. Die
/// beiden Werte gehen im Container auseinander (derselbe Defekt, den
/// `TrayLog.swift:40-44` für das Redaktionspräfix beschreibt) — und eine
/// Pfadauflösung, die die echte Prozessumgebung selbst liest, ist ohne
/// Prozessstart nicht prüfbar.
///
/// Dieser Typ macht **kein** I/O: Er rechnet Zeichenketten aus. Das Anlegen,
/// Lesen und Löschen der Datei liegt im Programm-Ziel (CM-20-Schichtung).
public enum AutostartPaths {

    /// Der Name der Unit — die eine Stelle, an der er steht.
    public static let unitName = "claude-monitor-tray.service"

    /// Die Zielgruppe, in die die Unit eingehängt wird.
    ///
    /// Gemessen: `default.target` erreicht auf einer GNOME-Sitzung keine
    /// aktive Zielgruppe des Nutzermanagers, `graphical-session.target` schon.
    public static let installTargetName = "graphical-session.target"

    /// Warum sich kein Pfad bilden ließ.
    public enum ResolveError: Error, Equatable, Sendable {
        /// Weder `XDG_DATA_HOME` noch `HOME` liefern einen absoluten Pfad.
        ///
        /// Es wird dann **kein** Pfad geraten: Ein geratenes Home würde die
        /// Unit an einen Ort schreiben, an dem `systemd --user` sie nie sucht,
        /// und der Nutzer bekäme „eingerichtet" gemeldet, ohne dass etwas
        /// eingerichtet wäre.
        case noHomeDirectory
    }

    /// Alle Pfade einer Einrichtung auf einen Blick.
    public struct Layout: Equatable, Sendable {

        /// `…/systemd/user`
        public let unitDirectory: String
        /// `…/systemd/user/claude-monitor-tray.service`
        public let unitPath: String
        /// Die `.wants`-Verweise, die `systemctl --user enable` anlegt.
        ///
        /// Sie liegen im **Konfig**-Baum, nicht im Datenbaum — deshalb reicht
        /// es beim Entfernen nicht, die Unit-Datei zu löschen (Auflage 3).
        public let wantsLinkPaths: [String]
    }

    /// Der Datenbaum, in dem die Unit liegt.
    public static func dataHome(environment: [String: String]) -> Result<String, ResolveError> {
        if let explicit = absolutePath(environment["XDG_DATA_HOME"]) { return .success(explicit) }
        guard let home = absolutePath(environment["HOME"]) else { return .failure(.noHomeDirectory) }
        return .success(home + "/.local/share")
    }

    /// Der Konfigbaum, in dem `enable` seine `.wants`-Verweise anlegt.
    public static func configHome(environment: [String: String]) -> Result<String, ResolveError> {
        if let explicit = absolutePath(environment["XDG_CONFIG_HOME"]) { return .success(explicit) }
        guard let home = absolutePath(environment["HOME"]) else { return .failure(.noHomeDirectory) }
        return .success(home + "/.config")
    }

    /// Das Home-Verzeichnis, aus dem die Pfade abgeleitet werden.
    ///
    /// Auch der **Redaktionspräfix** der Ausgabe kommt hier her und nicht aus
    /// `FileManager.default.homeDirectoryForCurrentUser`: Zwei getrennt
    /// ermittelte Werte gehen im Container auseinander, und dann redigiert der
    /// Filter ein Präfix, das in den gedruckten Pfaden gar nicht vorkommt
    /// (`TrayLog.swift:40-44`).
    public static func homeDirectory(environment: [String: String]) -> String? {
        absolutePath(environment["HOME"])
    }

    /// Alle Pfade zusammen.
    public static func layout(environment: [String: String]) -> Result<Layout, ResolveError> {
        let dataHomeValue: String
        switch dataHome(environment: environment) {
        case .success(let value): dataHomeValue = value
        case .failure(let error): return .failure(error)
        }
        let configHomeValue: String
        switch configHome(environment: environment) {
        case .success(let value): configHomeValue = value
        case .failure(let error): return .failure(error)
        }

        let unitDirectory = dataHomeValue + "/systemd/user"
        let configUnitDirectory = configHomeValue + "/systemd/user"
        return .success(Layout(
            unitDirectory: unitDirectory,
            unitPath: unitDirectory + "/" + unitName,
            wantsLinkPaths: [
                configUnitDirectory + "/" + installTargetName + ".wants/" + unitName,
                // `default.target.wants` wird von dieser Karte nie angelegt.
                // Er wird trotzdem mitgeprüft: Eine ältere Einrichtung von
                // Hand kann dort liegen, und „entfernt" zu melden, während
                // noch ein Verweis auf die gelöschte Unit zeigt, wäre eine
                // Falschauskunft (Auflage 3).
                configUnitDirectory + "/default.target.wants/" + unitName
            ]
        ))
    }

    /// Ob überhaupt ein Nutzermanager erreichbar sein kann.
    ///
    /// Echte Vorbedingung ist `XDG_RUNTIME_DIR` (dort liegt der Socket des
    /// Nutzermanagers); `DBUS_SESSION_BUS_ADDRESS` allein genügt als Hinweis,
    /// ist aber nicht die Bedingung — deshalb beides, nicht nur der Bus.
    public static func managerCanBeReachable(environment: [String: String]) -> Bool {
        isUsable(environment["XDG_RUNTIME_DIR"]) || isUsable(environment["DBUS_SESSION_BUS_ADDRESS"])
    }

    // MARK: - Intern

    /// Ein Umgebungswert, der als absoluter Pfad taugt.
    ///
    /// Leer oder relativ zählt wie **ungesetzt** — so schreibt es die
    /// XDG-Basisverzeichnis-Spezifikation für `XDG_*_HOME` vor.
    static func absolutePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.hasPrefix("/") else { return nil }
        var trimmed = raw
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func isUsable(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return !raw.isEmpty
    }
}
