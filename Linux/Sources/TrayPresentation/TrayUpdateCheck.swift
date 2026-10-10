import Foundation

/// Der Zustand von „Check for updates now" (CM-37) und der Suche ab Werk
/// (CM-36) — reiner Werttyp.
///
/// Den Prozessstart und das Abholen des Kindes macht das Programmziel; hier
/// stehen Zustand, Abbildung des Ergebnisses, die Menüzeilen und die Regeln der
/// Suche ab Werk (Takt, Abschalter, Nachversuch, was sichtbar wird), damit sie
/// ohne Prozessstart prüfbar sind (CM-20-Schichtung). Der Zustand lebt nur im
/// Prozess und wird nicht gespeichert (FE 10) — auch kein Zeitstempel der
/// letzten Suche (CM-36 · FE-8).
public struct TrayUpdateCheck: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        /// Noch keine Prüfung seit dem Start des Trays.
        case idle
        /// Das Kind läuft — vom erfolgreichen Start bis zum Abholen (FE 8).
        case running
        case finished(Outcome)
    }

    /// Ergebnis einer Prüfung (FE 9).
    public enum Outcome: Equatable, Sendable {
        /// Exit 0, und der Pfad zeigt auf dieselbe Datei wie der laufende Tray.
        case upToDate
        /// CM-36 · Exit 14 von `--check-update`: eine neuere Fassung gibt es und
        /// passt, nichts wurde geladen; das Verzeichnis des Binarys ist
        /// schreibbar — „Check for updates now" kann sie installieren.
        case updateAvailable
        /// CM-36 · Exit 14, aber das Verzeichnis des Binarys ist nicht
        /// schreibbar (2b-Auflage 2): kein Installationsversprechen, nur der
        /// Handdownload.
        case updateAvailableByHand
        /// Exit 0, und am Pfad liegt eine andere Datei als die, die läuft —
        /// diese oder eine frühere Prüfung hat das Binary ersetzt, der Tray
        /// läuft noch in der alten Fassung.
        case updatedRestartNeeded
        /// Exit 12: nichts gemessen (kein Netz, kein Manifest, …).
        case nothingChecked
        /// Exit 13: abgelehnt (Manifest ungültig, Prüfsumme falsch, Verzeichnis
        /// nicht schreibbar, …). Umfasst auch „ein anderes Update läuft": Der
        /// `flock` auf dem Binary-Verzeichnis lässt das zweite `--update` mit
        /// 13 enden (`main.swift:74-78`, `UpdateClient.swift:50-62`). Kein
        /// eigener Zustand dafür.
        case refused
        /// Jeder andere Code, Signaltod (`-1`), Start gescheitert oder eigenes
        /// Binary nicht auflösbar. Ausdrücklich kein „aktuell".
        case couldNotRun
    }

    public let state: State

    public init(state: State = .idle) {
        self.state = state
    }

    public static let idle = TrayUpdateCheck(state: .idle)
    public static let running = TrayUpdateCheck(state: .running)
    public static func finished(_ outcome: Outcome) -> TrayUpdateCheck {
        TrayUpdateCheck(state: .finished(outcome))
    }

    /// Ob ein Klick eine neue Prüfung starten darf.
    public var canStart: Bool { state != .running }

    /// FE 9: Exit-Code des Kindes und Dateiidentität → Ergebnis.
    ///
    /// - Parameters:
    ///   - exitStatus: Exit-Code des Kindes; `-1` bei Signaltod; `nil`, wenn
    ///     der Start scheiterte oder die Identität nicht messbar war.
    ///   - binaryReplaced: Identität(Pfad) ≠ Identität(`/proc/self/exe`).
    ///     Zählt nur bei Exit 0 (CM-36 · FE-11: auch für die Suche).
    ///   - directoryWritable: `access(<Verzeichnis des Pfads>, W_OK) == 0`.
    ///     Zählt nur bei Exit 14 (2b-Auflage 2).
    public static func outcome(exitStatus: Int32?, binaryReplaced: Bool, directoryWritable: Bool) -> Outcome {
        switch exitStatus {
        case 0: return binaryReplaced ? .updatedRestartNeeded : .upToDate
        case 12: return .nothingChecked
        case 13: return .refused
        case 14: return directoryWritable ? .updateAvailable : .updateAvailableByHand
        default: return .couldNotRun
        }
    }

    /// Die Zeile eines Ergebnisses.
    public static func text(for outcome: Outcome) -> String {
        switch outcome {
        case .upToDate: return TrayTexts.lastCheckUpToDate
        case .updateAvailable: return TrayTexts.lastCheckUpdateAvailable
        case .updateAvailableByHand: return TrayTexts.lastCheckUpdateAvailableByHand
        case .updatedRestartNeeded: return TrayTexts.lastCheckReplaced
        case .nothingChecked: return TrayTexts.lastCheckNothingChecked
        case .refused: return TrayTexts.lastCheckRefused
        case .couldNotRun: return TrayTexts.lastCheckCouldNotRun
        }
    }

    /// Die Menüeinträge dieses Zustands (FE 6/8/9/10): Aktion, bei laufender
    /// Prüfung stattdessen die gesperrte Laufzeile, nach einer Prüfung dazu
    /// höchstens eine Ergebniszeile.
    public var menuItems: [TrayMenuItem] {
        switch state {
        case .idle:
            return [TrayMenuItem(key: "action.checkForUpdates", role: .checkForUpdates, label: TrayTexts.checkForUpdates)]
        case .running:
            return [.information(key: "action.checkForUpdates", label: TrayTexts.checkingForUpdates)]
        case .finished(let outcome):
            return [
                TrayMenuItem(key: "action.checkForUpdates", role: .checkForUpdates, label: TrayTexts.checkForUpdates),
                .information(key: "checkForUpdates.result", label: Self.text(for: outcome))
            ]
        }
    }

    // MARK: - Suche ab Werk (CM-36)

    /// FE-8: erste Suche 15 min nach dem Start des Trays — wie der Timer
    /// (`UpdateUnits`), und zugleich der Abstand des einen Nachversuchs.
    public static let automaticFirstDelay: TimeInterval = 900
    /// FE-8: danach alle 24 h Prozesslaufzeit, gezählt ab dem **Start** der
    /// Suche — wie `SUScheduledCheckInterval` der macOS-Linie.
    public static let automaticInterval: TimeInterval = 86_400
    /// FE-9: der einzige Abschalter — kein Menüeintrag, keine Merkdatei.
    public static let disableVariable = "CLAUDE_MONITOR_NO_UPDATE_CHECK"

    /// FE-9: Genau der Wert `1` schaltet die Suche ab Werk ab; nicht gesetzt,
    /// leer, `0` oder jeder andere Wert lässt sie an. Wirkt nur auf die Suche
    /// ab Werk, nie auf „Check for updates now", `--update`,
    /// `--check-update` oder den Timer.
    public static func automaticChecksEnabled(environment: [String: String]) -> Bool {
        environment[disableVariable] != "1"
    }

    /// FE-10: Was eine **automatische** Suche im Menü hinterlässt. „Nichts
    /// gemessen" und „konnte nicht laufen" ändern nichts — es bleibt der
    /// Stand von vor der Suche (kein Ergebnis oder das vorige). Sichtbar
    /// werden: aktuell, neuere Fassung vorhanden (beide Formen), abgelehnt,
    /// neuere Fassung installiert — Tray neu starten.
    ///
    /// - Parameter previous: der Zustand vor dem Start der Suche.
    public static func afterAutomaticCheck(_ outcome: Outcome, previous: TrayUpdateCheck) -> TrayUpdateCheck {
        switch outcome {
        case .nothingChecked, .couldNotRun: return previous
        default: return .finished(outcome)
        }
    }

    /// FE-8 + 2b-Auflage 11: der nächste Start nach einer automatischen
    /// Suche, die bei `startedAt` begann.
    ///
    /// Endet sie mit „nichts gemessen" (Exit 12 — oft das WLAN nach dem
    /// Aufwachen), gibt es **genau einen** Nachversuch nach
    /// ``automaticFirstDelay``; endet auch der mit 12, geht es im 24-h-Takt
    /// ab dessen Start weiter. Jeder andere Ausgang: 24 h ab `startedAt`.
    ///
    /// - Parameter wasRetry: Die Suche war selbst der Nachversuch.
    /// - Returns: der Zeitpunkt und ob der nächste Start ein Nachversuch ist.
    public static func nextAutomaticCheck(
        startedAt: Date,
        outcome: Outcome,
        wasRetry: Bool
    ) -> (date: Date, isRetry: Bool) {
        if outcome == .nothingChecked && !wasRetry {
            return (startedAt.addingTimeInterval(automaticFirstDelay), true)
        }
        return (startedAt.addingTimeInterval(automaticInterval), false)
    }
}
