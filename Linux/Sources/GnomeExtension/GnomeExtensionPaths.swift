import Foundation
import Autostart

/// Orte der GNOME-Extension (CM-43). Reine Pfadregeln, ohne Dateizugriff.
public enum GnomeExtensionPaths {

    /// `<dataHome>/gnome-shell` — Elternordner von `extensions/` und Staging.
    public static func shellDirectory(dataHome: String) -> String {
        dataHome + "/gnome-shell"
    }

    /// `<dataHome>/gnome-shell/extensions`. `dataHome` wird wiederverwendet
    /// (`AutostartPaths.dataHome`) — es gibt keine zweite XDG-Regel.
    public static func extensionsDirectory(environment: [String: String]) -> Result<String, AutostartPaths.ResolveError> {
        AutostartPaths.dataHome(environment: environment).map { shellDirectory(dataHome: $0) + "/extensions" }
    }

    /// `…/extensions/<uuid>`
    public static func target(dataHome: String) -> String {
        shellDirectory(dataHome: dataHome) + "/extensions/" + GnomeExtensionPayload.uuid
    }

    /// Staging liegt **außerhalb** von `extensions/` (die Shell legt aus jedem
    /// Unterordner dort ein Extension-Objekt an, `extensionSystem.js:717-731`),
    /// aber im selben Baum, damit `rename` geht.
    public static func staging(dataHome: String) -> String {
        shellDirectory(dataHome: dataHome) + "/.claudemonitor-extension-staging"
    }
}
