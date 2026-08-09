import SwiftUI
import AppKit
import ClaudeMonitorShared

/// Reine Menüleisten-App: kein Dock-Symbol, kein Hauptfenster (`LSUIElement`).
@main
struct ClaudeMonitorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // `@ObservedObject` und nicht `@StateObject`: Der Monitor ist ein
    // Singleton, dessen Lebenszyklus am `NSApplicationDelegate` hängt. Die
    // Szene erzeugt und besitzt ihn nicht — `@StateObject` würde genau das
    // behaupten.
    @ObservedObject private var monitor = UsageMonitor.shared
    // Aus demselben Grund `@ObservedObject`: Der Update-Controller ist der
    // schwach gehaltene Delegat des Sparkle-Updaters und muss so lange leben
    // wie der Prozess. Die Szene besitzt ihn nicht.
    @ObservedObject private var updates = UpdateController.shared

    /// Der gewählte Anzeigemodus — bewusst **hier** in der Szene und nicht in
    /// `MenuBarLabelView`.
    ///
    /// Lag er in der Label-View, schrieb der Umschalter zwar korrekt nach
    /// `UserDefaults`, aber die Menüleiste zeichnete sich nicht neu: Ein
    /// `MenuBarExtra`-Label wertet seinen Rumpf bei einer reinen
    /// `UserDefaults`-Änderung nicht neu aus. Als Eigenschaft der Szene ist der
    /// Modus dagegen Teil ihres Abhängigkeitsgraphen — eine Änderung baut das
    /// Label zwingend neu. Am 30-s-Poller hängt er weiterhin nicht.
    ///
    /// Als `String` und nicht `RawRepresentable`, damit die Rückfallregel in
    /// ``MenuBarMode/init(storedValue:)`` auf dem Produktionspfad liegt statt
    /// von SwiftUIs eigener Umwandlung ersetzt zu werden. Dies ist die einzige
    /// Stelle, die sie aufruft.
    @AppStorage("menuBarMode") private var rawMode: String = MenuBarMode.activeAccount.rawValue

    var body: some Scene {
        MenuBarExtra {
            MonitorPopoverView()
                .environmentObject(monitor)
                .environmentObject(updates)
        } label: {
            // Die Leiste bekommt Zustand und Modus, nicht die fertige Anzeige —
            // die Anzeigeregeln liegen geprüft in `Shared/`.
            MenuBarLabelView(state: monitor.state, mode: MenuBarMode(storedValue: rawMode))
        }
        // `.window` statt Menü: Fortschrittsbalken und live laufende Restzeiten
        // lassen sich in einem klassischen Menü nicht darstellen.
        .menuBarExtraStyle(.window)
    }
}

/// Hält den Lebenszyklus des Pollers.
///
/// Eine App ohne Fenster hat keinen View, an dessen Erscheinen man den Start
/// hängen könnte — und gepollt wird ausdrücklich auch bei geschlossenem Menü,
/// weil die Leiste ihre Zahlen dauerhaft zeigt.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        UsageMonitor.shared.start()
        // Hier und nicht in einer View: Der Updater muss auch dann laufen,
        // wenn das Detailfenster nie geöffnet wird — sonst fände keine
        // geplante Prüfung statt.
        UpdateController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageMonitor.shared.stop()
        // Räumt eine noch offene Update-Sitzung ab, damit die App nicht mit
        // Dock-Symbol und Abzeichen aus dem Leben scheidet.
        UpdateController.shared.applicationWillTerminate()
    }
}
