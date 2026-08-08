import Foundation

/// Formatiert Auslastungen für die Anzeige.
public enum PercentFormatting {

    /// Kompakte Darstellung für die Menüleiste und die Fensterzeilen.
    ///
    /// Gibt `nil` zurück, wenn der Wert nicht darstellbar ist. Ein
    /// nicht-endlicher Wert darf **nie** in `Int(...)` laufen — das trappt zur
    /// Laufzeit. Deshalb hier die Endlichkeitsprüfung vor jeder Umwandlung.
    ///
    /// Es wird kaufmännisch gerundet und ohne Nachkommastellen angezeigt: In der
    /// Menüleiste zählt jeder Punkt Breite, und 42,4 % vs. 42 % ändert keine
    /// Entscheidung.
    public static func compact(_ percent: Double) -> String? {
        bare(percent).map { $0 + "%" }
    }

    /// Dieselbe Zahl **ohne** Prozentzeichen — für die Menüleiste, wo je
    /// Account zwei Werte als `74/28` stehen.
    ///
    /// Das Zeichen entfällt dort bewusst: Es käme sechsmal vor und kostete
    /// Breite, ohne etwas zu unterscheiden — dass es Prozente sind, sagt das
    /// Detailfenster. Ausdrücklich **dieselbe** Rundung und dieselbe
    /// Obergrenze wie ``compact(_:)``, damit die Leiste nie eine andere Zahl
    /// zeigt als das Fenster.
    public static func bare(_ percent: Double) -> String? {
        guard percent.isFinite else { return nil }
        // Obergrenze, damit ein korrupter Riesenwert die Menüleiste nicht sprengt.
        let clamped = min(max(percent, 0), 999)
        return "\(Int(clamped.rounded()))"
    }

    /// Anteil für Fortschrittsanzeigen, geklemmt auf 0…1.
    /// `nil`, wenn kein darstellbarer Wert vorliegt.
    public static func fraction(_ percent: Double) -> Double? {
        guard percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}
