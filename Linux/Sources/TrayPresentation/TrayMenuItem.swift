import Foundation

/// Ein Eintrag des Tray-Menüs — **reine Daten**, kein D-Bus, keine Anzeige.
///
/// Das Menü ist auf Linux kein Zubehör, sondern Pflicht: Ein
/// `StatusNotifierItem` ohne bedientes `com.canonical.dbusmenu` wird von
/// gnome-shell nie sichtbar (Fachentscheid 5.1, A/B am System gemessen —
/// `appIndicator.js:529,626-630`, `indicatorStatusIcon.js:130`). Es ist
/// zugleich das Gegenstück zum Detailfenster der macOS-Fassung.
///
/// **Flach und nicht verschachtelt.** Die Kärtchen des Detailfensters zeigen
/// alle Zahlen auf einen Blick; ein Untermenü je Account machte daraus ein
/// Aufklappen pro Account. Die Auskunftszeilen sind deshalb eigene Einträge auf
/// derselben Ebene, nur nicht anklickbar.
public struct TrayMenuItem: Equatable, Sendable {

    /// Wofür ein Eintrag da ist.
    public enum Role: String, Equatable, Sendable {
        /// Auskunft — zeigt etwas, tut nichts.
        case information
        /// Trennlinie.
        case separator
        /// „Jetzt aktualisieren" (`MonitorPopoverView.swift:69-77`).
        case refresh
        /// „Beenden" (`MonitorPopoverView.swift:292-297`). Für einen residenten
        /// Prozess ohne Programmmenü der einzige Weg hinaus — deshalb Pflicht
        /// und nicht Kür (Auflage 8).
        case quit
    }

    /// Stabiler Schlüssel für die Kennungsvergabe.
    ///
    /// ⚠️ Er darf **nie** eine Position enthalten. Die Kennung eines Eintrags
    /// wird daraus abgeleitet (``TrayMenuIdentifiers``), und eine positions-
    /// abhängige Kennung änderte sich, sobald ein Account wegfällt — genau der
    /// Fehler, den Auflage 6 ausschließt.
    public let key: String
    public let role: Role
    /// Der angezeigte Text. Bei ``Role/separator`` leer.
    public let label: String

    public init(key: String, role: Role, label: String) {
        self.key = key
        self.role = role
        self.label = label
    }

    /// Eine Auskunftszeile.
    public static func information(key: String, label: String) -> TrayMenuItem {
        TrayMenuItem(key: key, role: .information, label: label)
    }

    /// Eine Trennlinie. Sie braucht trotzdem einen eigenen Schlüssel, weil auch
    /// sie eine Kennung im Layout trägt.
    public static func separator(key: String) -> TrayMenuItem {
        TrayMenuItem(key: key, role: .separator, label: "")
    }

    /// Anklickbar ist ausschließlich, was wirklich etwas tut. Auskunftszeilen
    /// sind gesperrt: Ein Eintrag, der sich anklicken lässt, das Menü schließt
    /// und nichts bewirkt, ist eine Falschaussage über die eigene Bedienung.
    public var isEnabled: Bool {
        switch role {
        case .refresh, .quit: return true
        case .information, .separator: return false
        }
    }
}

/// Vergibt und behält die Menü-Kennungen für die gesamte Prozesslaufzeit.
///
/// **Warum ein Register und keine Zählung beim Aufbauen** (Auflage 6): Die
/// Kennungen eines dbusmenu sind für die Gegenstelle dauerhafte Identitäten —
/// `ItemsPropertiesUpdated`, `Event` und `AboutToShow` sprechen Einträge über
/// sie an. Würde bei jedem Durchlauf neu durchnummeriert, bekäme nach dem
/// Wegfallen eines Accounts jeder folgende Eintrag die Kennung seines
/// Nachbarn — angeklickt würde dann der falsche.
///
/// Der Schlüssel eines Account-Eintrags stammt aus ``MonitoredAccount/id`` und
/// damit aus der Quelle selbst. `AccountIdentifierOrder` kommt dafür
/// ausdrücklich **nicht** in Frage: Das ist ein reiner Vergleicher
/// (`AccountIdentifierOrder.swift:18-28`) und liefert überhaupt keine Kennung.
public final class TrayMenuIdentifiers {

    /// Die Wurzel des Menübaums hat im dbusmenu-Protokoll immer die 0.
    public static let root: Int32 = 0

    private var assigned: [String: Int32] = [:]
    private var keys: [Int32: String] = [:]
    private var nextIdentifier: Int32 = 1

    public init() {}

    /// Die Kennung zu einem Schlüssel — beim ersten Mal neu vergeben, danach
    /// dieselbe. Vergebene Kennungen werden nie wiederverwendet.
    public func identifier(for key: String) -> Int32 {
        if let existing = assigned[key] { return existing }
        let identifier = nextIdentifier
        nextIdentifier += 1
        assigned[key] = identifier
        keys[identifier] = key
        return identifier
    }

    /// Der Schlüssel hinter einer Kennung — für eingehende `Event`-Aufrufe.
    public func key(for identifier: Int32) -> String? {
        keys[identifier]
    }
}
