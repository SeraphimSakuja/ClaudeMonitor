import Foundation
import ClaudeMonitorShared

/// Die Übersetzung von `systemctl --user is-enabled` in den Zustand, den die
/// Oberfläche kennt (``LoginItemState``), und von `show -p FragmentPath` in
/// die wirksame Unit-Datei — reine Regeln, kein Prozessstart.
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
        if isConnectionFailure(standardError: standardError) { return true }
        return word.isEmpty && exitStatus != 0
    }

    /// Ob stderr die Verbindungsmeldung von `systemctl` trägt („Failed to
    /// connect to user scope bus").
    public static func isConnectionFailure(standardError: String) -> Bool {
        let lowered = standardError.lowercased()
        if lowered.contains("failed to connect to") { return true }
        return lowered.contains("failed to connect") && lowered.contains("bus")
    }

    // MARK: - Wirksame Unit (CM-32)

    /// Die Antwort eines `systemctl`-Aufrufs, wie sie die Auswertung braucht —
    /// ohne den Prozessstart selbst.
    public struct Answer: Equatable, Sendable {
        public let exitStatus: Int32
        public let standardOutput: String
        public let standardError: String
        /// `false`, wenn der Aufruf gar nicht erst gestartet wurde; dann ist
        /// `standardError` der Ausfallgrund.
        public let didRun: Bool

        public init(exitStatus: Int32, standardOutput: String, standardError: String, didRun: Bool = true) {
            self.exitStatus = exitStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.didRun = didRun
        }
    }

    /// Was sich aus `daemon-reload` und `show -p FragmentPath --value` über
    /// die Unit-Datei ablesen lässt, die systemd für den Namen lädt.
    public enum FragmentReading: Equatable, Sendable {
        /// systemd kennt keine Unit-Datei dieses Namens (leerer Wert, rc 0).
        case noUnitFile
        /// systemd lädt diese Datei — Wert roh, nur ohne Zeilenende.
        case path(String)
        /// Einer der beiden Aufrufe wurde gar nicht erst gestartet.
        case didNotRun(reason: String)
        /// Der Nutzermanager war nicht erreichbar (Verbindungsmeldung auf stderr).
        case managerUnavailable
        /// Ein Aufruf endete mit rc ≠ 0; der Grund ist stderr.
        case failed(reason: String)
        /// `show` lieferte etwas, das kein absoluter Pfad ist; Rohwert.
        case unusableValue(String)
    }

    /// Wertet erst `daemon-reload`, dann `show` aus.
    ///
    /// `show` wird nur abgefragt, wenn `daemon-reload` durchlief: Ohne Reload
    /// meldet ein geladener Dienst den Pfad von vor der Änderung.
    ///
    /// ⚠️ Nicht über ``isManagerUnavailable(word:exitStatus:standardError:)``
    /// und nicht über ``firstWordOfOutput(_:)``: Die erste Regel erklärte
    /// jeden Fehler mit leerem stdout zu „kein Nutzermanager", die zweite
    /// schriebe den Pfad klein und schnitte Leerzeichen ab.
    public static func fragmentReading(reload: Answer, show: () -> Answer) -> FragmentReading {
        if let failure = stepFailure(reload) { return failure }
        let answer = show()
        if let failure = stepFailure(answer) { return failure }
        return fragmentPath(fromShowOutput: answer.standardOutput)
    }

    /// Feste Zuordnung eines misslungenen Aufrufs; `nil`, wenn er gelang.
    static func stepFailure(_ answer: Answer) -> FragmentReading? {
        guard answer.didRun else { return .didNotRun(reason: answer.standardError) }
        if isConnectionFailure(standardError: answer.standardError) { return .managerUnavailable }
        guard answer.exitStatus == 0 else {
            let reason = answer.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: reason.isEmpty ? "exit status \(answer.exitStatus)" : reason)
        }
        return nil
    }

    /// Liest den Wert von `show -p FragmentPath --value` **roh**: nur das
    /// abschließende Zeilenende fällt weg, kein Trim, keine Kleinschreibung.
    static func fragmentPath(fromShowOutput output: String) -> FragmentReading {
        if output.isEmpty || output == "\n" { return .noUnitFile }
        let firstLine: String
        if let newline = output.firstIndex(of: "\n") {
            firstLine = String(output[..<newline])
        } else {
            firstLine = output
        }
        guard firstLine.hasPrefix("/") else { return .unusableValue(firstLine) }
        return .path(firstLine)
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
