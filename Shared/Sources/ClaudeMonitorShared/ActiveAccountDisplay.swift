import Foundation
import ClaudeMonitorCore

/// Wie der in claude-swap **aktive** Account ausgezeichnet wird.
///
/// Eine einzige Stelle für beide Anzeigen — Menüleiste und Account-Karte —,
/// damit dieselbe Markierung an beiden Orten steht und die Widget-Extension
/// später dieselbe benutzt.
///
/// **Keine Farbe:** Farbe ist in dieser App fest für die Ampel reserviert. Ein
/// eingefärbter Name stünde in unmittelbarer Nachbarschaft zum Ampelpunkt und
/// wäre nicht mehr davon zu unterscheiden — deshalb ein Zeichen und (in der
/// Leiste) Fettschrift.
public enum ActiveAccountDisplay {

    /// Das vorangestellte Zeichen: `▸●96/30`.
    ///
    /// Ein schmales, gerichtetes Zeichen — es kostet in der Menüleiste kaum
    /// Breite und zeigt zugleich auf den Account, zu dem es gehört.
    public static let marker = "▸"

    /// Markierung, falls dieser Account der aktive ist; sonst `nil`.
    public static func marker(isActive: Bool) -> String? {
        isActive ? marker : nil
    }
}
