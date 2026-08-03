import AppKit
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Erzeugt das Symbol für die Menüleiste.
///
/// SwiftUI-Views in einem `MenuBarExtra`-Label werden von AppKit als
/// Schablonenbild gerendert — eine per `foregroundStyle` gesetzte Farbe ginge
/// dabei verloren. Deshalb wird das Symbol hier als `NSImage` mit
/// Palettenfarbe gebaut und `isTemplate` abgeschaltet.
///
/// Der neutrale Fall bleibt umgekehrt bewusst ein Schablonenbild: So färbt
/// AppKit ihn passend zum hellen bzw. dunklen Erscheinungsbild und zur
/// hervorgehobenen Menüleiste ein.
enum MenuBarIcon {

    /// Punktgröße des Symbols in der Menüleiste.
    static let pointSize: CGFloat = 10

    /// Symbol für eine Ampelstufe; `nil` ⇒ neutrales Symbol ohne Aussage.
    static func image(for status: StatusLevel?) -> NSImage? {
        guard let status else {
            let image = NSImage(
                systemSymbolName: "circle.dashed",
                accessibilityDescription: String(localized: "No usage data")
            )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
            image?.isTemplate = true
            return image
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [StatusAppearance.nsColor(for: status)]))
        let image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: String(localized: "Claude usage")
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}
