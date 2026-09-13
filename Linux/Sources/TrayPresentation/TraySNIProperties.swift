import Foundation
import DBusWire

/// Die Eigenschaftstabellen der beiden bedienten Schnittstellen.
///
/// Liegt nach Auflage 12 im Bibliotheksziel: Welche Eigenschaft welchen Wert
/// trägt, ist eine Abbildung und keine Socket-Arbeit.
public enum TraySNIProperties {

    public static let itemInterface = "org.kde.StatusNotifierItem"
    public static let menuInterface = "com.canonical.dbusmenu"

    /// Die Kennung des Items auf dem Bus. Sie taucht in der Panel-Reihenfolge
    /// und in Fehlermeldungen der Extension auf.
    public static let itemIdentifier = "claude-monitor"

    /// Die Eigenschaften von `org.kde.StatusNotifierItem`.
    ///
    /// `Status` ist **immer** `Active` (Fachentscheid 5.2). `Passive` blendet
    /// das Item aus (`indicatorStatusIcon.js:322`) — ein leerer Text ist eine
    /// Aussage, ein verschwundenes Item ist keine.
    public static func itemTable(for view: TrayView, menuPath: String) -> [DBusDictionaryEntry] {
        [
            DBusDictionaryEntry("Category", .string("SystemServices")),
            DBusDictionaryEntry("Id", .string(itemIdentifier)),
            DBusDictionaryEntry("Title", .string(TrayTexts.applicationName)),
            DBusDictionaryEntry("Status", .string("Active")),
            DBusDictionaryEntry("WindowId", .int32(0)),
            DBusDictionaryEntry("IconThemePath", .string("")),
            DBusDictionaryEntry("Menu", .objectPath(menuPath)),
            // `true`: Ein Klick soll das Menü öffnen und nicht als
            // `Activate` beim Prozess landen — es gibt kein Fenster, das sich
            // dort aktivieren ließe, der Klick verpuffte sonst wirkungslos.
            DBusDictionaryEntry("ItemIsMenu", .bool(true)),
            DBusDictionaryEntry("IconName", .string("")),
            DBusDictionaryEntry("IconPixmap", TrayIconPixmap.dbusValue(for: view.icon)),
            DBusDictionaryEntry("IconAccessibleDesc", .string(accessibleDescription(for: view))),
            DBusDictionaryEntry("OverlayIconName", .string("")),
            DBusDictionaryEntry("OverlayIconPixmap", TrayIconPixmap.emptyPixmapArray),
            DBusDictionaryEntry("AttentionIconName", .string("")),
            DBusDictionaryEntry("AttentionIconPixmap", TrayIconPixmap.emptyPixmapArray),
            DBusDictionaryEntry("AttentionMovieName", .string("")),
            DBusDictionaryEntry("AttentionAccessibleDesc", .string("")),
            // Der Panel-Text (Fachentscheid 5.11). Er läuft über den
            // Optional-Property-Pfad der Extension
            // (`appIndicator.js:88-96,153-176`, `_onPropertiesChanged` `:748-751`)
            // und ausdrücklich nicht über `XAyatanaNewLabel` — jenes Signal ist
            // im Interface-XML auskommentiert
            // (`interfaces-xml/StatusNotifierItem.xml:123-132`, Auflage 14).
            DBusDictionaryEntry("XAyatanaLabel", .string(view.labelText)),
            DBusDictionaryEntry("XAyatanaLabelGuide", .string("")),
            DBusDictionaryEntry("XAyatanaOrderingIndex", .uint32(0))
        ]
    }

    /// Vorlesetext des Symbols: Produktname plus Panel-Text, falls einer da ist.
    static func accessibleDescription(for view: TrayView) -> String {
        view.labelText.isEmpty
            ? TrayTexts.applicationName
            : "\(TrayTexts.applicationName) \(view.labelText)"
    }

