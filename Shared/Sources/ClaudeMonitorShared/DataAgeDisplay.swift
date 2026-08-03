import Foundation

/// Aufbereitung des Datenalters für die Anzeige.
///
/// Die SSOT verlangt „veraltete Daten **mit Altersangabe**". Der Zustand
/// ``AccountStatusLine/stale(age:)`` trägt das Alter bereits — hier wird es in
/// eine `Duration` überführt, die die View mit `.units(...)` lokalisiert
/// ausgeben kann. Das Formatieren selbst bleibt bewusst bei SwiftUI: Nur so
/// stimmen Sprache und Maßeinheiten mit dem System überein.
public enum DataAgeDisplay {

    /// Datenalter als anzeigbare Dauer.
    ///
    /// - Returns: `nil`, wenn das Alter nicht darstellbar ist (nicht endlich).
    ///   Ein negatives Alter — etwa nach einem Uhrensprung — wird auf 0
    ///   geklemmt statt „vor -3 Minuten" zu behaupten.
    public static func duration(for age: TimeInterval) -> Duration? {
        guard age.isFinite else { return nil }
        // Erst klemmen, dann wandeln: `Int(_:)` würde bei einem absurd großen
        // (aber endlichen) Alter trappen — etwa nach einem Uhrensprung um
        // Jahrtausende. 100 Jahre sind als Obergrenze mehr als genug.
        let clamped = min(max(0, age), maximumAge)
        // Sekundengenau: Minuten und Stunden interessieren, Bruchteile nicht.
        return .seconds(Int(clamped.rounded()))
    }

    /// Obergrenze der Anzeige — jenseits davon ist die Zahl ohnehin ohne
    /// Aussage, nur der Trap wäre echt.
    static var maximumAge: TimeInterval {
        100 * 365 * 24 * 3_600
    }
}
