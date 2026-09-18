import Foundation
import ClaudeMonitorShared

/// Die Übersetzung von `systemctl --user is-enabled` in den Zustand, den die
/// Oberfläche kennt (``LoginItemState``) — reine Regel, kein Prozessstart.
public enum AutostartStatus {

    /// Was sich aus einem `is-enabled`-Aufruf ablesen lässt.
    ///
    /// ⚠️ Es gibt **fünf** Ausgänge und nicht drei. „Kein Nutzermanager
    /// erreichbar", „unerwartetes Wort" und „gar nicht erst gestartet" dürfen
    /// nicht in ``LoginItemState`` hineingefaltet werden:
    ///
    /// * Ohne Nutzermanager (Cronjob, SSH ohne Sitzung) antwortet `systemctl`
    ///   mit leerem stdout, „Failed to connect to user scope bus" auf stderr
    ///   und rc=1. Das als `.disabled` zu melden hieße „Autostart ist nicht
    ///   eingerichtet" — eine Aussage über eine Einrichtung, die gar nicht
    ///   abgefragt werden konnte (Auflage 1).
    /// * `bad` heißt „die Unit-Datei ist defekt". Auch das als `.disabled` zu
    ///   melden wäre eine Falschauskunft über einen Fehler, den der Nutzer
    ///   sehen muss (Auflage 2).
    public enum Reading: Equatable, Sendable {
        /// Ein Wort, das sich sauber auf den Schalterzustand abbilden lässt.
        case known(LoginItemState)
        /// Ein **bekanntes** `systemctl`-Wort ohne Entsprechung im
        /// Schalterzustand (`linked`, `static`, `bad`, …). Der Rohwert bleibt
        /// erhalten und gehört in die Meldung.
        case unexpected(word: String)
        /// Gar kein bekanntes Wort — leer oder etwas, das `systemctl` in
        /// dieser Fassung noch nicht kannte.
        case unreadable(word: String)
        /// Der Nutzermanager war nicht erreichbar; es wurde **nichts**
        /// gemessen.
        case managerUnavailable
        /// `systemctl` wurde gar nicht erst gestartet (Spawn/Pipe gescheitert).
        /// Anders als ``managerUnavailable``: Das sagt nichts über
        /// `XDG_RUNTIME_DIR`/den Sitzungsbus — der Grund liegt beim Aufruf
        /// selbst und wird roh mitgeführt.
        case didNotRun(reason: String)
    }

    /// Die Wörter, die `systemctl is-enabled` kennt, ohne dass sie einen
    /// Schalterzustand ergeben.
    static let knownUnmappedWords: Set<String> = [
        "linked", "linked-runtime", "alias", "static",
        "indirect", "generated", "transient", "bad"
    ]

    /// Wertet einen `is-enabled`-Aufruf aus.
    ///
    /// - Parameters:
    ///   - isEnabledOutput: stdout des Aufrufs.
    ///   - exitStatus: **der Aufruf-Erfolg**, nicht nur der Text. Ohne ihn
    ///     ließe sich „leere Antwort, weil kein Manager da" nicht von einer
    ///     echten Antwort unterscheiden (Auflage 1).
    ///   - standardError: stderr des Aufrufs.
    ///
    /// ⚠️ Ein Rückgabecode ≠ 0 allein ist **kein** Fehler: `is-enabled`
    /// antwortet auch für `disabled` und `not-found` mit rc=1. Deshalb zählt
    /// nur die Kombination aus leerer Ausgabe und misslungenem Aufruf bzw. die
    /// Verbindungsmeldung auf stderr.
    public static func reading(
        isEnabledOutput: String,
        exitStatus: Int32,
        standardError: String,
        didRun: Bool = true
    ) -> Reading {
        guard didRun else { return .didNotRun(reason: standardError) }
        let word = firstWordOfOutput(isEnabledOutput)
        if isManagerUnavailable(word: word, exitStatus: exitStatus, standardError: standardError) {
            return .managerUnavailable
        }
        switch word {
        case "enabled", "enabled-runtime":
            return .known(.enabled)
        case "masked", "masked-runtime":
            return .known(.requiresApproval)
        case "not-found", "disabled":
            return .known(.disabled)
        default:
            if knownUnmappedWords.contains(word) { return .unexpected(word: word) }
            return .unreadable(word: word)
        }
    }

    /// Ob der Aufruf gar keinen Nutzermanager erreicht hat.
    public static func isManagerUnavailable(
        word: String,
        exitStatus: Int32,
        standardError: String
    ) -> Bool {
        let lowered = standardError.lowercased()
        if lowered.contains("failed to connect to") { return true }
        if lowered.contains("failed to connect") && lowered.contains("bus") { return true }
        return word.isEmpty && exitStatus != 0
    }

    /// Das erste nicht-leere Wort der Ausgabe, kleingeschrieben.
    ///
    /// `is-enabled` stellt bei manchen Fassungen Hinweiszeilen voran bzw.
    /// hängt sie an; ausgewertet wird das erste echte Wort.
    public static func firstWordOfOutput(_ output: String) -> String {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return trimmed.lowercased()
        }
        return ""
    }
}