    /// Die Eigenschaften von `com.canonical.dbusmenu`.
    public static func menuTable() -> [DBusDictionaryEntry] {
        [
            DBusDictionaryEntry("Version", .uint32(TrayMenuLayout.version)),
            DBusDictionaryEntry("Status", .string("normal")),
            DBusDictionaryEntry("TextDirection", .string("ltr")),
            DBusDictionaryEntry("IconThemePath", .array(elementSignature: "s", elements: []))
        ]
    }

    /// Der Wert einer Eigenschaft — **immer** einer (Auflage 3).
    ///
    /// Es gibt keinen Rückgabewert „gibt es nicht". Eine unbekannte Eigenschaft
    /// bekommt einen typgerechten Leerwert, weil die Extension ein Item nach
    /// einer `Unknown*`-Fehlerantwort auf ihre 10-s-Liveness-Frage zerstört
    /// (`appIndicator.js:672-715`) — auch bei `Status = Active`.
    public static func value(named name: String, in table: [DBusDictionaryEntry]) -> DBusValue {
        table.first { $0.key == name }?.value ?? fallback(for: name)
    }

    /// Der typgerechte Leerwert zu einem unbekannten Eigenschaftsnamen.
    ///
    /// Die Zuordnung geht nach der Endung des Namens, weil ein unbekannter Name
    /// definitionsgemäß in keiner Tabelle steht. Trifft nichts zu, kommt eine
    /// leere Zeichenkette: Sie ist der Wert, mit dem jeder Leser umgehen kann,
    /// der überhaupt etwas erwartet.
    public static func fallback(for name: String) -> DBusValue {
        if name.hasSuffix("Pixmap") { return TrayIconPixmap.emptyPixmapArray }
        if name.hasSuffix("Index") { return .uint32(0) }
        if name.hasSuffix("Id") { return .int32(0) }
        return .string("")
    }

    /// Die Eigenschaften, die sich zwischen zwei Ständen geändert haben.
    ///
    /// Nur sie gehen in `PropertiesChanged` (Fachentscheid 5.12). Das Pixmap
    /// ist knapp 2 KB — es alle 30 s ohne Änderung mitzuschicken, wäre der
    /// teuerste Teil eines Durchlaufs, der sonst nichts kostet.
    public static func changes(
        from previous: [DBusDictionaryEntry],
        to current: [DBusDictionaryEntry]
    ) -> [DBusDictionaryEntry] {
        current.filter { entry in
            previous.first { $0.key == entry.key }?.value != entry.value
        }
    }
}

/// Die eigene `Introspect`-Antwort.
///
/// ⚠️ Der Interface-Name `org.kde.StatusNotifierItem` muss **wörtlich** darin
/// stehen (Auflage 13): Die Extension findet ein Item nach ihrem eigenen
/// Neustart nur wieder, indem sie die Introspektionsdaten aller Busnamen
/// wörtlich danach filtert (`tools/busAnalyzer.js:19-21`). Ohne diesen String
/// wäre das Item nach jedem `gnome-shell`-Neustart weg, obwohl der Prozess
/// läuft.
public enum TrayIntrospection {

