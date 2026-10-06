import Foundation

/// Der Zustand von „Check for updates now" (CM-37) — reiner Werttyp.
///
/// Den Prozessstart und das Abholen des Kindes macht das Programmziel; hier
/// stehen Zustand, Abbildung des Ergebnisses und die Menüzeilen, damit sie ohne
/// Prozessstart prüfbar sind (CM-20-Schichtung). Der Zustand lebt nur im
/// Prozess und wird nicht gespeichert (FE 10).
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
    ///     Zählt nur bei Exit 0.
    public static func outcome(exitStatus: Int32?, binaryReplaced: Bool) -> Outcome {
        switch exitStatus {
        case 0: return binaryReplaced ? .updatedRestartNeeded : .upToDate
        case 12: return .nothingChecked
        case 13: return .refused
        default: return .couldNotRun
        }
    }

    /// Die Zeile eines Ergebnisses.
    public static func text(for outcome: Outcome) -> String {
        switch outcome {
        case .upToDate: return TrayTexts.lastCheckUpToDate
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
}
