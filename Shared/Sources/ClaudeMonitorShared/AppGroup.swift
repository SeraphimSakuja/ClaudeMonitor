import Foundation

/// Feste Kennungen der App — an einer Stelle, weil die Widget-Extension aus
/// Teilaufgabe 3 exakt dieselben Werte benutzen muss.
public enum AppGroup {

    /// App-Group-Container, über den Menüleisten-App und Widget Daten teilen.
    ///
    /// Der Container ist die einzige Brücke über die Sandbox: Die Extension darf
    /// weder fremde Prozesse starten noch beliebige Home-Pfade lesen.
    ///
    /// ⚠️ **Auf macOS muss diese Kennung mit der Team-ID beginnen** —
    /// `<TeamID>.group.at.markusfricke.claudemonitor.shared`. Solange die
    /// Team-ID offen ist (SSOT-Punkt CM-01), steht hier der unpräfixierte
    /// Platzhalter; die Entitlement-Wache lässt den Container dann ohnehin
    /// nicht zu. Sobald die Team-ID feststeht, ist dieser Wert Schritt 3 der
    /// Checkliste in `App/Signing.xcconfig` und muss zeichengleich mit der
    /// `.entitlements`-Datei und dem Developer-Portal sein.
    public static let identifier = "group.at.markusfricke.claudemonitor.shared"

    /// Dateiname des Snapshots innerhalb des Containers.
    public static let snapshotFileName = "snapshot.json"

    /// Subsystem für alle Log-Ausgaben der App.
    public static let loggingSubsystem = "at.markusfricke.claudemonitor"
}
