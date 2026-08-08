import AppKit
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Das **neutrale** Symbol für die Menüleiste: der Zustand „nichts zu sagen".
///
/// Alles mit Aussage — Ampelpunkte und Zahlen — zeichnet
/// ``MenuBarImageRenderer`` selbst in ein einziges `NSImage`. Übrig bleibt hier
/// genau der Fall ohne jede Aussage, und der ist bewusst ein
/// **Schablonenbild** (`isTemplate = true`): So färbt AppKit ihn passend zum
/// hellen bzw. dunklen Erscheinungsbild und zur hervorgehobenen Menüleiste ein.
///
/// Ein SwiftUI-`Image` täte es dafür nicht: Views in einem `MenuBarExtra`-Label
/// werden von AppKit ohnehin als Schablonenbild gerendert, eine per
/// `foregroundStyle` gesetzte Farbe ginge dabei verloren. Genau deshalb liegt
/// das Symbol hier als `NSImage` vor — und genau deshalb kann der farbige Fall
/// nicht über diesen Weg laufen, sondern nur über den Zeichner mit
/// `isTemplate = false`.
enum MenuBarIcon {

    /// Punktgröße des Symbols in der Menüleiste.
    static let pointSize: CGFloat = 10

    /// Das neutrale Symbol ohne Aussage.
    static var neutralImage: NSImage? {
        let image = NSImage(
            systemSymbolName: "circle.dashed",
            accessibilityDescription: String(localized: "No usage data")
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        image?.isTemplate = true
        return image
    }
}
