import Foundation
import Security
import ClaudeMonitorShared

/// Prüft, ob dieses Programm das App-Group-Entitlement wirklich trägt.
///
/// **Warum das nötig ist:** `FileManager.containerURL(forSecurityApplication…)`
/// liefert bei einem *nicht* sandboxed Prozess auch ohne Entitlement einen
/// Pfad unter `~/Library/Group Containers/`. Der Schreibversuch dorthin läuft
/// dann in den macOS-Zustimmungsdialog „Zugriff auf Daten anderer Apps".
/// Erscheint der Dialog in einer Umgebung ohne sichtbares Fenster — etwa unter
/// dem Testrunner —, blockiert der Schreibvorgang **endlos**. Genau das ist
/// beim ersten Testlauf passiert.
///
/// Deshalb wird vorher die Signatur des eigenen Prozesses befragt: Trägt sie
/// die Gruppe nicht, wird gar nicht erst geschrieben.
enum AppGroupEntitlement {

    /// `true`, wenn die Codesignatur dieses Prozesses die App Group führt.
    static func isDeclared(_ identifier: String = AppGroup.identifier) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.security.application-groups" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        guard let groups = value as? [String] else { return false }
        return groups.contains(identifier)
    }
}
