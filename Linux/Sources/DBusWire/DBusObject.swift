import Foundation

/// Was ein Objekt auf einen Methodenaufruf hin zurückgibt.
///
/// ⚠️ **Dieser Typ hat bewusst keinen Fehlerfall** (Auflage 3). Die
/// `ubuntu-appindicators`-Extension zerstört ein Item, sobald eine ihrer
/// Liveness-Abfragen mit `org.freedesktop.DBus.Error.Unknown*` beantwortet wird
/// (`appIndicator.js:672-715`, gerufen aus `indicatorStatusIcon.js:325`) — und
/// zwar auch dann, wenn `Status` auf `Active` steht. Die Zusage „das Item bleibt
/// sichtbar und sagt etwas" (§5.2) ist damit nicht bloß eine Absprache, sondern
/// im Typ verankert: Ein Dispatcher dieses Projekts **kann** keine Fehlerantwort
/// formulieren, weil es dafür keinen Fall gibt.
public enum DBusCallOutcome: Equatable, Sendable {
    /// Antwort mit Rumpf.
    case reply(signature: String, body: [UInt8])
    /// Antwort ohne Rumpf — die Rückfallantwort für alles Unbekannte.
    case empty
}

/// Ein auf dem Bus bedientes Objekt.
public protocol DBusObject: AnyObject {

    /// Der Objektpfad, unter dem dieses Objekt erreichbar ist.
    var objectPath: String { get }

    /// Beantwortet einen Methodenaufruf. Muss immer antworten — siehe
    /// ``DBusCallOutcome``.
    func handle(_ call: DBusMessage) -> DBusCallOutcome
}

extension DBusCallOutcome {

    /// Kurzform für eine Antwort aus einem einzelnen Wert.
    public static func value(_ value: DBusValue) -> DBusCallOutcome {
        var writer = DBusWriter()
        writer.write(value)
        return .reply(signature: value.signature, body: writer.bytes)
    }

    /// Kurzform für eine Antwort aus mehreren Werten.
    public static func values(_ values: [DBusValue]) -> DBusCallOutcome {
        var writer = DBusWriter()
        for value in values { writer.write(value) }
        return .reply(signature: values.map(\.signature).joined(), body: writer.bytes)
    }
}
