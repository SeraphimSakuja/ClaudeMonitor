import Foundation

/// Ein Wert des D-Bus-Wire-Protokolls.
///
/// Bewusst **nicht** der vollständige Typvorrat der Spezifikation: Aufgenommen
/// ist genau das, was `org.kde.StatusNotifierItem` und `com.canonical.dbusmenu`
/// **senden**. Typen, die nur in fremden Argumenten vorkommen können (`n`, `q`,
/// `x`, `t`, `d`, `h`), werden beim Lesen über ``DBusReader/skipValue(_:)``
/// übersprungen, statt hier als Fall zu erscheinen — ein Fall, den niemand
/// schreibt, wäre toter Code mit eigener Fehlerquelle.
///
/// `indirect`, weil `variant`/`array`/`structure` sich selbst enthalten.
public indirect enum DBusValue: Equatable, Sendable {
    case byte(UInt8)
    case bool(Bool)
    case int32(Int32)
    case uint32(UInt32)
    case string(String)
    case objectPath(String)
    case signature(String)
    case variant(DBusValue)
    /// `a<elementSignature>` — die Elementsignatur steht mit dabei, weil ein
    /// **leeres** Array sie sonst nicht mehr hergäbe. Genau daran hängt
    /// Auflage 2: ein leeres `a(iiay)` muss als solches erkennbar bleiben.
    case array(elementSignature: String, elements: [DBusValue])
    /// `a{sv}` — der einzige Wörterbuchtyp, den beide Schnittstellen benutzen.
    case dictionary([DBusDictionaryEntry])
    case structure([DBusValue])
}

/// Ein Eintrag eines `a{sv}`.
///
/// Ein benannter Typ statt des Tupels `(String, DBusValue)`: Nur so ist
/// ``DBusValue`` `Equatable` — und ohne `Equatable` gäbe es keine
/// Diff-Berechnung für `ItemsPropertiesUpdated`.
public struct DBusDictionaryEntry: Equatable, Sendable {
    public let key: String
    public let value: DBusValue

    public init(_ key: String, _ value: DBusValue) {
        self.key = key
        self.value = value
    }
}

extension DBusValue {

    /// Die Signatur dieses Wertes.
    public var signature: String {
        switch self {
        case .byte: return "y"
        case .bool: return "b"
        case .int32: return "i"
        case .uint32: return "u"
        case .string: return "s"
        case .objectPath: return "o"
        case .signature: return "g"
        case .variant: return "v"
        case .array(let element, _): return "a" + element
        case .dictionary: return "a{sv}"
        case .structure(let items): return "(" + items.map(\.signature).joined() + ")"
        }
    }
}

/// Regeln über Signaturen — Ausrichtung und Zerlegung.
public enum DBusSignature {

    /// Ausrichtung eines Typcodes in Bytes (D-Bus-Spezifikation, Tabelle
    /// „Alignment").
    ///
    /// Vollständig für **alle** Typcodes, nicht nur für die von ``DBusValue``
    /// abgedeckten: Beim Überspringen fremder Argumente muss auch ein `t` oder
    /// `d` richtig ausgerichtet werden, sonst verrutscht der Lesezeiger und die
    /// ganze folgende Nachricht wird Unsinn.
    public static func alignment(ofTypeCode code: Character) -> Int {
        switch code {
        case "y", "g", "v": return 1
        case "n", "q": return 2
        case "b", "i", "u", "s", "o", "a", "h": return 4
        case "x", "t", "d", "(", "{": return 8
        default: return 1
        }
    }

    /// Ausrichtung des ersten Typs einer Signatur.
    public static func alignment(of signature: some StringProtocol) -> Int {
        alignment(ofTypeCode: signature.first ?? "y")
    }

    /// Der erste vollständige Einzeltyp ab dem Anfang von `signature`.
    ///
    /// „Vollständig" heißt: `(ii)` und `a{sv}` kommen als Ganzes zurück, nicht
    /// als `(`. Nötig, um Elementsignaturen aus einer zusammengesetzten
    /// Signatur herauszulösen, ohne sie zu parsen.
    public static func firstCompleteType(of signature: Substring) -> Substring {
        guard let first = signature.first else { return signature }
        if first == "a" {
            let rest = firstCompleteType(of: signature.dropFirst())
            return signature[signature.startIndex..<rest.endIndex]
        }
        guard first == "(" || first == "{" else {
            return signature[signature.startIndex..<signature.index(after: signature.startIndex)]
        }
        var depth = 0
        var index = signature.startIndex
        while index < signature.endIndex {
            let character = signature[index]
            if character == "(" || character == "{" { depth += 1 }
            if character == ")" || character == "}" { depth -= 1 }
            index = signature.index(after: index)
            if depth == 0 { break }
        }
        return signature[signature.startIndex..<index]
    }
}
