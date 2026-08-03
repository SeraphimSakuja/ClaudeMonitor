import SwiftUI
import AppKit
import ClaudeMonitorCore
import ClaudeMonitorShared

/// Farbzuordnung der Ampel — einmal für SwiftUI, einmal für AppKit
/// (die Menüleiste zeichnet über `NSImage`).
///
/// Es werden ausschließlich Systemfarben benutzt: Sie sind in hellem und
/// dunklem Erscheinungsbild abgestimmt und folgen den Kontrasteinstellungen des
/// Systems. Eigene Hex-Werte wären in einem der beiden Modi immer schlechter.
enum StatusAppearance {

    /// AppKit-Farbe einer Ampelstufe.
    ///
    /// „Gelb" wird als `systemOrange` gezeichnet: Ein gelber Punkt auf hellem
    /// Grund ist praktisch unsichtbar. Die Stufe heißt weiterhin `yellow`, nur
    /// ihre Darstellung ist lesbar gewählt.
    static func nsColor(for status: StatusLevel) -> NSColor {
        switch status {
        case .green: return .systemGreen
        case .yellow: return .systemOrange
        case .red: return .systemRed
        }
    }

    /// SwiftUI-Farbe einer Ampelstufe.
    static func color(for status: StatusLevel) -> Color {
        Color(nsColor: nsColor(for: status))
    }

    /// Farbe für einen unbekannten Zustand — bewusst neutral, nie grün.
    static let neutral = Color.secondary
}
