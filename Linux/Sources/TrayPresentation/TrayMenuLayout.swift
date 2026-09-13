import Foundation
import DBusWire

/// Die Abbildung des Menümodells auf `com.canonical.dbusmenu`-Werte.
///
/// **Warum diese Datei in einem Bibliotheksziel liegt und nicht im Programm**
/// (Auflage 12): Sie ist der inhaltsreichste Teil der Karte — Layout-Aufbau,
/// Eigenschaftstabelle und die Diff-Berechnung für `ItemsPropertiesUpdated`.
/// Der Nachweis-Platz in `Linux/Package.swift` kann nur Bibliotheksziele
/// importieren; im ausführbaren Ziel wäre genau dieser Teil unprüfbar. Dort
/// bleiben Socket, Registrierung und Ereignisschleife.
public enum TrayMenuLayout {

    /// Fassung des Protokolls, die dieser Prozess spricht.
    public static let version: UInt32 = 3

    // MARK: - Eigenschaften

    /// Die Eigenschaften eines Eintrags.
    ///
    /// `visible` steht ausdrücklich immer dabei und wird nie weggelassen: Eine
    /// fehlende Eigenschaft bedeutet im dbusmenu-Protokoll „Vorgabewert", und
    /// sich auf fremde Vorgabewerte zu verlassen, hieße die eigene Anzeige an
    /// die Fassung der Gegenstelle zu binden.
    public static func properties(of item: TrayMenuItem) -> [DBusDictionaryEntry] {
        switch item.role {
        case .separator:
            return [
                DBusDictionaryEntry("type", .string("separator")),
                DBusDictionaryEntry("enabled", .bool(false)),
                DBusDictionaryEntry("visible", .bool(true))
            ]
        case .information, .refresh, .quit:
            return [
                DBusDictionaryEntry("label", .string(escapeLabel(item.label))),
                DBusDictionaryEntry("enabled", .bool(item.isEnabled)),
                DBusDictionaryEntry("visible", .bool(true))
            ]
        }
    }

