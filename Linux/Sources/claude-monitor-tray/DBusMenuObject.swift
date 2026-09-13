import Foundation
import DBusWire
import TrayPresentation

/// Das Objekt unter `/StatusNotifierItem/Menu` — `com.canonical.dbusmenu` in
/// voller Breite.
///
/// **Vollständig und nicht in Auswahl**, weil ein Item ohne bedientes dbusmenu
/// von gnome-shell nie sichtbar wird (Fachentscheid 5.1): `isReady` hängt am
/// Menüpfad (`appIndicator.js:529,626-630`), und `visible = isReady()`
/// (`indicatorStatusIcon.js:130`). Gemessen: Ein Item mit
/// `Menu=/NO_DBUSMENU` bekommt überhaupt keine dbusmenu-Aufrufe.
///
/// Auch hier gilt: Aufbau und Abbildung liegen in ``TrayMenuLayout`` im
/// Bibliotheksziel; diese Klasse hält den Stand und verteilt die Aufrufe.
final class DBusMenuObject: DBusObject {

    let objectPath: String
    /// Prozesslebenslang — die Kennungen dürfen sich nie verschieben
    /// (Auflage 6).
    let identifiers = TrayMenuIdentifiers()

    private(set) var items: [TrayMenuItem]
    /// Streng monoton. Die Gegenstelle verwirft ein `LayoutUpdated` mit einer
    /// Revision, die sie schon kennt.
    private(set) var revision: UInt32 = 1
    private var pending: [TrayMenuItem.Role] = []

    init(objectPath: String, items: [TrayMenuItem]) {
        self.objectPath = objectPath
        self.items = items
        // Kennungen sofort vergeben, damit sie in der Reihenfolge des ersten
        // Aufbaus liegen und nicht in der zufälligen Reihenfolge der ersten
        // Abfrage.
        for item in items { _ = identifiers.identifier(for: item.key) }
    }

    /// Übernimmt einen neuen Menüstand und meldet, was zu senden ist.
    func apply(_ updated: [TrayMenuItem]) -> TrayMenuLayout.Update {
        let update = TrayMenuLayout.update(from: items, to: updated, identifiers: identifiers)
        items = updated
        for item in updated { _ = identifiers.identifier(for: item.key) }
        if update.structureChanged { revision += 1 }
        return update
    }

    /// Holt die angeklickten Aktionen ab und leert die Liste.
    func takePendingActions() -> [TrayMenuItem.Role] {
        defer { pending = [] }
        return pending
    }

    func handle(_ call: DBusMessage) -> DBusCallOutcome {
        switch (call.interface, call.member) {
        case ("com.canonical.dbusmenu", "GetLayout"):
            var reader = call.bodyReader()
            let parent = (try? reader.readInt32()) ?? TrayMenuIdentifiers.root
            let depth = (try? reader.readInt32()) ?? -1
            let names = (try? reader.readStringArray()) ?? []
            return .values([
                .uint32(revision),
                TrayMenuLayout.layout(
                    of: items,
                    identifiers: identifiers,
                    parent: parent,
                    depth: depth,
                    propertyNames: names
                )
            ])

        case ("com.canonical.dbusmenu", "GetGroupProperties"):
            var reader = call.bodyReader()
            let ids = (try? reader.readInt32Array()) ?? []
            let names = (try? reader.readStringArray()) ?? []
            return .value(TrayMenuLayout.groupProperties(
                of: items,
                identifiers: identifiers,
                ids: ids,
                propertyNames: names
            ))

        case ("com.canonical.dbusmenu", "GetProperty"):
            var reader = call.bodyReader()
            let id = (try? reader.readInt32()) ?? -1
            let name = (try? reader.readString()) ?? ""
            let value = identifiers.key(for: id)
                .flatMap { key in items.first { $0.key == key } }
                .flatMap { TrayMenuLayout.property(named: name, of: $0) }
            // Unbekannt ⇒ Leerwert, nie ein Fehler (Auflage 3).
            return .value(.variant(value ?? .string("")))

        case ("com.canonical.dbusmenu", "Event"):
            record(event: call.bodyReader())
            return .empty

        case ("com.canonical.dbusmenu", "EventGroup"):
            var reader = call.bodyReader()
            _ = try? reader.readArray(elementSignature: "(isvu)") { element in
                try element.align(to: 8)
                let id = try element.readInt32()
                let kind = try element.readString()
                let signature = try element.readSignature()
                try element.skipValue(signature)
                _ = try element.readUInt32()
                self.record(identifier: id, kind: kind)
            }
            // Keine Kennung war unbekannt — jede wird beantwortet.
            return .value(.array(elementSignature: "i", elements: []))

        case ("com.canonical.dbusmenu", "AboutToShow"):
            // `false`: Das Menü ist beim Öffnen bereits aktuell — der
            // Poller hält es nach. Ein `true` verlangte von der Gegenstelle
            // ein sofortiges Nachladen des Layouts, ohne dass sich etwas
            // geändert hätte.
            return .value(.bool(false))

        case ("com.canonical.dbusmenu", "AboutToShowGroup"):
            return .values([
                .array(elementSignature: "i", elements: []),
                .array(elementSignature: "i", elements: [])
            ])

        case ("org.freedesktop.DBus.Properties", "Get"):
            var reader = call.bodyReader()
            _ = try? reader.readString()
            guard let name = try? reader.readString() else { return .value(.variant(.string(""))) }
            return .value(.variant(TraySNIProperties.value(
                named: name,
                in: TraySNIProperties.menuTable()
            )))

        case ("org.freedesktop.DBus.Properties", "GetAll"):
            var reader = call.bodyReader()
            let interface = (try? reader.readString()) ?? ""
            let known = interface.isEmpty || interface == TraySNIProperties.menuInterface
            return .value(.dictionary(known ? TraySNIProperties.menuTable() : []))

        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return .value(.string(TrayIntrospection.menuXML))

        default:
            return .empty
        }
    }

    private func record(event reader: DBusReader) {
        var reader = reader
        guard let id = try? reader.readInt32(), let kind = try? reader.readString() else { return }
        record(identifier: id, kind: kind)
    }

    /// Merkt sich einen Klick. Andere Ereignisse (`hovered`, `opened`,
    /// `closed`) werden beantwortet, lösen aber nichts aus.
    private func record(identifier: Int32, kind: String) {
        guard kind == "clicked",
              let key = identifiers.key(for: identifier),
              let item = items.first(where: { $0.key == key }),
              item.isEnabled
        else { return }
        pending.append(item.role)
    }
}
