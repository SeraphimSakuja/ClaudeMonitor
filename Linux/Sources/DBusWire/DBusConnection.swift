import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Eine Verbindung zum Sitzungsbus über einen `AF_UNIX`-Socket.
///
/// **Ein Thread, eine Schleife, kein `Task`.** Die Nebenläufigkeit dieses
/// Prozesses ist ausdrücklich neu gefasst und nicht von `UsageMonitor`
/// übernommen (Fachentscheid 5.9): `poll()` wartet auf dem Bus-Deskriptor mit
/// einem Zeitlimit, das der Aufrufer aus der Restzeit bis zum nächsten
/// Lesevorgang bildet. Es gibt keinen zweiten Ausführungspfad, damit auch keine
/// Absprache darüber, wer was wann anfassen darf.
///
/// Die Fristen, an denen sich das messen lassen muss (Auflage 4): GDBus
/// antwortet standardmäßig nach **25 s** nicht mehr (`dbusProxy.js:96,104`,
/// Aufruf mit Timeout `-1`), die Liveness-Abfrage der Extension nach **10 s**.
/// Jeder Durchlauf der Schleife muss also deutlich darunter bleiben — der
/// Store-Lesevorgang ist durch `SourceFileGuard.maximumFileSize` (8 MiB)
/// gedeckelt und liegt damit im Millisekundenbereich.
public final class DBusConnection {

    /// Warum eine Verbindung nicht zustande kam — jeder Fall hat im
    /// Exit-Vertrag des Tray-Prozesses seinen eigenen Code.
    public enum ConnectError: Error, Equatable {
        /// `DBUS_SESSION_BUS_ADDRESS` fehlt oder nennt keinen Unix-Pfad.
        case addressUnavailable
        /// `socket()`/`connect()` gescheitert.
        case connectFailed(errno: Int32)
        /// SASL EXTERNAL abgelehnt.
        case authenticationFailed
        /// Verbindung während einer Anfrage abgerissen.
        case disconnected
        /// Der Bus hat auf eine Startanfrage nicht rechtzeitig geantwortet.
        case timedOut
    }

    /// Ergebnis von `RequestName`.
    public enum RequestNameResult: UInt32, Sendable {
        case primaryOwner = 1
        case inQueue = 2
        case exists = 3
        case alreadyOwner = 4
    }

    private static let busName = "org.freedesktop.DBus"
    private static let busPath = "/org/freedesktop/DBus"

    private let descriptor: Int32
    private var serial: UInt32 = 0
    private var inbox: [UInt8] = []
    private var objects: [String: any DBusObject] = [:]

    /// Der eindeutige Name dieser Verbindung (`:1.42`), nach `Hello`.
    public private(set) var uniqueName = ""

    /// Aufrufe, die beantwortet wurden — Schlüssel `interface.member`.
    /// Grundlage der `--selftest`-Abnahme.
    public private(set) var servedCalls: Set<String> = []

    // MARK: - Aufbau

