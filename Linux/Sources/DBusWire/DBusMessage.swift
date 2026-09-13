import Foundation

/// Art einer D-Bus-Nachricht.
public enum DBusMessageType: UInt8, Sendable, Equatable {
    case methodCall = 1
    case methodReturn = 2
    case error = 3
    case signal = 4
}

/// Eine D-Bus-Nachricht: fester Kopf, Kopffelder, Rumpf.
///
/// Die Kopffelder sind hier **benannte Eigenschaften** und keine Liste von
/// Code-Wert-Paaren. Grund: Jede Stelle, die eine Nachricht baut oder liest,
/// hätte sonst ihre eigene Vorstellung davon, welcher Code was bedeutet —
/// genau die Sorte Fehler, die auf dem Draht als „Nachricht wird still
/// ignoriert" erscheint und stundenlang nicht zu finden ist.
public struct DBusMessage: Equatable, Sendable {

    public var type: DBusMessageType
    /// Bit 0 = `NO_REPLY_EXPECTED`. Antworten und Signale setzen es.
    public var flags: UInt8
    public var serial: UInt32
    public var replySerial: UInt32?
    public var path: String
    public var interface: String
    public var member: String
    public var errorName: String
    public var destination: String
    public var sender: String
    public var bodySignature: String
    public var body: [UInt8]

    public init(
        type: DBusMessageType,
        flags: UInt8 = 0,
        serial: UInt32 = 0,
        replySerial: UInt32? = nil,
        path: String = "",
        interface: String = "",
        member: String = "",
        errorName: String = "",
        destination: String = "",
        sender: String = "",
        bodySignature: String = "",
        body: [UInt8] = []
    ) {
        self.type = type
        self.flags = flags
        self.serial = serial
        self.replySerial = replySerial
        self.path = path
        self.interface = interface
        self.member = member
        self.errorName = errorName
        self.destination = destination
        self.sender = sender
        self.bodySignature = bodySignature
        self.body = body
    }

    /// `interface.member` — der Schlüssel, unter dem ein Dispatcher entscheidet.
    public var callKey: String { "\(interface).\(member)" }

    // MARK: - Schreiben

    /// Die fertige Byte-Darstellung.
    public func encoded() -> [UInt8] {
        var fields = DBusWriter()
        func field(_ code: UInt8, _ value: DBusValue) {
            // Kopffelder sind ein `a(yv)`: jeder Eintrag auf 8 ausgerichtet.
            // Dieser Teilschreiber beginnt bei 0, der endgültige Platz des
            // Feldarrays ist Byte 16 — beide sind 8-ausgerichtet, die
            // Füllbytes stimmen daher überein.
            fields.pad(to: 8)
            fields.writeByte(code)
            fields.write(.variant(value))
        }
        if !path.isEmpty { field(1, .objectPath(path)) }
        if !interface.isEmpty { field(2, .string(interface)) }
        if !member.isEmpty { field(3, .string(member)) }
        if !errorName.isEmpty { field(4, .string(errorName)) }
        if let replySerial { field(5, .uint32(replySerial)) }
        if !destination.isEmpty { field(6, .string(destination)) }
        if !bodySignature.isEmpty { field(8, .signature(bodySignature)) }

        var message = DBusWriter()
        message.writeByte(UInt8(ascii: "l"))
        message.writeByte(type.rawValue)
        message.writeByte(flags)
        message.writeByte(1)
        message.writeUInt32(UInt32(body.count))
        message.writeUInt32(serial)
        message.writeUInt32(UInt32(fields.bytes.count))
        var bytes = message.bytes + fields.bytes
        while bytes.count % 8 != 0 { bytes.append(0) }
        return bytes + body
    }

    // MARK: - Lesen

    /// Liest die erste vollständige Nachricht aus `buffer`.
    ///
    /// - Returns: `nil`, wenn noch nicht genug Bytes da sind — der Aufrufer
    ///   sammelt dann weiter. Andernfalls die Nachricht und die Anzahl der
    ///   verbrauchten Bytes.
    public static func decode(from buffer: [UInt8]) throws -> (message: DBusMessage, consumed: Int)? {
        guard buffer.count >= 16 else { return nil }
        guard buffer[0] == UInt8(ascii: "l") else {
            // Big-Endian kommt von keinem Bus dieses Projekts; ein zweiter,
            // nie durchlaufener Pfad wäre gefährlicher als eine Absage.
            throw DBusWireError.malformed("unsupported byte order")
        }
        guard let type = DBusMessageType(rawValue: buffer[1]) else {
            throw DBusWireError.malformed("unknown message type \(buffer[1])")
        }

        var head = DBusReader(buffer, offset: 4)
        let bodyLength = Int(try head.readUInt32())
        let serial = try head.readUInt32()
        let fieldsLength = Int(try head.readUInt32())

        var bodyStart = 16 + fieldsLength
        while bodyStart % 8 != 0 { bodyStart += 1 }
        let total = bodyStart + bodyLength
        guard buffer.count >= total else { return nil }

        var message = DBusMessage(type: type, flags: buffer[2], serial: serial)
        var fields = DBusReader(buffer, offset: 16)
        let fieldsEnd = 16 + fieldsLength
        while fields.offset < fieldsEnd {
            try fields.align(to: 8)
            guard fields.offset < fieldsEnd else { break }
            let code = try fields.readByte()
            let signature = try fields.readSignature()
            switch (code, signature) {
            case (1, "o"): message.path = try fields.readString()
            case (2, "s"): message.interface = try fields.readString()
            case (3, "s"): message.member = try fields.readString()
            case (4, "s"): message.errorName = try fields.readString()
            case (5, "u"): message.replySerial = try fields.readUInt32()
            case (6, "s"): message.destination = try fields.readString()
            case (7, "s"): message.sender = try fields.readString()
            case (8, "g"): message.bodySignature = try fields.readSignature()
            // Unbekannte Kopffelder sind ausdrücklich erlaubt und werden
            // übersprungen, nicht als Fehler behandelt.
            default: try fields.skipValue(signature)
            }
        }

        message.body = Array(buffer[bodyStart..<total])
        return (message, total)
    }

    /// Liest den Rumpf mit einem Leser, dessen Ausrichtung zur Nachricht passt.
    ///
    /// Der Rumpf beginnt im Draht immer an einer 8-Byte-Grenze; ein Leser über
    /// den Rumpf allein (Offset 0) rechnet deshalb richtig.
    public func bodyReader() -> DBusReader {
        DBusReader(body)
    }
}
