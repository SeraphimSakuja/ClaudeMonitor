import Foundation
import DBusWire
import TrayPresentation

/// Das Objekt unter `/StatusNotifierItem` — `org.kde.StatusNotifierItem`,
/// `org.freedesktop.DBus.Properties` und `org.freedesktop.DBus.Introspectable`.
///
/// Es hält den aktuellen Eigenschaftsstand und beantwortet Abfragen. **Was**
/// darin steht, entscheidet es nicht: Die Tabelle kommt aus
/// ``TraySNIProperties`` im Bibliotheksziel (Auflage 12).
final class StatusNotifierItemObject: DBusObject {

    let objectPath: String
    private let menuPath: String
    private(set) var properties: [DBusDictionaryEntry]

    init(objectPath: String, menuPath: String, view: TrayView) {
        self.objectPath = objectPath
        self.menuPath = menuPath
        self.properties = TraySNIProperties.itemTable(for: view, menuPath: menuPath)
    }

    /// Übernimmt einen neuen Anzeigestand.
    ///
    /// - Returns: die **geänderten** Eigenschaften. Leer heißt: nichts senden
    ///   (Fachentscheid 5.12).
    func apply(_ view: TrayView) -> [DBusDictionaryEntry] {
        let updated = TraySNIProperties.itemTable(for: view, menuPath: menuPath)
        let changes = TraySNIProperties.changes(from: properties, to: updated)
        properties = updated
        return changes
    }

    /// Beantwortet einen Aufruf — **immer**, notfalls leer.
    ///
    /// Es gibt hier keinen Zweig, der einen Fehler zurückgibt: ``DBusCallOutcome``
    /// hat dafür keinen Fall (Auflage 3). Eine unbekannte Eigenschaft bekommt
    /// den typgerechten Leerwert aus ``TraySNIProperties/fallback(for:)``, eine
    /// unbekannte Methode eine leere Antwort.
    func handle(_ call: DBusMessage) -> DBusCallOutcome {
        switch (call.interface, call.member) {
        case ("org.freedesktop.DBus.Properties", "Get"):
            var reader = call.bodyReader()
            _ = try? reader.readString()
            guard let name = try? reader.readString() else { return .value(.variant(.string(""))) }
            return .value(.variant(TraySNIProperties.value(named: name, in: properties)))

        case ("org.freedesktop.DBus.Properties", "GetAll"):
            var reader = call.bodyReader()
            let interface = (try? reader.readString()) ?? ""
            // Eine fremde Schnittstelle bekommt ein leeres Wörterbuch — die
            // richtige Antwort auf „ich kenne die nicht", und keine
            // Fehlerantwort.
            let known = interface.isEmpty || interface == TraySNIProperties.itemInterface
            return .value(.dictionary(known ? properties : []))

        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return .value(.string(TrayIntrospection.itemXML(menuPath: menuPath)))

        case ("org.freedesktop.DBus.Peer", "GetMachineId"):
            return .value(.string(""))

        default:
            // Deckt `Activate`, `SecondaryActivate`, `Scroll`, `ContextMenu`,
            // `Peer.Ping` und alles Unbekannte ab. Ein Klick öffnet dank
            // `ItemIsMenu` ohnehin das Menü und landet nie hier.
            return .empty
        }
    }
}