    /// Die Adresse des Sitzungsbusses aus der Umgebung, als Socket-Pfad.
    public static func sessionBusSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let address = environment["DBUS_SESSION_BUS_ADDRESS"] else { return nil }
        // Die Adresse kann mehrere durch `;` getrennte Transporte und je
        // Transport mehrere durch `,` getrennte Schlüssel führen.
        for transport in address.split(separator: ";") {
            for entry in transport.split(separator: ",") where entry.hasPrefix("unix:path=") {
                return String(entry.dropFirst("unix:path=".count))
            }
            if let range = transport.range(of: "unix:path=") {
                let rest = transport[range.upperBound...]
                return String(rest.split(separator: ",").first ?? rest)
            }
        }
        return nil
    }

    /// Verbindet, meldet sich per SASL EXTERNAL an und ruft `Hello`.
    public init(socketPath: String) throws {
        descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw ConnectError.connectFailed(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: 108) { path in
                for (index, byte) in socketPath.utf8.enumerated() where index < 107 {
                    path[index] = CChar(bitPattern: byte)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = errno
            Glibc.close(descriptor)
            throw ConnectError.connectFailed(errno: reason)
        }

        try authenticate()
        try hello()
    }

    /// SASL EXTERNAL: führendes Nullbyte, die eigene UID als Hex, `BEGIN`.
    private func authenticate() throws {
        let uid = String(getuid()).utf8.map { String(format: "%02x", $0) }.joined()
        writeAll([0])
        writeAll(Array("AUTH EXTERNAL \(uid)\r\n".utf8))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = readSome(into: &buffer)
        guard count > 0,
              String(decoding: buffer[0..<count], as: UTF8.self).hasPrefix("OK ")
        else { throw ConnectError.authenticationFailed }

        writeAll(Array("BEGIN\r\n".utf8))
    }

    private func hello() throws {
        let reply = try callBlocking(
            destination: Self.busName,
            path: Self.busPath,
            interface: Self.busName,
            member: "Hello"
        )
        var reader = reply.bodyReader()
        uniqueName = (try? reader.readString()) ?? ""
    }

    /// Schließt die Verbindung. Der Watcher bemerkt das über
    /// `NameOwnerChanged` und nimmt das Item aus dem Panel — genau das ist der
    /// zugesagte saubere Abbau.
    public func close() {
        _ = Glibc.close(descriptor)
    }

    // MARK: - Objekte

    public func register(_ object: any DBusObject) {
        objects[object.objectPath] = object
    }

    // MARK: - Senden

    private func nextSerial() -> UInt32 {
        serial += 1
        return serial
    }

    /// Schickt eine Nachricht; die vergebene Seriennummer kommt zurück.
    @discardableResult
    public func send(_ message: DBusMessage) -> UInt32 {
        var outgoing = message
        outgoing.serial = nextSerial()
        writeAll(outgoing.encoded())
        return outgoing.serial
    }

    @discardableResult
    public func call(
        destination: String,
        path: String,
        interface: String,
        member: String,
        arguments: [DBusValue] = []
    ) -> UInt32 {
        var writer = DBusWriter()
        for argument in arguments { writer.write(argument) }
        return send(DBusMessage(
            type: .methodCall,
            path: path,
            interface: interface,
            member: member,
            destination: destination,
            bodySignature: arguments.map(\.signature).joined(),
            body: writer.bytes
        ))
    }

    public func emit(path: String, interface: String, member: String, arguments: [DBusValue]) {
        var writer = DBusWriter()
        for argument in arguments { writer.write(argument) }
        send(DBusMessage(
            type: .signal,
            // `NO_REPLY_EXPECTED`: Ein Signal beantwortet niemand.
            flags: 1,
            path: path,
            interface: interface,
            member: member,
            bodySignature: arguments.map(\.signature).joined(),
            body: writer.bytes
        ))
    }

    // MARK: - Anfragen mit Antwort (nur beim Start)

    /// Schickt einen Aufruf und wartet auf die Antwort.
    ///
    /// Nur für die Startfolge (`Hello`, `RequestName`, `GetNameOwner`): Im
    /// laufenden Betrieb wartet dieser Prozess auf **nichts**, er beantwortet
    /// nur. Während des Wartens werden eingehende Methodenaufrufe trotzdem
    /// bedient — sonst liefe schon die Registrierung in die 10-s-Frist.
    @discardableResult
    public func callBlocking(
        destination: String,
        path: String,
        interface: String,
        member: String,
        arguments: [DBusValue] = [],
        timeout: TimeInterval = 5
    ) throws -> DBusMessage {
        let serial = call(
            destination: destination,
            path: path,
            interface: interface,
            member: member,
            arguments: arguments
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for message in try pump(timeoutMilliseconds: 100)
            where message.replySerial == serial {
                if message.type == .error { throw ConnectError.disconnected }
                return message
            }
        }
        throw ConnectError.timedOut
    }

    /// Fordert einen Well-Known-Namen an (Auflage 5: Einzelinstanz).
    ///
    /// `DBUS_NAME_FLAG_DO_NOT_QUEUE` (4): Eine zweite Instanz soll **nicht**
    /// in der Warteschlange stehen bleiben und später stillschweigend ein
    /// zweites Panel-Item erzeugen, sondern sofort eine klare Absage bekommen.
    public func requestName(_ name: String) throws -> RequestNameResult {
        let reply = try callBlocking(
            destination: Self.busName,
            path: Self.busPath,
            interface: Self.busName,
            member: "RequestName",
            arguments: [.string(name), .uint32(4)]
        )
        var reader = reply.bodyReader()
        let raw = (try? reader.readUInt32()) ?? 0
        return RequestNameResult(rawValue: raw) ?? .exists
    }

    /// Hat dieser Name gerade einen Eigentümer? (Auflage 13: Watcher da oder
    /// nicht.)
    public func nameHasOwner(_ name: String) throws -> Bool {
        let reply = try callBlocking(
            destination: Self.busName,
            path: Self.busPath,
            interface: Self.busName,
            member: "NameHasOwner",
            arguments: [.string(name)]
        )
        var reader = reply.bodyReader()
        return (try? reader.readBool()) ?? false
    }

    /// Bestellt Signale ab. Ohne passende Regel schickt der Bus einer
    /// Verbindung **keine** fremden Signale — ohne sie bliebe der Neustart des
    /// Watchers unbemerkt.
    public func addMatch(_ rule: String) {
        call(
            destination: Self.busName,
            path: Self.busPath,
            interface: Self.busName,
            member: "AddMatch",
            arguments: [.string(rule)]
        )
    }

    // MARK: - Schleife

    /// Wartet bis zu `timeoutMilliseconds` auf den Bus, beantwortet alle
    /// eingegangenen Methodenaufrufe und gibt alles übrige zurück
    /// (Antworten, Fehler, Signale).
    public func pump(timeoutMilliseconds: Int32) throws -> [DBusMessage] {
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptorSet, 1, timeoutMilliseconds)
        if ready > 0 {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = readSome(into: &buffer)
            // 0 heißt: Gegenstelle hat geschlossen. Ohne diese Prüfung liefe
            // die Schleife danach mit 100 % CPU leer.
            guard count != 0 else { throw ConnectError.disconnected }
            if count > 0 { inbox += buffer[0..<count] }
        }

        var rest: [DBusMessage] = []
        while let decoded = try DBusMessage.decode(from: inbox) {
            inbox.removeFirst(decoded.consumed)
            let message = decoded.message
            guard message.type == .methodCall else {
                rest.append(message)
                continue
            }
            servedCalls.insert(message.callKey)
            answer(message)
        }
        return rest
    }

    /// Beantwortet einen Methodenaufruf — **immer**, notfalls leer.
    ///
    /// Ein unbekannter Pfad ist hier ausdrücklich kein Fehler (Auflage 3):
    /// `UnknownObject` wäre für die Extension dasselbe Todesurteil wie
    /// `UnknownProperty`.
    private func answer(_ call: DBusMessage) {
        let outcome = objects[call.path]?.handle(call) ?? .empty
        // `NO_REPLY_EXPECTED` gesetzt? Dann ist die Antwort unerwünscht.
        guard call.flags & 1 == 0 else { return }
        switch outcome {
        case .reply(let signature, let body):
            send(DBusMessage(
                type: .methodReturn,
                flags: 1,
                replySerial: call.serial,
                destination: call.sender,
                bodySignature: signature,
                body: body
            ))
        case .empty:
            send(DBusMessage(
                type: .methodReturn,
                flags: 1,
                replySerial: call.serial,
                destination: call.sender
            ))
        }
    }

    // MARK: - Socket

    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let written = write(descriptor, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                // Ein Schreibversuch, der durch ein Signal unterbrochen wurde,
                // wird wiederholt; alles andere bricht ab — die Schleife merkt
                // den Abriss beim nächsten `pump`.
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    private func readSome(into buffer: inout [UInt8]) -> Int {
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            return count
        }
    }
}
