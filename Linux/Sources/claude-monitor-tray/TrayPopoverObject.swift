import Foundation
import DBusWire
import TrayPresentation

/// Das Objekt unter `/Popover` — `org.claudemonitor.Tray.Popover1` (CM-41).
///
/// Es hält den zuletzt angewandten JSON-String und verteilt die Aufrufe der
/// Popover-Extension; **was** darin steht, entscheidet ``TrayPopoverState`` im
/// Bibliotheksziel. `Invoke` und `Opened` laufen über dasselbe
/// ``DBusMenuObject`` wie ein Menüklick, damit es genau einen Weg gibt.
///
/// Der Typ hat keinen Fehlerfall (``DBusCallOutcome``): Ein fehlendes Argument
/// ergibt `false`, alles Unbekannte eine leere Antwort.
final class TrayPopoverObject: DBusObject {

    let objectPath = TrayPopoverInterface.objectPath
    private let menu: DBusMenuObject
    private(set) var stateJSON: String

    init(state: TrayPopoverState, menu: DBusMenuObject) {
        self.stateJSON = state.json()
        self.menu = menu
    }

    /// Übernimmt einen neuen Stand.
    ///
    /// - Returns: der neue JSON-String, wenn er vom letzten abweicht — dann
    ///   ist `StateChanged` zu senden. Sonst `nil` (Fachentscheid FE-8).
    func apply(_ state: TrayPopoverState) -> String? {
        let json = state.json()
        guard json != stateJSON else { return nil }
        stateJSON = json
        return json
    }

    func handle(_ call: DBusMessage) -> DBusCallOutcome {
        switch (call.interface, call.member) {
        case (TrayPopoverInterface.interfaceName, "GetState"):
            return .value(.string(stateJSON))

        case (TrayPopoverInterface.interfaceName, "Invoke"):
            var reader = call.bodyReader()
            guard let key = try? reader.readString() else { return .value(.bool(false)) }
            return .value(.bool(menu.enqueue(key: key)))

        case (TrayPopoverInterface.interfaceName, "Opened"):
            menu.noteOpened()
            return .empty

        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return .value(.string(TrayPopoverInterface.introspectionXML))

        default:
            return .empty
        }
    }
}
