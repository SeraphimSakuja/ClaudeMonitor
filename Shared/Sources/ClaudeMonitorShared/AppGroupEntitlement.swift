import Foundation
#if canImport(Security)
import Security
#endif

/// Prüft, ob das laufende Programm das App-Group-Entitlement wirklich **trägt**.
///
/// **Warum das nötig ist:** `FileManager.containerURL(forSecurityApplication…)`
/// liefert bei einem *nicht* sandboxed Prozess auch **ohne** Entitlement einen
/// Pfad unter `~/Library/Group Containers/` — der Pfad existiert also, die
/// Funktion gibt gerade **nicht** `nil` zurück. Erst der Zugriff darauf läuft in
/// den macOS-Zustimmungsdialog „Zugriff auf Daten anderer Apps". Erscheint der
/// Dialog in einer Umgebung ohne sichtbares Fenster — etwa unter einem
/// Testrunner —, blockiert der Zugriff **endlos**. Genau das ist zweimal
/// reproduziert worden.
///
/// Deshalb wird vorher die Codesignatur des eigenen Prozesses befragt: Trägt sie
/// die Gruppe nicht, wird der Container gar nicht erst angefasst.
///
/// **Die Wache lebt hier in `Shared/` und nicht im App-Target**, weil sie sonst
/// umgehbar wäre: Die Widget-Extension benutzt denselben ``SnapshotStore`` und
/// liefe ohne sie ungeschützt in dieselbe Blockade. ``SnapshotStore`` wertet sie
/// **innerhalb** von ``SnapshotStore/containerDirectory`` aus — es gibt keinen
/// Pfad am Container vorbei.
///
/// **Grenze der Wache:** Sie prüft die *Deklaration*, nicht die *Autorisierung*.
/// Ein ad hoc signiertes Programm (`CODE_SIGN_IDENTITY = -`) mit gesetztem
/// Entitlement meldet hier `true`, der Zugriff blockiert trotzdem. Siehe die
/// Warnung in `App/Signing.xcconfig`.
public struct AppGroupEntitlement: Sendable {

    /// Liefert die App Groups, die die Signatur des Prozesses führt.
    public typealias GroupsProvider = @Sendable () -> [String]

    private let groups: GroupsProvider

    /// - Parameter groups: Quelle der deklarierten Gruppen. Injizierbar, damit
    ///   ``isDeclared(_:)`` prüfbar ist, ohne den Testprozess signieren zu
    ///   müssen.
    public init(groups: @escaping GroupsProvider) {
        self.groups = groups
    }

    /// Die echte Wache: fragt die Codesignatur des laufenden Prozesses.
    public static let codeSignature = AppGroupEntitlement(groups: Self.groupsFromCodeSignature)

    /// Wache mit fest vorgegebenen Gruppen — für Tests und für Aufrufer, die
    /// die Deklaration schon anderweitig kennen.
    public static func declaring(_ groups: [String]) -> AppGroupEntitlement {
        AppGroupEntitlement(groups: { groups })
    }

    /// Wache, die nie etwas freigibt.
    public static let none = AppGroupEntitlement.declaring([])

    /// `true`, wenn die Signatur dieses Prozesses die App Group führt.
    public func isDeclared(_ identifier: String = AppGroup.identifier) -> Bool {
        groups().contains(identifier)
    }

    /// Liest `com.apple.security.application-groups` aus der eigenen Signatur.
    /// Jeder Fehlfall bedeutet „nicht deklariert" — die Wache irrt nur zur
    /// sicheren Seite.
    public static func groupsFromCodeSignature() -> [String] {
        #if canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        let key = "com.apple.security.application-groups" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return [] }
        return value as? [String] ?? []
        #else
        return []
        #endif
    }
}