    /// Verdoppelt Unterstriche im Beschriftungstext.
    ///
    /// Ein einzelner Unterstrich ist in einem dbusmenu-Label das Zeichen für
    /// den Tastaturkürzel-Buchstaben und verschwindet aus der Anzeige. Ein
    /// Account-Alias darf Unterstriche enthalten — ohne diese Verdopplung fehlte
    /// im Menü genau dieses Zeichen aus dem Namen.
    static func escapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: "__")
    }

    /// Eine einzelne Eigenschaft, wenn es sie gibt.
    public static func property(named name: String, of item: TrayMenuItem) -> DBusValue? {
        properties(of: item).first { $0.key == name }?.value
    }

    /// Filtert eine Eigenschaftsliste auf die angefragten Namen. Eine **leere**
    /// Anfrage heißt „alle" — so steht es in der dbusmenu-Spezifikation.
    static func filter(
        _ entries: [DBusDictionaryEntry],
        to names: [String]
    ) -> [DBusDictionaryEntry] {
        guard !names.isEmpty else { return entries }
        return entries.filter { names.contains($0.key) }
    }

    // MARK: - Layout

    /// Antwort auf `GetLayout`: `(ia{sv}av)`.
    ///
    /// Das Menü ist flach. Für `parent == 0` kommt die Wurzel mit allen
    /// Einträgen als Kinder; für jede andere Kennung der Eintrag selbst ohne
    /// Kinder. Eine unbekannte Kennung ergibt einen leeren Knoten — und
    /// ausdrücklich **keinen** Fehler (Auflage 3).
    public static func layout(
        of items: [TrayMenuItem],
        identifiers: TrayMenuIdentifiers,
        parent: Int32,
        depth: Int32,
        propertyNames: [String]
    ) -> DBusValue {
        guard parent == TrayMenuIdentifiers.root else {
            guard let key = identifiers.key(for: parent),
                  let item = items.first(where: { $0.key == key })
            else {
                return node(identifier: parent, properties: [], children: [])
            }
            return node(
                identifier: parent,
                properties: filter(properties(of: item), to: propertyNames),
                children: []
            )
        }

        // `depth == 0` heißt „nur dieser Knoten". Alles andere (1, oder -1 für
        // „alles") liefert bei einem flachen Menü dieselbe vollständige Liste.
        let children: [DBusValue] = depth == 0 ? [] : items.map { item in
            .variant(node(
                identifier: identifiers.identifier(for: item.key),
                properties: filter(properties(of: item), to: propertyNames),
                children: []
            ))
        }
        return node(
            identifier: TrayMenuIdentifiers.root,
            // Ohne `children-display: submenu` hält die Gegenstelle die Wurzel
            // für einen einfachen Eintrag und fragt die Kinder nie ab.
            properties: [DBusDictionaryEntry("children-display", .string("submenu"))],
            children: children
        )
    }

    private static func node(
        identifier: Int32,
        properties: [DBusDictionaryEntry],
        children: [DBusValue]
    ) -> DBusValue {
        .structure([
            .int32(identifier),
            .dictionary(properties),
            .array(elementSignature: "v", elements: children)
        ])
    }

    /// Antwort auf `GetGroupProperties`: `a(ia{sv})`.
    ///
    /// Eine leere Kennungsliste heißt „alle Einträge".
    public static func groupProperties(
        of items: [TrayMenuItem],
        identifiers: TrayMenuIdentifiers,
        ids: [Int32],
        propertyNames: [String]
    ) -> DBusValue {
        let selected = items.filter { item in
            ids.isEmpty || ids.contains(identifiers.identifier(for: item.key))
        }
        return .array(elementSignature: "(ia{sv})", elements: selected.map { item in
            .structure([
                .int32(identifiers.identifier(for: item.key)),
                .dictionary(filter(properties(of: item), to: propertyNames))
            ])
        })
    }

    // MARK: - Änderungen

    /// Was sich zwischen zwei Menüständen geändert hat.
    public struct Update: Equatable, Sendable {

        /// Menge oder Reihenfolge der Einträge hat sich geändert. Dann hilft
        /// keine Eigenschaftsmeldung mehr — die Gegenstelle muss das Layout neu
        /// holen (`LayoutUpdated`).
        public let structureChanged: Bool
        /// Geänderte Eigenschaften je Eintrag, als `a(ia{sv})`.
        public let updated: DBusValue
        /// Entfallene Eigenschaften je Eintrag, als `a(ias)`.
        public let removed: DBusValue
        /// `true`, wenn nichts zu melden ist.
        public let isEmpty: Bool
    }

    /// Berechnet die Änderung zwischen zwei Menüständen.
    ///
    /// **Nur bei Änderung senden** (Fachentscheid 5.12): Der Takt ist 30 s, und
    /// die Zahlen stehen die meiste Zeit still. Ein bedingungsloses
    /// `LayoutUpdated` alle 30 s ließe die Gegenstelle das ganze Menü neu
    /// aufbauen — bei geöffnetem Menü sichtbar als Flackern.
    public static func update(
        from previous: [TrayMenuItem],
        to current: [TrayMenuItem],
        identifiers: TrayMenuIdentifiers
    ) -> Update {
        guard previous.map(\.key) == current.map(\.key) else {
            return Update(
                structureChanged: true,
                updated: .array(elementSignature: "(ia{sv})", elements: []),
                removed: .array(elementSignature: "(ias)", elements: []),
                isEmpty: false
            )
        }

        var changed: [DBusValue] = []
        var dropped: [DBusValue] = []
        for (before, after) in zip(previous, current) {
            let oldProperties = properties(of: before)
            let newProperties = properties(of: after)

            let differing = newProperties.filter { entry in
                oldProperties.first { $0.key == entry.key }?.value != entry.value
            }
            let missing = oldProperties
                .map(\.key)
                .filter { key in !newProperties.contains { $0.key == key } }

            let identifier = identifiers.identifier(for: after.key)
            if !differing.isEmpty {
                changed.append(.structure([.int32(identifier), .dictionary(differing)]))
            }
            if !missing.isEmpty {
                dropped.append(.structure([
                    .int32(identifier),
                    .array(elementSignature: "s", elements: missing.map { .string($0) })
                ]))
            }
        }

        return Update(
            structureChanged: false,
            updated: .array(elementSignature: "(ia{sv})", elements: changed),
            removed: .array(elementSignature: "(ias)", elements: dropped),
            isEmpty: changed.isEmpty && dropped.isEmpty
        )
    }
}
