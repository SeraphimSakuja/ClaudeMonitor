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
    /// `<TeamID>.group.at.markusfricke.claudemonitor.shared`. Hier steht
    /// bewusst weiterhin der unpräfixierte Wert, weil die Widget-Extension auf
    /// Hold liegt und die App das Entitlement deshalb **nicht** führt: Die
    /// Entitlement-Wache meldet „nicht deklariert", der Container wird nie
    /// angefasst.
    ///
    /// Kehren die Widgets zurück, wird dieser Wert team-präfixiert — das ist
    /// Schritt 2 der Liste in `App/Signing.xcconfig`, und er muss zeichengleich
    /// mit der `.entitlements`-Datei und dem Developer-Portal sein. Ihn jetzt
    /// schon umzustellen brächte nichts und würde nur so lange falsch dastehen,
    /// bis die Gruppe tatsächlich autorisiert ist.
    public static let identifier = "group.at.markusfricke.claudemonitor.shared"

    /// Dateiname des Snapshots innerhalb des Containers.
    public static let snapshotFileName = "snapshot.json"

    /// Subsystem für alle Log-Ausgaben der App.
    public static let loggingSubsystem = "at.markusfricke.claudemonitor"
}
