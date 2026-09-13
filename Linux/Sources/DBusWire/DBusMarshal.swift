import Foundation

/// Schreibt Werte in der D-Bus-Byte-Darstellung.
///
/// **Little-Endian.** Die Byte-Reihenfolge steht im Nachrichtenkopf (`l`); ein
/// Client darf seine eigene wählen. Little-Endian ist die des Ziels (x86_64,
/// aarch64) und spart damit jede Umrechnung.
///
/// Die Ausrichtung (`pad`) ist kein Detail, sondern der häufigste Fehler in
/// handgeschriebenen D-Bus-Codecs: Jeder Wert beginnt an einem Vielfachen
/// seiner Ausrichtung, gezählt **ab dem Anfang der Nachricht** — deshalb zählt
/// dieser Schreiber ab `bytes.count` und nicht ab dem Anfang eines Teilstücks.
/// Für Array-Inhalte, die nicht am Nachrichtenanfang liegen, gilt dasselbe, weil
/// der Schreiber durchgehend in denselben Puffer schreibt.
public struct DBusWriter {

    /// Der geschriebene Puffer.
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Setzt einen Schreiber fort, der bereits an einer Nachrichtenposition
    /// steht — nötig, damit die Ausrichtung des Rumpfs relativ zum
    /// Nachrichtenanfang stimmt.
    public init(continuing prefix: [UInt8]) {
        bytes = prefix
    }

    /// Füllt bis zum nächsten Vielfachen von `alignment`.
    public mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    public mutating func writeByte(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeUInt32(_ value: UInt32) {
        pad(to: 4)
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    /// `s`/`o`: 4-Byte-Länge, Inhalt, abschließendes Nullbyte.
    public mutating func writeString(_ value: String) {
        let utf8 = Array(value.utf8)
        writeUInt32(UInt32(utf8.count))
        bytes += utf8
        bytes.append(0)
    }

    /// `g`: 1-Byte-Länge, Inhalt, abschließendes Nullbyte — **keine**
    /// Ausrichtung.
    public mutating func writeSignature(_ value: String) {
        let utf8 = Array(value.utf8)
        bytes.append(UInt8(truncatingIfNeeded: utf8.count))
        bytes += utf8
        bytes.append(0)
    }

    /// Schreibt einen Wert samt seiner Ausrichtung.
    public mutating func write(_ value: DBusValue) {
        switch value {
        case .byte(let raw):
            writeByte(raw)
        case .bool(let raw):
            writeUInt32(raw ? 1 : 0)
        case .int32(let raw):
            writeInt32(raw)
        case .uint32(let raw):
            writeUInt32(raw)
        case .string(let raw), .objectPath(let raw):
            writeString(raw)
        case .signature(let raw):
            writeSignature(raw)
        case .variant(let inner):
            writeSignature(inner.signature)
            write(inner)
        case .array(let elementSignature, let elements):
            writeArray(elementSignature: elementSignature) { writer in
                for element in elements { writer.write(element) }
            }
        case .dictionary(let entries):
            writeArray(elementSignature: "{sv}") { writer in
                for entry in entries {
                    writer.pad(to: 8)
                    writer.writeString(entry.key)
                    writer.write(.variant(entry.value))
                }
            }
        case .structure(let items):
            pad(to: 8)
            for item in items { write(item) }
        }
    }

    /// Array-Rahmen: Länge **des Inhalts** als `u`, danach der auf die
    /// Elementausrichtung gebrachte Inhalt.
    ///
    /// Die Länge wird nachträglich eingetragen, weil sie vorher nicht bekannt
    /// ist. Sie zählt ausdrücklich **ohne** die Füllbytes zwischen Längenfeld
    /// und erstem Element — deshalb wird `start` erst nach dem `pad` genommen.
    private mutating func writeArray(
        elementSignature: String,
        body: (inout DBusWriter) -> Void
    ) {
        pad(to: 4)
        let lengthIndex = bytes.count
        bytes += [0, 0, 0, 0]
        pad(to: DBusSignature.alignment(of: elementSignature))
        let start = bytes.count
        body(&self)
        let length = UInt32(bytes.count - start)
        withUnsafeBytes(of: length.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[lengthIndex + offset] = byte }
        }
    }
}
