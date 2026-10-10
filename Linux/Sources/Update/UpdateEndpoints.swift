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
/// Es gibt **keine** Umgebungsvariable und kein Argument, das eine dieser
/// Adressen oder den Schlüssel umlenkt: Eine solche Naht wäre eine Hintertür,
/// über die ein Dritter jedem Rechner ein anderes Binary unterschieben könnte
/// (CM-36 · FE-5). Tests ersetzen stattdessen die Werkzeuge (`curl`, `wget`)
/// über `PATH` bzw. den Runner, den Schlüssel und den Binary-Pfad über den
/// Initialisierer von `UpdateClient` — `main.swift` setzt beides nie.
public enum UpdateEndpoints {
    public static let manifestURL = "https://seraphimsakuja.github.io/ClaudeMonitor/linux-latest.json"
    public static let downloadURLBase = "https://github.com/SeraphimSakuja/ClaudeMonitor/releases/download"
    public static let product = "claude-monitor-tray"
    public static let platform = "linux-x86_64"
    /// CM-36 · FE-4: Ed25519-Public-Key (Base64, 32 Byte), gegen den das
    /// Manifest geprüft wird — derselbe Schlüssel wie der Sparkle-Feed der
    /// macOS-Linie (`SPARKLE_PUBLIC_KEY` in `scripts/release.sh`,
    /// `SUPublicEDKey` in `App/Info.plist`). Ab der ersten Auslieferung in jedem
    /// Client eingefroren.
    public static let manifestPublicKey = "xe1+/8jYc45qORKi4EzxgBfxsOk0K5NWRS79mjuJQj0="
}
