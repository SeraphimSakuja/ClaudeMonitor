import Foundation

/// Die Adressen und Kennungen, gegen die das Linux-Auto-Update arbeitet (CM-29).
///
/// ⚠️ **Zweitkopie mit Wächter.** Die Werte stehen auch im Release-Skript
/// (`scripts/release-linux.sh`, abgeleitet aus `scripts/release.sh`). Dort
/// vergleicht ein Zwillingswächter jede Zeile hier gegen die Erzeugerseite und
/// bricht bei Abweichung ab. Deshalb steht jede Konstante auf einer eigenen
/// Zeile im Format `public static let <name> = "<wert>"` — der Wächter liest
/// sie per `sed`. Umformatieren heißt: den Wächter mitziehen.
///
/// Es gibt **keine** Umgebungsvariable, die eine dieser Adressen umlenkt: Eine
/// solche Naht wäre eine Hintertür, über die ein Dritter jedem Opt-in-Rechner
/// ein anderes Binary unterschieben könnte. Tests ersetzen stattdessen die
/// Werkzeuge (`curl`, `wget`) über `PATH`.
public enum UpdateEndpoints {
    public static let manifestURL = "https://seraphimsakuja.github.io/ClaudeMonitor/linux-latest.json"
    public static let downloadURLBase = "https://github.com/SeraphimSakuja/ClaudeMonitor/releases/download"
    public static let product = "claude-monitor-tray"
    public static let platform = "linux-x86_64"
}
