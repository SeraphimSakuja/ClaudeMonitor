import Foundation

/// Reine Regeln für `enabled-extensions`/`disabled-extensions` (CM-43), ohne
/// Ein- und Ausgabe.
public enum GnomeExtensionSettings {

    /// Neue Listen nach ``planEnable(enabled:disabled:uuid:)``; `nil` = Liste
    /// bleibt, es wird kein `set` abgesetzt.
    public struct EnablePlan: Equatable, Sendable {
        public let enabled: [String]?
        public let disabled: [String]?
    }

    /// Die `gsettings get`-Ausgabe einer Liste von Zeichenketten.
    ///
    /// Angenommen: `@as []`, `[]` und `['…', …]` bzw. `"…"`. Als Escapes gelten
    /// nur `\\`, `\'` und `\"`. Alles andere ergibt `nil`.
    public static func parseStrv(_ text: String) -> [String]? {
        var chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if chars.starts(with: Array("@as")) {
            chars.removeFirst(3)
            while let first = chars.first, first == " " { chars.removeFirst() }
        }
        guard chars.first == "[", chars.last == "]" else { return nil }
        chars = Array(chars.dropFirst().dropLast())

        var result: [String] = []
        var index = 0
        func skipSpaces() { while index < chars.count, chars[index] == " " { index += 1 } }
        skipSpaces()
        if index == chars.count { return [] }
        while true {
            skipSpaces()
            guard index < chars.count, chars[index] == "'" || chars[index] == "\"" else { return nil }
            let quote = chars[index]
            index += 1
            var item = ""
            var closed = false
            while index < chars.count {
                let char = chars[index]
                if char == "\\" {
                    guard index + 1 < chars.count, ["\\", "'", "\""].contains(chars[index + 1]) else { return nil }
                    item.append(chars[index + 1])
                    index += 2
                    continue
                }
                if char == quote {
                    closed = true
                    index += 1
                    break
                }
                item.append(char)
                index += 1
            }
            guard closed else { return nil }
            result.append(item)
            skipSpaces()
            if index == chars.count { return result }
            guard chars[index] == "," else { return nil }
            index += 1
        }
    }

    /// `['a', 'b']` — einfache Anführungszeichen, `\` und `'` werden escaped.
    public static func renderStrv(_ items: [String]) -> String {
        let rendered = items.map { item -> String in
            let escaped = item.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return "'" + escaped + "'"
        }
        return "[" + rendered.joined(separator: ", ") + "]"
    }

    /// Die Shell-eigene Regel `enableExtension` (`extensionSystem.js:279-290`):
    /// Fehlt die UUID in `enabled`, wird sie ans Ende gehängt; aus `disabled`
    /// wird sie entfernt (`disabled` hat Vorrang, `:557-559`). `nil`, wenn sich
    /// nichts ändert.
    public static func planEnable(enabled: [String], disabled: [String], uuid: String) -> EnablePlan? {
        let newEnabled: [String]? = enabled.contains(uuid) ? nil : enabled + [uuid]
        let newDisabled: [String]? = disabled.contains(uuid) ? disabled.filter { $0 != uuid } : nil
        if newEnabled == nil && newDisabled == nil { return nil }
        return EnablePlan(enabled: newEnabled, disabled: newDisabled)
    }

    /// Die UUID wird aus `enabled` entfernt (alle Vorkommen), `disabled` bleibt
    /// unberührt. `nil`, wenn sie nicht drin ist.
    public static func planDisable(enabled: [String], uuid: String) -> [String]? {
        enabled.contains(uuid) ? enabled.filter { $0 != uuid } : nil
    }
}
