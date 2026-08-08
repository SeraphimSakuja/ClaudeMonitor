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

    var body: some Scene {
        MenuBarExtra {
            MonitorPopoverView()
                .environmentObject(monitor)
        } label: {
            // Die Leiste bekommt den Zustand, nicht die fertige Anzeige: Der
            // gewählte Modus liegt in `MenuBarLabelView` und darf nicht über
            // den 30-s-Poller laufen.
            MenuBarLabelView(state: monitor.state)
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
/// weil derselbe Snapshot die Widgets versorgt.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        UsageMonitor.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageMonitor.shared.stop()
    }
}
