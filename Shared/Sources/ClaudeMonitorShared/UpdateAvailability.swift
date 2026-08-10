import Foundation

/// Was der Knopf „Nach Updates suchen…" anzeigen darf.
///
/// Es gibt genau einen gesperrten Zustand, der eine Entschuldigung ist
/// (``checking`` — es läuft gerade etwas), und genau einen, der ein Defekt ist
/// (``unavailable`` — der Updater ist nie gestartet). Beide sehen an
/// `canCheckForUpdates` gleich aus; die Oberfläche muss sie trotzdem
/// auseinanderhalten.
public enum UpdateButtonState: Equatable, Sendable {

    /// Bedienbar.
    case ready
    /// Vorübergehend gesperrt: Eine Prüfung läuft oder eine Installation steht
    /// aus. Geht von selbst wieder weg.
    case checking
    /// Dauerhaft gesperrt: Der Updater ist nie bereit gewesen. Aus diesem
    /// Zustand führt nur ein Neustart der App heraus.
    case unavailable
}

/// Die Regel hinter dem Update-Knopf.
///
/// **Warum zwei Eingaben und nicht nur `canCheckForUpdates`:** Sparkle setzt
/// die Eigenschaft **auch während einer laufenden Prüfung** auf `false`
/// (`SPUUpdater.m:713 _sessionInProgress`). Ein pauschales „Updates sind nicht
/// verfügbar" wäre also in dem Moment falsch, in dem die App gerade das
/// Gegenteil tut. Andersherum wäre ein pauschales „Suche nach Updates…" bei
/// einem nie gestarteten Updater die Behauptung einer Tätigkeit, die es nicht
/// gibt. Beides ist eine Falschauskunft, und ein gesperrtes Bedienelement ohne
/// sichtbare Begründung ist in dieser App seit CM-11/CM-12 ein Fehler.
///
/// Unterscheidungsmerkmal ist deshalb, ob der Updater überhaupt **je** bereit
/// war. War er es nie, hat `startUpdater` versagt — das ist der Defekt.
///
/// Die Regel liegt in `Shared/`, ist framework-frei und hält keinen Zustand;
/// `hasEverBeenReady` führt der Aufrufer (``UpdateController``) mit.
public enum UpdateAvailability {

    /// - Parameters:
    ///   - canCheckForUpdates: Spiegel von `SPUUpdater.canCheckForUpdates`.
    ///   - hasEverBeenReady: Ob `canCheckForUpdates` seit Prozessstart schon
    ///     einmal `true` war. Wird nie zurückgesetzt.
    public static func state(canCheckForUpdates: Bool, hasEverBeenReady: Bool) -> UpdateButtonState {
        if canCheckForUpdates { return .ready }
        return hasEverBeenReady ? .checking : .unavailable
    }
}
