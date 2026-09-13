import Foundation
import Testing
@testable import DBusWire

@Suite("CM-20 · D-Bus-Wire-Codec: Rundtrip und Ausrichtung")
struct DBusWireCodecTests {

    /// Eine Nachricht encodieren und wieder decodieren — mit **Ausrichtungs-
    /// beleg**.
    ///
    /// Die Erwartung an die Offsets stammt aus der D-Bus-Wire-Spezifikation
    /// („STRUCT is aligned to 8", Nachrichtenrumpf beginnt an einer
    /// 8-Byte-Grenze) und ausdrücklich **nicht** aus dem vorliegenden Encoder:
    /// Ein `uint32` belegt die Bytes 0–3 des Rumpfes, die folgende Struktur
    /// beginnt deshalb bei 8 und nicht bei 4.
    @Test("Rundtrip hält Kopf, Rumpf und die 8-Byte-Ausrichtung ein")
    func roundtripKeepsAlignment() throws {
        // Rumpf: ein `u`, dann `(ia{sv}av)` — die verschachtelte Struktur trägt
        // zwei Kinder im `av`.
        let structure = DBusValue.structure([
            .int32(42),
            .dictionary([DBusDictionaryEntry("label", .string("ClaudeMonitor"))]),
            .array(elementSignature: "v", elements: [.variant(.string("first")), .variant(.uint32(2))])
        ])
        var writer = DBusWriter()
        writer.write(.uint32(7))
        writer.write(structure)
        let body = writer.bytes

        let message = DBusMessage(
            type: .methodReturn,
            flags: 1,
            serial: 9,
            replySerial: 17,
            destination: ":1.38661",
            bodySignature: "u(ia{sv}av)",
            body: body
        )
        let encoded = message.encoded()

        guard let (decoded, consumed) = try DBusMessage.decode(from: encoded) else {
            Issue.record("Die eigene Nachricht ließ sich nicht wieder lesen")
            return
        }

        #expect(consumed == encoded.count)
        #expect(decoded.type == .methodReturn)
        #expect(decoded.serial == 9)
        #expect(decoded.replySerial == 17)
        #expect(decoded.destination == ":1.38661")
        #expect(decoded.bodySignature == "u(ia{sv}av)")
        #expect(decoded.body == body)

        // Der Rumpf beginnt im Draht an einem Vielfachen von 8.
        #expect((encoded.count - body.count) % 8 == 0)

        // Werte-Rundtrip mit dem Leser, der dieselbe Ausrichtung rechnet.
        var reader = decoded.bodyReader()
        #expect(try reader.readUInt32() == 7)
        try reader.align(to: 8)
        // Die Struktur beginnt bei 8, nicht bei 4.
        #expect(reader.offset == 8)
        #expect(try reader.readInt32() == 42)

        let entries = try reader.readArray(elementSignature: "{sv}") { inner -> (String, String) in
            try inner.align(to: 8)
            let key = try inner.readString()
            let signature = try inner.readSignature()
            #expect(signature == "s")
            return (key, try inner.readString())
        }
        #expect(entries.count == 1)
        #expect(entries.first?.0 == "label")
        #expect(entries.first?.1 == "ClaudeMonitor")

        let variants = try reader.readArray(elementSignature: "v") { inner -> String in
            switch try inner.readSignature() {
            case "s": return try inner.readString()
            case "u": return String(try inner.readUInt32())
            case let other: return "?" + other
            }
        }
        #expect(variants == ["first", "2"])

        // Ein um ein Byte gekürzter Puffer ist „noch nicht vollständig" —
        // `nil`, kein Absturz und kein Fehler.
        let truncated = try DBusMessage.decode(from: Array(encoded.dropLast()))
        #expect(truncated == nil)
    }
}