    public static func itemXML(menuPath: String) -> String {
        """
        <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" \
        "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        <node>
          <interface name="org.freedesktop.DBus.Introspectable">
            <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
          </interface>
          <interface name="org.freedesktop.DBus.Properties">
            <method name="Get">
              <arg name="interface" type="s" direction="in"/>
              <arg name="property" type="s" direction="in"/>
              <arg name="value" type="v" direction="out"/>
            </method>
            <method name="GetAll">
              <arg name="interface" type="s" direction="in"/>
              <arg name="properties" type="a{sv}" direction="out"/>
            </method>
            <signal name="PropertiesChanged">
              <arg name="interface" type="s"/>
              <arg name="changed" type="a{sv}"/>
              <arg name="invalidated" type="as"/>
            </signal>
          </interface>
          <interface name="org.kde.StatusNotifierItem">
            <property name="Category" type="s" access="read"/>
            <property name="Id" type="s" access="read"/>
            <property name="Title" type="s" access="read"/>
            <property name="Status" type="s" access="read"/>
            <property name="WindowId" type="i" access="read"/>
            <property name="IconName" type="s" access="read"/>
            <property name="IconPixmap" type="a(iiay)" access="read"/>
            <property name="IconThemePath" type="s" access="read"/>
            <property name="OverlayIconName" type="s" access="read"/>
            <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
            <property name="AttentionIconName" type="s" access="read"/>
            <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
            <property name="AttentionMovieName" type="s" access="read"/>
            <property name="ItemIsMenu" type="b" access="read"/>
            <property name="Menu" type="o" access="read"/>
            <property name="XAyatanaLabel" type="s" access="read"/>
            <property name="XAyatanaLabelGuide" type="s" access="read"/>
            <property name="XAyatanaOrderingIndex" type="u" access="read"/>
            <method name="Activate">
              <arg name="x" type="i" direction="in"/>
              <arg name="y" type="i" direction="in"/>
            </method>
            <method name="SecondaryActivate">
              <arg name="x" type="i" direction="in"/>
              <arg name="y" type="i" direction="in"/>
            </method>
            <method name="Scroll">
              <arg name="delta" type="i" direction="in"/>
              <arg name="orientation" type="s" direction="in"/>
            </method>
            <signal name="NewIcon"/>
            <signal name="NewTitle"/>
            <signal name="NewStatus"><arg name="status" type="s"/></signal>
          </interface>
          <node name="Menu"/>
        </node>
        """
    }

    public static let menuXML = """
        <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" \
        "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        <node>
          <interface name="com.canonical.dbusmenu">
            <property name="Version" type="u" access="read"/>
            <property name="TextDirection" type="s" access="read"/>
            <property name="Status" type="s" access="read"/>
            <property name="IconThemePath" type="as" access="read"/>
            <method name="GetLayout">
              <arg name="parentId" type="i" direction="in"/>
              <arg name="recursionDepth" type="i" direction="in"/>
              <arg name="propertyNames" type="as" direction="in"/>
              <arg name="revision" type="u" direction="out"/>
              <arg name="layout" type="(ia{sv}av)" direction="out"/>
            </method>
            <method name="GetGroupProperties">
              <arg name="ids" type="ai" direction="in"/>
              <arg name="propertyNames" type="as" direction="in"/>
              <arg name="properties" type="a(ia{sv})" direction="out"/>
            </method>
            <method name="GetProperty">
              <arg name="id" type="i" direction="in"/>
              <arg name="name" type="s" direction="in"/>
              <arg name="value" type="v" direction="out"/>
            </method>
            <method name="Event">
              <arg name="id" type="i" direction="in"/>
              <arg name="eventId" type="s" direction="in"/>
              <arg name="data" type="v" direction="in"/>
              <arg name="timestamp" type="u" direction="in"/>
            </method>
            <method name="EventGroup">
              <arg name="events" type="a(isvu)" direction="in"/>
              <arg name="idErrors" type="ai" direction="out"/>
            </method>
            <method name="AboutToShow">
              <arg name="id" type="i" direction="in"/>
              <arg name="needUpdate" type="b" direction="out"/>
            </method>
            <method name="AboutToShowGroup">
              <arg name="ids" type="ai" direction="in"/>
              <arg name="updatesNeeded" type="ai" direction="out"/>
              <arg name="idErrors" type="ai" direction="out"/>
            </method>
            <signal name="ItemsPropertiesUpdated">
              <arg name="updatedProps" type="a(ia{sv})"/>
              <arg name="removedProps" type="a(ias)"/>
            </signal>
            <signal name="LayoutUpdated">
              <arg name="revision" type="u"/>
              <arg name="parent" type="i"/>
            </signal>
          </interface>
        </node>
        """
}
