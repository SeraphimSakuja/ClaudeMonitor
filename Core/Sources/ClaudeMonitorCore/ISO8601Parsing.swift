import Foundation

/// Parser für die `resets_at`-Zeitstempel von claude-swap.
///
/// Die Quelle liefert ISO-8601 mit **Mikrosekunden** und Offset, z. B.
/// `2026-08-03T16:50:00.191164+00:00`. `.withFractionalSeconds` ist auf
/// Millisekunden ausgelegt; wie ein Formatter mit *mehr* als drei
/// Nachkommastellen umgeht, ist nicht dokumentiert.
///
/// Gemessen auf macOS 26 liefern `.191164` und `.191` denselben Instant
/// (Differenz 0,0 s) — dort gibt es also keinen Versatz. Für das
/// Deployment-Target macOS 14 mit älterer ICU konnte das **nicht** verifiziert
/// werden. Die Kürzung auf drei Stellen bleibt deshalb als reine Absicherung
/// stehen: Sie ist auf der gemessenen Plattform ein No-op und schützt auf
/// älteren gegen ein möglicherweise abweichendes Parserverhalten.
enum ISO8601Parsing {

    /// Wandelt einen Zeitstempel der Quelle in ein `Date`; `nil`, wenn er fehlt
    /// oder nicht interpretierbar ist.
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let normalized = normalizedFractionalSeconds(in: string)

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized) ?? plain.date(from: strippedFractionalSeconds(in: string))
    }

    /// Kürzt den Sekundenbruchteil auf höchstens drei Stellen.
    static func normalizedFractionalSeconds(in string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var index = string.index(after: dot)
        var digits = 0
        while index < string.endIndex, string[index].isNumber {
            digits += 1
            index = string.index(after: index)
        }
        guard digits > 3 else { return string }
        let keepEnd = string.index(dot, offsetBy: 4) // Punkt + 3 Ziffern
        return String(string[string.startIndex..<keepEnd]) + String(string[index...])
    }

    /// Entfernt den Sekundenbruchteil vollständig (Fallback).
    static func strippedFractionalSeconds(in string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var index = string.index(after: dot)
        while index < string.endIndex, string[index].isNumber {
            index = string.index(after: index)
        }
        return String(string[string.startIndex..<dot]) + String(string[index...])
    }
}
