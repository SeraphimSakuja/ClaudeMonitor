import Foundation

/// Fehler beim Lesen einer D-Bus-Nachricht.
///
/// Es gibt sie, weil der Tray-Prozess **resident** ist: Er liest, was der Bus
/// ihm schickt, und das ist fremdbestimmter Inhalt. Ein Codec, der bei einer
/// abgeschnittenen oder unsinnigen Nachricht mit einem Index-Trap abstürzt,
/// nähme dem Nutzer die Anzeige — ein geworfener Fehler kostet höchstens eine
/// Nachricht.
public enum DBusWireError: Error, Equatable {
    /// Der Puffer endet mitten im Wert.
    case truncated
    /// Der Inhalt widerspricht der Spezifikation.
    case malformed(String)
    /// Verschachtelung jenseits von ``DBusReader/maximumDepth``.
    case tooDeeplyNested
}

/// Liest Werte aus der D-Bus-Byte-Darstellung — **little-endian**, passend zum
/// Schreiber. Nachrichten mit `B` im Kopf (big-endian) weist
/// ``DBusMessage/decode(from:)`` ab; sie kommen von keinem Bus, den dieses
/// Projekt bedient, und ein ungetesteter zweiter Pfad wäre schlechter als eine
/// klare Absage.
///
/// **Jeder** Lesezugriff ist geprüft. Der Lesezeiger bewegt sich nur, wenn die
/// Bytes wirklich da sind.
public struct DBusReader {

    /// Grenze gegen eine Nachricht, die sich selbst in Varianten verschachtelt,
    /// bis der Stapel voll ist. Die D-Bus-Spezifikation erlaubt 64 Ebenen; 32
    /// liegt darüber, was beide bedienten Schnittstellen je brauchen (`v` in
    /// `av` in `(ia{sv}av)` sind drei).
    public static let maximumDepth = 32

    private let bytes: [UInt8]
    /// Position **relativ zum Anfang der Nachricht** — nur so stimmt die
    /// Ausrichtung. Teilstücke dürfen deshalb ausschließlich an
    /// 8-Byte-Grenzen der Nachricht beginnen.
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public mutating func align(to alignment: Int) throws {
        while offset % alignment != 0 {
            guard offset < bytes.count else { throw DBusWireError.truncated }
            offset += 1
        }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else { throw DBusWireError.truncated }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    public mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw DBusWireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readUInt32() throws -> UInt32 {
        try align(to: 4)
        let raw = try take(4)
        return raw.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readBool() throws -> Bool {
        try readUInt32() != 0
    }

    public mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        let raw = try take(length)
        // Das Nullbyte gehört zur Darstellung, nicht zum Inhalt.
        guard try readByte() == 0 else { throw DBusWireError.malformed("string terminator") }
        return String(decoding: raw, as: UTF8.self)
    }

    public mutating func readSignature() throws -> String {
        let length = Int(try readByte())
        let raw = try take(length)
        guard try readByte() == 0 else { throw DBusWireError.malformed("signature terminator") }
        return String(decoding: raw, as: UTF8.self)
    }

    /// Liest ein Array, indem `element` je Element gerufen wird.
    ///
    /// Die Schleife endet am **Längenfeld**, nicht an einer Zählung: Ein Array
    /// steht mit seiner Byte-Länge im Draht, die Elementzahl steht nirgends.
    public mutating func readArray<Element>(
        elementSignature: String,
        element: (inout DBusReader) throws -> Element
    ) throws -> [Element] {
        let length = Int(try readUInt32())
        try align(to: DBusSignature.alignment(of: elementSignature))
        let end = offset + length
        guard end <= bytes.count else { throw DBusWireError.truncated }
        var result: [Element] = []
        while offset < end {
            result.append(try element(&self))
        }
        guard offset == end else { throw DBusWireError.malformed("array overrun") }
        return result
    }

    public mutating func readStringArray() throws -> [String] {
        try readArray(elementSignature: "s") { try $0.readString() }
    }

    public mutating func readInt32Array() throws -> [Int32] {
        try readArray(elementSignature: "i") { try $0.readInt32() }
    }

    /// Überspringt einen Wert der angegebenen Signatur.
    ///
    /// Deckt **alle** Typcodes ab, auch die, die ``DBusValue`` nicht führt:
    /// Fremde Argumente (etwa die Nutzlast von `com.canonical.dbusmenu.Event`)
    /// dürfen alles enthalten, und ein falsch übersprungener Wert verschöbe den
    /// Lesezeiger für den gesamten Rest der Nachricht.
    public mutating func skipValue(_ signature: String) throws {
        try skipValue(Substring(signature), depth: 0)
    }

    private mutating func skipValue(_ signature: Substring, depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw DBusWireError.tooDeeplyNested }
        var rest = signature
        while let code = rest.first {
            switch code {
            case "y":
                _ = try readByte()
            case "n", "q":
                try align(to: 2)
                _ = try take(2)
            case "b", "i", "u", "h":
                _ = try readUInt32()
            case "x", "t", "d":
                try align(to: 8)
                _ = try take(8)
            case "s", "o":
                _ = try readString()
            case "g":
                _ = try readSignature()
            case "v":
                let inner = try readSignature()
                try skipValue(Substring(inner), depth: depth + 1)
            case "a":
                let elementSignature = DBusSignature.firstCompleteType(of: rest.dropFirst())
                let length = Int(try readUInt32())
                try align(to: DBusSignature.alignment(of: elementSignature))
                _ = try take(length)
                rest = rest[elementSignature.endIndex...]
                continue
            case "(", "{":
                let whole = DBusSignature.firstCompleteType(of: rest)
                try align(to: 8)
                try skipValue(whole.dropFirst().dropLast(), depth: depth + 1)
                rest = rest[whole.endIndex...]
                continue
            default:
                throw DBusWireError.malformed("unknown type code \(code)")
            }
            rest = rest.dropFirst()
        }
    }
}
