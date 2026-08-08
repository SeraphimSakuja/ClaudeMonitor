import Foundation

/// Findet den Cache von claude-swap, ohne Nutzerpfade hart zu kodieren.
///
/// claude-swap legt seinen Backup-Store auf macOS unter `~/.claude-swap-backup`
/// ab und folgt sonst der XDG-Konvention. Beide Orte werden in dieser
/// Reihenfolge geprüft.
public enum UsageStoreLocator {

    /// Pfad relativ zum Home-Verzeichnis (macOS-Variante).
    public static let macRelativePath = ".claude-swap-backup/cache/usage.json"
    /// Pfad relativ zum XDG-Datenverzeichnis.
    public static let xdgRelativePath = "claude-swap/cache/usage.json"

    /// Alle Kandidatenpfade in Prüfreihenfolge — auch dann, wenn keiner existiert.
    /// Wird für den Hinweis „claude-swap nicht gefunden" mit ausgegeben.
    public static func candidateURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var candidates: [URL] = [
            homeDirectory.appending(path: macRelativePath)
        ]
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            candidates.append(URL(fileURLWithPath: xdg).appending(path: xdgRelativePath))
        }
        candidates.append(homeDirectory.appending(path: ".local/share/" + xdgRelativePath))
        return candidates
    }

    /// Dateiname der Geschwisterdatei mit Reihenfolge, aktivem Account und Aliasen.
    public static let sequenceFileName = "sequence.json"

    /// Pfad zu `sequence.json`, **abgeleitet** aus der gefundenen `usage.json`.
    ///
    /// Die Datei liegt eine Ebene **über** dem Cache-Verzeichnis
    /// (`…/cache/usage.json` → `…/sequence.json`) und gilt für beide
    /// Fundstellen (macOS-Home wie XDG). Abgeleitet statt eigenständig gesucht:
    /// Ein zweiter Pfadmechanismus daneben könnte auf eine andere Installation
    /// zeigen als die, deren Zahlen gerade angezeigt werden.
    public static func sequenceURL(forStoreAt storeURL: URL) -> URL {
        storeURL
            .deletingLastPathComponent()   // …/cache
            .deletingLastPathComponent()   // …/ (Wurzel des Backup-Stores)
            .appending(path: sequenceFileName)
    }

    /// Erster existierender Kandidat, sonst `nil`.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        candidateURLs(environment: environment, homeDirectory: homeDirectory)
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}
